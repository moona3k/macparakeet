import Foundation
import Darwin
import MachO
import MacParakeetObjCShims

/// Lightweight crash reporter that persists crash data to disk, then sends it
/// as a telemetry event on next launch.
///
/// Architecture:
///   1. `install()` — snapshots metadata (Swift, normal context), then installs
///      the fatal-signal handler + ObjC exception handler at app startup
///   2. Fatal-signal handler — `MPKInstallCrashSignalHandler` (see
///      `MPKCrashSignalHandler.c`) is a plain-C, allocation-free handler that
///      writes a minimal crash report (metadata, `si_code`, fault address,
///      interrupted PC) to disk *before* attempting a best-effort backtrace.
///      No Swift or Objective-C runtime call happens inside this handler.
///   3. `sendPendingReport(via:)` — reads crash file on next launch, sends telemetry event
///
/// Known limitations:
/// - `backtrace()` (called from the C handler) is not strictly async-signal-safe
///   (can deadlock on dyld lock). This is an accepted, known limitation of this
///   reporter, not a safety guarantee — other crash reporters (Sentry,
///   PLCrashReporter) making the same tradeoff doesn't make it safe here. It is
///   why the minimal report is written and durable on disk *before* the
///   backtrace is attempted: worst case on a hang is a report with metadata,
///   `si_code`, fault address and PC but no stack.
/// - `SIGKILL` (OOM kills) cannot be caught — fundamental OS limitation.
/// - Swift async backtraces not captured — only physical thread stack.
/// - Framework crash addresses need their own image slide for full symbolication.
public final class CrashReporter {

    // MARK: - Pre-Snapshotted Metadata
    //
    // Written once in install() (main thread, before the run loop starts) and
    // read only from the ObjC exception handler (normal Swift context, not a
    // signal handler). The fatal-signal handler itself is pure C and keeps its
    // own copies internally — see MPKCrashSignalHandler.c.

    nonisolated(unsafe) private static var appVersionString = ""
    nonisolated(unsafe) private static var osVersionString = ""
    nonisolated(unsafe) private static var machOUUIDString = ""
    nonisolated(unsafe) private static var aslrSlideString = ""

    /// Alternate signal stack for handling stack overflow crashes.
    nonisolated(unsafe) private static var altStack = [UInt8](repeating: 0, count: Int(SIGSTKSZ))

    /// Previous ObjC exception handler (for chaining).
    nonisolated(unsafe) private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

    /// Whether install() has been called (prevents double-install).
    nonisolated(unsafe) private static var installed = false

    // MARK: - Install (call once, before NSApplication.run())

    /// Install crash handlers. Call as the very first line of `main()`.
    /// This method has no dependencies on any services or protocols.
    public static func install() {
        guard !installed else { return }
        installed = true

        // 1. Ensure the crash directory exists
        guard prepareCrashDirectory(at: AppPaths.appSupportDir) else {
            installed = false
            return
        }

        // 2. Snapshot version/image metadata as plain Swift strings (normal
        // context — used to build the ObjC exception report and passed as
        // C strings to the C signal-handler installer below).
        let info = SystemInfo.current
        appVersionString = info.appVersion
        osVersionString = info.macOSVersion
        machOUUIDString = snapshotMachOUUID()
        let slide = _dyld_get_image_vmaddr_slide(0)
        aslrSlideString = String(format: "0x%lx", UInt(bitPattern: slide))

        // 3. Set up alternate signal stack (handles stack overflow crashes)
        altStack.withUnsafeMutableBufferPointer { buf in
            var ss = stack_t()
            ss.ss_sp = UnsafeMutableRawPointer(buf.baseAddress!)
            ss.ss_size = buf.count
            ss.ss_flags = 0
            sigaltstack(&ss, nil)
        }

        // 4. Install the C fatal-signal handler (MPKCrashSignalHandler.c).
        // It copies each C string into its own fixed internal buffer, so
        // none of these pointers need to outlive this call.
        crashReportPath.withCString { pathPtr in
            appVersionString.withCString { appVerPtr in
                osVersionString.withCString { osVerPtr in
                    machOUUIDString.withCString { uuidPtr in
                        aslrSlideString.withCString { slidePtr in
                            var metadata = MPKCrashMetadata(
                                app_version: appVerPtr,
                                os_version: osVerPtr,
                                mach_uuid: uuidPtr,
                                aslr_slide: slidePtr
                            )
                            MPKInstallCrashSignalHandler(pathPtr, &metadata)
                        }
                    }
                }
            }
        }

        // 5. Register ObjC uncaught exception handler
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(objcExceptionHandler)
    }

