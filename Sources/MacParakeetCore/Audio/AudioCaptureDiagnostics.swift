import CoreAudio
import Darwin
import Foundation
import os

public enum AudioCaptureDiagnostics {
    private static let lock = OSAllocatedUnfairLock(initialState: ())
    private static let logger = Logger(subsystem: "com.macparakeet.core", category: "AudioCaptureDiagnostics")
    private static let processSession = UUID().uuidString.lowercased()
    private static let appendQueue = DispatchQueue(
        label: "com.macparakeet.audio-capture-diagnostics.append",
        qos: .utility
    )
    private static let logPathOverrideEnvironmentKey = "MACPARAKEET_AUDIO_DIAGNOSTICS_LOG_PATH"
    /// On-disk cap for `dictation-audio.log`. When the cap is reached, retain
    /// the newest complete lines instead of deleting all diagnostic history.
    /// Five MB keeps tens of days for normal use; retaining half leaves room
    /// for the next burst without rotating on every append.
    private static let maxLogBytes: UInt64 = 5_000_000
    private static let retainedLogBytes = Int(maxLogBytes / 2)
    private static let maxMessageCharacters = 16_384

    private enum MainThreadAppendResult {
        case completed
        case deferred(reason: String)
    }

    private enum LogWriteError: Error {
        case rotationRequiresBackground
    }

    public static var diagnosticLogFileURL: URL {
        diagnosticLogURL()
    }

    public static var diagnosticLogMaxBytes: UInt64 {
        maxLogBytes
    }

    /// Device identity is private: diagnostics are designed to be shared, so
    /// labels intentionally omit CoreAudio IDs, UIDs, and microphone names.
    static func deviceLabel(_ deviceID: AudioDeviceID?) -> String {
        deviceID == nil ? "none" : "present"
    }

    static func deviceTransportLabel(_ deviceID: AudioDeviceID?) -> String {
        guard let deviceID else { return "none" }
        let transport = AudioDeviceManager.transportType(deviceID)
        if transport == kAudioDeviceTransportTypeAggregate,
            let subTransport = AudioDeviceManager.subDeviceTransport(deviceID)
        {
            return "aggregate-\(safeTransportLabel(subTransport))"
        }
        return safeTransportLabel(transport)
    }

    static func defaultInputDeviceLabel() -> String {
        deviceLabel(AudioDeviceManager.defaultInputDevice())
    }

    static func defaultInputDeviceTransportLabel() -> String {
        deviceTransportLabel(AudioDeviceManager.defaultInputDevice())
    }

    static func defaultInputDeviceSummary() -> String {
        let deviceID = AudioDeviceManager.defaultInputDevice()
        return "default_input=\(deviceLabel(deviceID)) default_input_transport=\(deviceTransportLabel(deviceID))"
    }

    static func errorType(_ error: Error) -> String {
        TelemetryErrorClassifier.classify(error)
    }

    static func errorFields(_ error: Error) -> String {
        // This file can be attached to public feedback. Arbitrary error text
        // can contain speech, filenames or credentials that regex redaction
        // cannot reliably recognize. Keep classified type and the NSError
        // bridge code here. For Swift wrappers that code can be an enum ordinal,
        // not the underlying OSStatus retained in the classified type. Existing
        // OSLog calls carry separate, privacy-marked localized descriptions.
        "error_type=\(errorType(error)) bridged_error_code=\((error as NSError).code)"
    }

