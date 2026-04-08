import Foundation
import Darwin
import MachO

/// Lightweight crash reporter that persists crash data to disk via async-signal-safe
/// POSIX I/O, then sends it as a telemetry event on next launch.
///
/// Architecture (same as Sentry/PLCrashReporter core):
///   1. `install()` — registers signal handlers + ObjC exception handler at app startup
///   2. Signal handler — writes crash report to disk using pre-allocated buffers
///   3. `sendPendingReport(via:)` — reads crash file on next launch, sends telemetry event
///
/// Known limitations:
/// - `backtrace()` is not strictly async-signal-safe (can deadlock on dyld lock).
///   Accepted: same tradeoff all major crash reporters make. Worst case: one report lost.
/// - `SIGKILL` (OOM kills) cannot be caught — fundamental OS limitation.
/// - Swift async backtraces not captured — only physical thread stack.
/// - Framework crash addresses need their own image slide for full symbolication.
public final class CrashReporter {

    // MARK: - Pre-Allocated Static Buffers (signal-safe)
    //
    // All mutable statics are written once in install() (main thread, before run loop)
    // and read in the signal handler (crash context). This is safe because install()
    // completes before any signal can fire, and the signal handler is guarded by an
    // atomic compare-and-swap to ensure single entry.

    /// 4 KB buffer for formatting crash report in the signal handler.
    nonisolated(unsafe) private static var buffer = [CChar](repeating: 0, count: 4096)

    /// Pre-resolved crash file path as a C string.
    nonisolated(unsafe) private static var crashFilePath = [CChar](repeating: 0, count: 512)

    /// Pre-snapshotted metadata (set once at install, read in signal handler).
    nonisolated(unsafe) private static var appVersion = [CChar](repeating: 0, count: 64)
    nonisolated(unsafe) private static var osVersion = [CChar](repeating: 0, count: 32)
    nonisolated(unsafe) private static var machOUUID = [CChar](repeating: 0, count: 48)
    nonisolated(unsafe) private static var aslrSlide = [CChar](repeating: 0, count: 24)

    /// Alternate signal stack for handling stack overflow crashes.
    nonisolated(unsafe) private static var altStack = [UInt8](repeating: 0, count: Int(SIGSTKSZ))

    /// Pre-allocated frame buffer for backtrace() — avoids heap allocation in signal handler.
    nonisolated(unsafe) private static var framesBuffer = [UnsafeMutableRawPointer?](repeating: nil, count: 64)

    /// Atomic flag to prevent concurrent signal handler entry from multiple threads.
    nonisolated(unsafe) private static var handlerEntered: Int32 = 0

    /// Previous ObjC exception handler (for chaining).
    nonisolated(unsafe) private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

    /// Whether install() has been called (prevents double-install).
    nonisolated(unsafe) private static var installed = false