    // MARK: - ObjC Exception Handler (normal Swift context, NOT signal handler)

    private static let objcExceptionHandler: @convention(c) (NSException) -> Void = { exception in
        let name = exception.name.rawValue
        let reason = TelemetryErrorClassifier.errorDetail(
            NSError(domain: name, code: 0, userInfo: [NSLocalizedDescriptionKey: exception.reason ?? ""])
        )

        // Build crash report as a Swift string (safe here — not in signal handler)
        var lines = [String]()
        lines.append("crash_type: exception")
        lines.append("signal: exception")
        lines.append("name: \(name)")
        lines.append("timestamp: \(Int(Date().timeIntervalSince1970))")
        lines.append("app_ver: \(appVersionString)")
        lines.append("os_ver: \(osVersionString)")
        lines.append("uuid: \(machOUUIDString)")
        lines.append("slide: \(aslrSlideString)")
        let safeReason = reason.replacingOccurrences(of: "\n", with: "\\n")
                               .replacingOccurrences(of: "\r", with: "\\r")
        lines.append("reason: \(safeReason)")
        lines.append("--- stack ---")

        for address in exception.callStackReturnAddresses {
            lines.append(String(format: "0x%lx", address.uintValue))
        }

        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(toFile: crashReportPath, atomically: true, encoding: .utf8)

        // Prevent the subsequent SIGABRT (from abort() after uncaught exception)
        // from overwriting this richer exception report with a generic signal report.
        MPKMarkCrashHandlerEntered()

        // Chain to previous handler
        previousExceptionHandler?(exception)
    }

    private static func prepareCrashDirectory(at dir: String) -> Bool {
        var isDir: ObjCBool = false
        do {
            if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
                if !isDir.boolValue {
                    try FileManager.default.removeItem(atPath: dir)
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                }
            } else {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            return true
        } catch {
            fputs("MacParakeet CrashReporter: failed to prepare crash directory at \(dir): \(error)\n", stderr)
            return false
        }
    }

    // MARK: - Mach-O UUID Extraction

    private static func snapshotMachOUUID() -> String {
        guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 else {
            return "unknown"
        }

        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let cmd = cursor.assumingMemoryBound(to: load_command.self).pointee
            guard cmd.cmdsize >= UInt32(MemoryLayout<load_command>.size) else { break }
            if cmd.cmd == LC_UUID, cmd.cmdsize >= 24 {
                // uuid_command: load_command (8 bytes) + uuid (16 bytes)
                let uuidPtr = cursor.advanced(by: 8).assumingMemoryBound(to: UInt8.self)
                let bytes = (0..<16).map { uuidPtr[$0] }
                return String(format:
                    "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15])
            }
            cursor = cursor.advanced(by: Int(cmd.cmdsize))
        }
        return "unknown"
    }

    // MARK: - Crash Report Recovery (normal Swift, called on next launch)

    /// Parsed crash report from a previous session.
    public struct CrashReport {
        public let crashType: String    // "signal" or "exception"
        public let signal: String       // e.g. "11" or "exception"
        public let name: String         // e.g. "SIGSEGV" or "NSInvalidArgumentException"
        public let timestamp: String    // Unix timestamp
        public let appVersion: String
        public let osVersion: String
        public let uuid: String
        public let slide: String
        public let reason: String?      // Only for exceptions
        public let stackTrace: [String] // Hex addresses
        /// Signal's `si_code` (fault subtype). Signal crashes only; absent
        /// from exceptions and older report files.
        public let siCode: String?
        /// Interrupted instruction pointer at the moment of the fault, as
        /// `0x`-prefixed hex. Absent when the handler didn't recognize the
        /// CPU architecture, for exceptions, and for older report files.
        public let pc: String?
        /// Faulting memory address (`siginfo_t.si_addr`), as `0x`-prefixed
        /// hex. Signal crashes only; absent from exceptions and older report files.
        public let faultAddr: String?
    }