    static func sanitizedMessage(_ message: String) -> String {
        TelemetryErrorClassifier.sanitize(message)
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    static func sanitizedLogValue(_ message: String) -> String {
        String(
            sanitizedMessage(message)
                .replacingOccurrences(of: "\"", with: "'")
                .prefix(512)
        )
    }

    public static func append(_ message: @autoclosure () -> String) {
        append(message(), timestamp: Date(), uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    private static func append(_ message: String, timestamp: Date, uptimeNanoseconds: UInt64) {
        let data = encodedLogLine(message, timestamp: timestamp, uptimeNanoseconds: uptimeNanoseconds)
        appendEncodedLogLine(data, to: diagnosticLogURL())
    }

    static func appendEncodedLogLine(_ data: Data, to logURL: URL) {
        if Thread.isMainThread {
            let result = lock.withLockIfAvailable {
                do {
                    try writeLogLine(data, to: logURL, waitForLock: false, allowRotation: false)
                    return MainThreadAppendResult.completed
                } catch LogWriteError.rotationRequiresBackground {
                    return .deferred(reason: "rotation")
                } catch {
                    let code = (error as NSError).code
                    if (error as NSError).domain == NSPOSIXErrorDomain, code == Int(EWOULDBLOCK) {
                        return .deferred(reason: "lock_contended")
                    }
                    logger.error("audio_diagnostic_write_failed error_type=\(errorType(error), privacy: .public)")
                    return .completed
                }
            } ?? .deferred(reason: "lock_contended")
            if case .deferred(let reason) = result {
                logger.info("audio_diagnostic_write_deferred reason=\(reason, privacy: .public)")
                // Keep the exact record and its occurrence clocks. Only its
                // visibility is deferred; a busy writer must not block the UI.
                appendQueue.async { appendEncodedLogLine(data, to: logURL) }
            }
            return
        }

        lock.withLock {
            do {
                try writeLogLine(data, to: logURL)
            } catch {
                // Keep capture independent of the file sink, but make a failed
                // diagnostic write visible through the independent system log.
                logger.error("audio_diagnostic_write_failed error_type=\(errorType(error), privacy: .public)")
            }
        }
    }

    static func flushPendingAppends() async {
        await withCheckedContinuation { continuation in
            appendQueue.async { continuation.resume() }
        }
    }

    /// Capture the clocks before dispatching: a busy utility queue must not
    /// make a first-buffer event appear to have happened after Stop. The random
    /// process session distinguishes app/CLI runs without a persistent ID.
    public static func appendAsync(_ message: String) {
        let timestamp = Date()
        let uptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        appendQueue.async {
            append(message, timestamp: timestamp, uptimeNanoseconds: uptimeNanoseconds)
        }
    }

    static func encodedLogLine(_ message: String, timestamp: Date, uptimeNanoseconds: UInt64) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sanitized = String(sanitizedMessage(message).prefix(maxMessageCharacters))
        let line =
            "\(formatter.string(from: timestamp)) \(sanitized)"
            + " process_id=\(ProcessInfo.processInfo.processIdentifier)"
            + " process_session=\(processSession) uptime_ns=\(uptimeNanoseconds)\n"
        return Data(line.utf8)
    }

    /// Serialize the complete create/append/rotate operation across cooperating
    /// app and CLI processes. Keeping the boundary throwable also lets tests
    /// exercise failures against isolated files instead of user logs.
    static func writeLogLine(
        _ data: Data, to logURL: URL, waitForLock: Bool = true, allowRotation: Bool = true
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try withLogFileLock(at: logURL, waitForLock: waitForLock) {
            if fm.fileExists(atPath: logURL.path) {
                // An open failure is not an absent file: replacing it would erase
                // the existing history (e.g. a read-only log in a writable folder).
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                if size + UInt64(data.count) > maxLogBytes {
                    guard allowRotation else { throw LogWriteError.rotationRequiresBackground }
                    let existingData = try Data(contentsOf: logURL)
                    var rotatedData = retainedLogSuffix(existingData, maxBytes: retainedLogBytes)
                    rotatedData.append(data)
                    try rotatedData.write(to: logURL, options: .atomic)
                    return
                }
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logURL, options: .atomic)
            }
        }
    }

    /// The sibling inode is stable across atomic log replacement. Never unlink
    /// this file: another process may already hold or be waiting on its lock.
    /// This advisory lock only coordinates participating local writers; readers
    /// remain independent. Closing releases it on success, failure, or exit.
    static func withLogFileLock(at logURL: URL, waitForLock: Bool = true, _ operation: () throws -> Void) throws {
        let lockURL = logURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = Darwin.close(descriptor) }
        while flock(descriptor, waitForLock ? LOCK_EX : LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EINTR else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        }
        try operation()
    }

    /// Keeps only complete newest log lines. If the byte boundary splits a
    /// line, starting after its newline also discards any split UTF-8 scalar.
    static func retainedLogSuffix(_ data: Data, maxBytes: Int) -> Data {
        guard maxBytes > 0, data.count > maxBytes else {
            return maxBytes > 0 ? data : Data()
        }

        let suffix = data.suffix(maxBytes)
        if data[data.index(before: suffix.startIndex)] == 0x0A {
            return Data(suffix)
        }
        guard let firstNewline = suffix.firstIndex(of: 0x0A) else {
            return Data()
        }
        let firstCompleteLine = suffix.index(after: firstNewline)
        return Data(suffix[firstCompleteLine...])
    }

    static func diagnosticLogURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let overridePath = environment[logPathOverrideEnvironmentKey],
            !overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: overridePath)
        }

        if isRunningUnderXCTest(environment: environment) {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("MacParakeetTests", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("dictation-audio-\(ProcessInfo.processInfo.processIdentifier).log")
        }

        return URL(fileURLWithPath: AppPaths.logsDir, isDirectory: true)
            .appendingPathComponent("dictation-audio.log")
    }

    private static func isRunningUnderXCTest(environment: [String: String]) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }

        return Bundle.allBundles.contains { bundle in
            bundle.bundlePath.hasSuffix(".xctest")
        }
    }

    private static func safeTransportLabel(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        default: return "unknown"
        }
    }
}
