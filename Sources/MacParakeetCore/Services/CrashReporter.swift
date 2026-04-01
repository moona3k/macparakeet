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

    /// 4 KB buffer for formatting crash report in the signal handler.
    private static var buffer = [CChar](repeating: 0, count: 4096)

    /// Pre-resolved crash file path as a C string.
    private static var crashFilePath = [CChar](repeating: 0, count: 512)

    /// Pre-snapshotted metadata (set once at install, read in signal handler).
    private static var appVersion = [CChar](repeating: 0, count: 64)
    private static var osVersion = [CChar](repeating: 0, count: 32)
    private static var machOUUID = [CChar](repeating: 0, count: 48)
    private static var aslrSlide = [CChar](repeating: 0, count: 24)

    /// Alternate signal stack for handling stack overflow crashes.
    private static var altStack = [UInt8](repeating: 0, count: Int(SIGSTKSZ))

    /// Flag to prevent concurrent signal handler entry from multiple threads.
    /// Volatile int32 — set via OSAtomicTestAndSet which is async-signal-safe.
    private static var handlerEntered: Int32 = 0

    /// Previous ObjC exception handler (for chaining).
    private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

    /// Signals to catch.
    private static let signals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE]

    /// Signal name lookup (async-signal-safe — no allocation).
    private static func signalName(_ sig: Int32) -> StaticString {
        switch sig {
        case SIGSEGV: return "SIGSEGV"
        case SIGABRT: return "SIGABRT"
        case SIGBUS:  return "SIGBUS"
        case SIGILL:  return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGFPE:  return "SIGFPE"
        default:      return "UNKNOWN"
        }
    }

    // MARK: - Install (call once, before NSApplication.run())

    /// Install crash handlers. Call as the very first line of `main()`.
    /// This method has no dependencies on any services or protocols.
    public static func install() {
        // 1. Ensure the crash directory exists
        let dir = AppPaths.appSupportDir
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // 2. Pre-resolve crash file path to C string
        let path = crashReportPath
        path.withCString { ptr in
            strncpy(&crashFilePath, ptr, crashFilePath.count - 1)
        }

        // 3. Snapshot version strings into static buffers
        let info = SystemInfo.current
        info.appVersion.withCString { ptr in
            strncpy(&appVersion, ptr, appVersion.count - 1)
        }
        info.macOSVersion.withCString { ptr in
            strncpy(&osVersion, ptr, osVersion.count - 1)
        }

        // 4. Capture Mach-O UUID from main executable load commands
        snapshotMachOUUID()

        // 5. Capture ASLR slide
        let slide = _dyld_get_image_vmaddr_slide(0)
        let slideStr = String(format: "0x%lx", UInt(bitPattern: slide))
        slideStr.withCString { ptr in
            strncpy(&aslrSlide, ptr, aslrSlide.count - 1)
        }

        // 6. Set up alternate signal stack (handles stack overflow crashes)
        altStack.withUnsafeMutableBufferPointer { buf in
            var ss = stack_t()
            ss.ss_sp = UnsafeMutableRawPointer(buf.baseAddress!)
            ss.ss_size = buf.count
            ss.ss_flags = 0
            sigaltstack(&ss, nil)
        }

        // 7. Register signal handlers via sigaction with SA_ONSTACK
        for sig in signals {
            var action = sigaction()
            action.__sigaction_u = unsafeBitCast(
                signalHandler as @convention(c) (Int32) -> Void,
                to: __sigaction_u.self
            )
            action.sa_flags = Int32(SA_ONSTACK)
            sigaction(sig, &action, nil)
        }

        // 8. Register ObjC uncaught exception handler
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(objcExceptionHandler)
    }

    // MARK: - Signal Handler (@convention(c), async-signal-safe)

    private static let signalHandler: @convention(c) (Int32) -> Void = { sig in
        // Guard: only first thread proceeds (OSAtomicTestAndSet is async-signal-safe)
        guard OSAtomicTestAndSet(0, &handlerEntered) == false else { return }

        // Format crash report into pre-allocated buffer using only
        // async-signal-safe-on-Darwin functions (snprintf, open, write, close).
        var offset = 0
        let bufSize = buffer.count

        func appendBytes(_ s: UnsafePointer<CChar>) {
            let len = Int(strlen(s))
            guard offset + len < bufSize else { return }
            buffer.withUnsafeMutableBufferPointer { buf in
                memcpy(buf.baseAddress! + offset, s, len)
            }
            offset += len
        }

        func appendLine(_ key: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) {
            appendBytes(key)
            appendBytes(value)
            buffer[offset] = 0x0A // '\n'
            offset += 1
        }

        // Manual decimal formatting (async-signal-safe, no snprintf)
        func appendInt(_ key: UnsafePointer<CChar>, _ value: Int) {
            appendBytes(key)
            var digits: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                         CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                         CChar, CChar, CChar, CChar, CChar) =
                (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
            var n = value < 0 ? -value : value
            var pos = 19
            withUnsafeMutablePointer(to: &digits) { ptr in
                let base = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                repeat {
                    base[pos] = CChar(0x30 + (n % 10)) // '0' = 0x30
                    n /= 10
                    pos -= 1
                } while n > 0
                if value < 0 { base[pos] = 0x2D; pos -= 1 } // '-'
                base[20] = 0
                appendBytes(base + pos + 1)
            }
            buffer[offset] = 0x0A
            offset += 1
        }

        // Manual hex formatting (async-signal-safe, no snprintf)
        func appendHex(_ value: UInt) {
            let hexChars: StaticString = "0123456789abcdef"
            var hexBuf: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                         CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                         CChar, CChar, CChar) =
                (0x30, 0x78, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0) // "0x"
            var n = value
            var pos = 17
            withUnsafeMutablePointer(to: &hexBuf) { ptr in
                let base = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                hexChars.withUTF8Buffer { chars in
                    repeat {
                        base[pos] = CChar(bitPattern: chars[Int(n & 0xF)])
                        n >>= 4
                        pos -= 1
                    } while n > 0
                }
                // Shift "0x" prefix to just before the digits
                base[pos - 1] = 0x78 // 'x'
                base[pos - 2] = 0x30 // '0'
                base[18] = 0x0A // '\n'
                let start = pos - 2
                let len = 19 - start
                guard offset + len < bufSize else { return }
                buffer.withUnsafeMutableBufferPointer { buf in
                    memcpy(buf.baseAddress! + offset, base + start, len)
                }
                offset += len
            }
        }

        appendLine("crash_type: ", "signal")
        appendInt("signal: ", Int(sig))

        // Signal name
        switch sig {
        case SIGSEGV: appendLine("name: ", "SIGSEGV")
        case SIGABRT: appendLine("name: ", "SIGABRT")
        case SIGBUS:  appendLine("name: ", "SIGBUS")
        case SIGILL:  appendLine("name: ", "SIGILL")
        case SIGTRAP: appendLine("name: ", "SIGTRAP")
        case SIGFPE:  appendLine("name: ", "SIGFPE")
        default:      appendLine("name: ", "UNKNOWN")
        }

        appendInt("timestamp: ", time(nil))
        appendLine("app_ver: ", &appVersion)
        appendLine("os_ver: ", &osVersion)
        appendLine("uuid: ", &machOUUID)
        appendLine("slide: ", &aslrSlide)
        appendBytes("--- stack ---\n")

        // Stack trace via backtrace() — not strictly async-signal-safe but
        // pragmatically used by all major crash reporters (Sentry, PLCrashReporter).
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let frameCount = backtrace(&frames, Int32(frames.count))
        for i in 0..<Int(frameCount) {
            guard offset + 24 < bufSize else { break }
            if let addr = frames[i] {
                appendHex(UInt(bitPattern: addr))
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

        // Restore default handler and re-raise so macOS gets the crash
        Darwin.signal(sig, SIG_DFL)
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
        lines.append("reason: \(reason)")
        lines.append("--- stack ---")

        for address in exception.callStackReturnAddresses {
            lines.append(String(format: "0x%lx", address.uintValue))
        }

        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(toFile: crashReportPath, atomically: true, encoding: .utf8)

        // Chain to previous handler
        previousExceptionHandler?(exception)
    }

    // MARK: - Mach-O UUID Extraction

    private static func snapshotMachOUUID() {
        guard let header = _dyld_get_image_header(0) else {
            strncpy(&machOUUID, "unknown", machOUUID.count - 1)
            return
        }

        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let cmd = cursor.assumingMemoryBound(to: load_command.self).pointee
            if cmd.cmd == LC_UUID {
                // uuid_command: load_command (8 bytes) + uuid (16 bytes)
                let uuidPtr = cursor.advanced(by: 8).assumingMemoryBound(to: UInt8.self)
                let bytes = (0..<16).map { uuidPtr[$0] }
                let formatted = String(format:
                    "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15])
                formatted.withCString { ptr in
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
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8),
              !content.isEmpty else {
            return nil
        }

        let lines = content.components(separatedBy: "\n")
        var fields = [String: String]()
        var stackTrace = [String]()
        var inStack = false

        for line in lines {
            if line == "--- stack ---" {
                inStack = true
                continue
            }
            if inStack {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("0x") {
                    stackTrace.append(trimmed)
                }
            } else if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
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
            reason: fields["reason"],
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
            stackTrace: stackTraceString
        ))

        // Always delete — even if telemetry is disabled (send() handles opt-out)
        deleteCrashFile(at: path)
    }

    private static func deleteCrashFile(at path: String? = nil) {
        try? FileManager.default.removeItem(atPath: path ?? crashReportPath)
    }
}