    /// Path to the crash report file.
    public static var crashReportPath: String {
        AppPaths.appSupportDir + "/crash_report.txt"
    }

    /// Load a pending crash report from disk, if one exists.
    public static func loadPendingReport(from path: String? = nil) -> CrashReport? {
        let filePath = path ?? crashReportPath
        // Use tolerant UTF-8 decoding: a crash mid-write could truncate a
        // multi-byte character, and strict .utf8 would discard the entire report.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              !data.isEmpty else {
            return nil
        }
        let content = String(decoding: data, as: UTF8.self)

        let lines = content.components(separatedBy: "\n")
        var fields = [String: String]()
        var stackTrace = [String]()
        var inStack = false

        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "--- stack ---" {
                inStack = true
                continue
            }
            if inStack {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("0x"), stackTrace.count < 256 {
                    stackTrace.append(trimmed)
                }
            } else if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                fields[key] = value
            }
        }

        guard let crashType = fields["crash_type"],
              let signal = fields["signal"],
              let name = fields["name"],
              let timestamp = fields["timestamp"],
              let appVer = fields["app_ver"] else {
            return nil
        }

        return CrashReport(
            crashType: crashType,
            signal: signal,
            name: name,
            timestamp: timestamp,
            appVersion: appVer,
            osVersion: fields["os_ver"] ?? "",
            uuid: fields["uuid"] ?? "",
            slide: fields["slide"] ?? "",
            reason: fields["reason"]?
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\r", with: "\r"),
            stackTrace: stackTrace,
            siCode: validatedDecimal(fields["si_code"]),
            pc: validatedHexAddress(fields["pc"]),
            faultAddr: validatedHexAddress(fields["fault_addr"])
        )
    }

    /// Accepts only a bounded, optionally negative decimal integer. Corrupt
    /// or oversized values are dropped (return `nil`) rather than forwarded
    /// as arbitrary text — this field can come from a report file written by
    /// a crashing process mid-corruption.
    private static func validatedDecimal(_ raw: String?, maxDigits: Int = 9) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let digits = raw.hasPrefix("-") ? raw.dropFirst() : raw[raw.startIndex...]
        guard !digits.isEmpty, digits.count <= maxDigits, digits.allSatisfy(\.isNumber) else {
            return nil
        }
        return raw
    }

    /// Accepts only a bounded `0x`-prefixed hex address (up to 64 bits).
    /// Corrupt or oversized values are dropped (return `nil`) rather than
    /// forwarded as arbitrary text.
    private static func validatedHexAddress(_ raw: String?, maxHexDigits: Int = 16) -> String? {
        guard let raw, raw.hasPrefix("0x") else { return nil }
        let digits = raw.dropFirst(2)
        guard !digits.isEmpty, digits.count <= maxHexDigits, digits.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return raw
    }

    /// Send any pending crash report as a telemetry event. Delete the file only
    /// when telemetry reports that the event was delivered or intentionally dropped.
    /// Call after TelemetryService is initialized.
    public static func sendPendingReport(via telemetry: TelemetryServiceProtocol) async {
        await sendPendingReport(via: telemetry, from: crashReportPath)
    }

    /// Internal variant with injectable path for testing.
    static func sendPendingReport(via telemetry: TelemetryServiceProtocol, from path: String) async {
        guard let report = loadPendingReport(from: path) else { return }

        let stackTraceString = report.stackTrace.joined(separator: "\n")

        let delivered = await telemetry.sendAndFlush(.crashOccurred(
            crashType: report.crashType,
            signal: report.signal,
            name: report.name,
            crashTimestamp: report.timestamp,
            crashAppVer: report.appVersion,
            crashOsVer: report.osVersion,
            uuid: report.uuid,
            slide: report.slide,
            reason: report.reason,
            stackTrace: stackTraceString,
            siCode: report.siCode,
            pc: report.pc,
            faultAddr: report.faultAddr
        ))

        if delivered {
            // Delete only after telemetry has either been flushed or intentionally dropped by opt-out.
            deleteCrashFile(at: path)
        }
    }

    private static func deleteCrashFile(at path: String? = nil) {
        try? FileManager.default.removeItem(atPath: path ?? crashReportPath)
    }
}