    /// Signals to catch.
    private static let signals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE]

    // MARK: - Install (call once, before NSApplication.run())

    /// Install crash handlers. Call as the very first line of `main()`.
    /// This method has no dependencies on any services or protocols.
    public static func install() {
        guard !installed else { return }
        installed = true

        // 1. Ensure the crash directory exists
        let dir = AppPaths.appSupportDir
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // 2. Pre-resolve crash file path to C string
        let path = crashReportPath
        _ = path.withCString { ptr in
            strncpy(&crashFilePath, ptr, crashFilePath.count - 1)
        }
        crashFilePath[crashFilePath.count - 1] = 0

        // 3. Snapshot version strings into static buffers
        let info = SystemInfo.current
        _ = info.appVersion.withCString { ptr in
            strncpy(&appVersion, ptr, appVersion.count - 1)
        }
        appVersion[appVersion.count - 1] = 0

        _ = info.macOSVersion.withCString { ptr in
            strncpy(&osVersion, ptr, osVersion.count - 1)
        }
        osVersion[osVersion.count - 1] = 0

        // 4. Capture Mach-O UUID from main executable load commands
        snapshotMachOUUID()

        // 5. Capture ASLR slide
        let slide = _dyld_get_image_vmaddr_slide(0)
        let slideStr = String(format: "0x%lx", UInt(bitPattern: slide))
        _ = slideStr.withCString { ptr in
            strncpy(&aslrSlide, ptr, aslrSlide.count - 1)
        }
        aslrSlide[aslrSlide.count - 1] = 0

        // 6. Set up alternate signal stack (handles stack overflow crashes)
        altStack.withUnsafeMutableBufferPointer { buf in
            var ss = stack_t()
            ss.ss_sp = UnsafeMutableRawPointer(buf.baseAddress!)
            ss.ss_size = buf.count
            ss.ss_flags = 0
            sigaltstack(&ss, nil)
        }

        // 7. Register signal handlers via sigaction
        // SA_ONSTACK:   use alternate stack (handles stack overflow)
        // SA_RESETHAND: reset to SIG_DFL on entry (handler crash → default termination)
        // SA_NODEFER:   don't block the signal during handler (belt-and-suspenders with SA_RESETHAND)
        for sig in signals {
            var action = sigaction()
            action.__sigaction_u = unsafeBitCast(
                signalHandler as @convention(c) (Int32) -> Void,
                to: __sigaction_u.self
            )
            action.sa_flags = Int32(SA_ONSTACK) | Int32(SA_RESETHAND) | Int32(SA_NODEFER)
            sigaction(sig, &action, nil)
        }

        // 8. Register ObjC uncaught exception handler
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(objcExceptionHandler)
    }

    // MARK: - Signal Handler (@convention(c), async-signal-safe)
    //
    // Uses only async-signal-safe functions per Darwin's man sigaction:
    // snprintf, open, write, close, backtrace, raise, sigaction, time.

    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        // Guard: only first thread proceeds
        guard OSAtomicCompareAndSwap32Barrier(0, 1, &handlerEntered) else {
            // Second concurrent thread: re-raise so it terminates via SIG_DFL
            // rather than resuming from the crash site.
            Darwin.raise(sig)
            return
        }

        // snprintf is async-signal-safe on Darwin (per man sigaction).
        // Use it for all formatting — much safer than manual int/hex formatters.
        var offset = 0
        let bufSize = buffer.count

        // Helper: append formatted string to buffer via snprintf
        func append(_ s: UnsafePointer<CChar>) {
            let len = Int(strlen(s))
            guard offset + len < bufSize else { return }
            _ = buffer.withUnsafeMutableBufferPointer { buf in
                memcpy(buf.baseAddress! + offset, s, len)
            }
            offset += len
        }

        // Helper: vsnprintf into buffer at current offset.
        // snprintf is async-signal-safe on Darwin per man sigaction, but Swift marks
        // C variadic functions as unavailable. Use vsnprintf via withVaList instead.
        func snprintfInto(_ format: UnsafePointer<CChar>, _ args: CVarArg...) {
            let remaining = bufSize - offset
            guard remaining > 0 else { return }
            let written = withVaList(args) { vaList in
                buffer.withUnsafeMutableBufferPointer { buf in
                    Int(vsnprintf(buf.baseAddress! + offset, remaining, format, vaList))
                }
            }
            if written > 0 { offset += min(written, remaining - 1) }
        }

        append("crash_type: signal\n")
        snprintfInto("signal: %d\n", sig)

        // Signal name
        append("name: ")
        switch sig {
        case SIGSEGV: append("SIGSEGV")
        case SIGABRT: append("SIGABRT")
        case SIGBUS:  append("SIGBUS")
        case SIGILL:  append("SIGILL")
        case SIGTRAP: append("SIGTRAP")
        case SIGFPE:  append("SIGFPE")
        default:      append("UNKNOWN")
        }
        append("\n")

        snprintfInto("timestamp: %ld\n", time(nil))

        // Append pre-snapshotted C strings
        append("app_ver: "); append(&appVersion); append("\n")
        append("os_ver: "); append(&osVersion); append("\n")
        append("uuid: "); append(&machOUUID); append("\n")
        append("slide: "); append(&aslrSlide); append("\n")
        append("--- stack ---\n")

        // Stack trace via backtrace() — not strictly async-signal-safe but
        // pragmatically used by all major crash reporters (Sentry, PLCrashReporter).
        // Uses pre-allocated framesBuffer to avoid heap allocation.
        let frameCount = backtrace(&framesBuffer, Int32(framesBuffer.count))
        for i in 0..<Int(frameCount) {
            guard bufSize - offset > 20 else { break }
            if let addr = framesBuffer[i] {
                snprintfInto("0x%lx\n", UInt(bitPattern: addr))
            }
        }

        // Write to disk via POSIX I/O
        let fd = Darwin.open(&crashFilePath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            buffer.withUnsafeBufferPointer { buf in
                _ = Darwin.write(fd, buf.baseAddress!, offset)
            }
            Darwin.close(fd)
        }

        // SA_RESETHAND already restored SIG_DFL before entering this handler.
        // Just re-raise to let the OS default handler produce the crash report.
        Darwin.raise(sig)
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
        lines.append("app_ver: \(String(cString: &appVersion))")
        lines.append("os_ver: \(String(cString: &osVersion))")
        lines.append("uuid: \(String(cString: &machOUUID))")
        lines.append("slide: \(String(cString: &aslrSlide))")
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
        OSAtomicCompareAndSwap32Barrier(0, 1, &handlerEntered)

        // Chain to previous handler
        previousExceptionHandler?(exception)
    }

    // MARK: - Mach-O UUID Extraction

    private static func snapshotMachOUUID() {
        guard let header = _dyld_get_image_header(0) else {
            strncpy(&machOUUID, "unknown", machOUUID.count - 1)
            return
        }

        guard header.pointee.magic == MH_MAGIC_64 else {
            strncpy(&machOUUID, "unknown", machOUUID.count - 1)
            return
        }

        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let cmd = cursor.assumingMemoryBound(to: load_command.self).pointee
            guard cmd.cmdsize >= UInt32(MemoryLayout<load_command>.size) else { break }
            if cmd.cmd == LC_UUID, cmd.cmdsize >= 24 {
                // uuid_command: load_command (8 bytes) + uuid (16 bytes)
                let uuidPtr = cursor.advanced(by: 8).assumingMemoryBound(to: UInt8.self)
                let bytes = (0..<16).map { uuidPtr[$0] }
                let formatted = String(format:
                    "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15])
                _ = formatted.withCString { ptr in
                    strncpy(&machOUUID, ptr, machOUUID.count - 1)
                }
                return
            }
            cursor = cursor.advanced(by: Int(cmd.cmdsize))
        }
        strncpy(&machOUUID, "unknown", machOUUID.count - 1)
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
            stackTrace: stackTrace
        )
    }

    /// Send any pending crash report as a telemetry event, then delete the file.
    /// Call after TelemetryService is initialized.
    public static func sendPendingReport(via telemetry: TelemetryServiceProtocol) {
        sendPendingReport(via: telemetry, from: crashReportPath)
    }

    /// Internal variant with injectable path for testing.
    static func sendPendingReport(via telemetry: TelemetryServiceProtocol, from path: String) {
        guard let report = loadPendingReport(from: path) else { return }

        let stackTraceString = report.stackTrace.joined(separator: "\n")

        telemetry.send(.crashOccurred(
            crashType: report.crashType,
            signal: report.signal,
            name: report.name,
            crashTimestamp: report.timestamp,
            crashAppVer: report.appVersion,
            crashOsVer: report.osVersion,
            uuid: report.uuid,
            slide: report.slide,
            reason: report.reason,
            stackTrace: stackTraceString
        ))

        // Always delete — even if telemetry is disabled (send() handles opt-out)
        deleteCrashFile(at: path)
    }

    private static func deleteCrashFile(at path: String? = nil) {
        try? FileManager.default.removeItem(atPath: path ?? crashReportPath)
    }
}
