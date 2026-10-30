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
///   3. `sendPendingReport(via:)` — claims previous-process reports on next
///      launch and sends them under the existing telemetry consent policy.
/// Each process writes to its own bounded spool entry. A lifetime filesystem
/// lease keeps uploaders and retention cleanup away from live writers.
///
/// Known limitations:
/// - `backtrace()` (called from the C handler) is not strictly async-signal-safe
///   (can deadlock on dyld lock). This is an accepted, known limitation of this
///   reporter, not a safety guarantee — other crash reporters (Sentry,
///   PLCrashReporter) making the same tradeoff doesn't make it safe here. It is
///   why backtrace runs only after a complete minimum report write. A hang
///   can leave metadata, `si_code`, fault address and PC without a stack.
/// - Persistence is best-effort, not durable: a successful `write`/`close` in
///   the C handler means the OS accepted the bytes, not that they survived a
///   power loss (there is no `fsync`). Two threads crashing concurrently is
///   handled the same way — only the first claims the report; the second
///   re-raises immediately with no report of its own, rather than sleeping or
///   spinning to wait its turn.
/// - `sigaltstack` is installed only on the main thread during startup. A worker thread that overflows its own
///   stack has no alternate stack to deliver the signal on, so that crash is
///   not caught by this reporter at all.
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
    // The stable lease must outlive all signal/exception writes. It is never
    // released by the next-launch uploader in this process.
    nonisolated(unsafe) private static var activeReportLease: CrashReportStore.Lease?
    private static let drain = PendingReportDrain()

    private static var reportStore: CrashReportStore {
        CrashReportStore(appSupportURL: URL(fileURLWithPath: AppPaths.appSupportDir, isDirectory: true))
    }

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

        guard let reservation = reportStore.reserve(), reservation.reportURL.path.utf8.count < 512 else {
            installed = false
            return
        }
        activeReportLease = reservation

        // 2. Snapshot version/image metadata as plain Swift strings (normal
        // context — used to build the ObjC exception report and passed as
        // C strings to the C signal-handler installer below).
        let info = SystemInfo.current
        appVersionString = String(info.appVersion.prefix(63))
        osVersionString = String(info.macOSVersion.prefix(31))
        machOUUIDString = snapshotMachOUUID()
        let slide = _dyld_get_image_vmaddr_slide(0)
        aslrSlideString = String(format: "0x%lx", UInt(bitPattern: slide))

        // 3. Install the C fatal-signal handler (MPKCrashSignalHandler.c).
        // It copies each C string into its own fixed internal buffer, so
        // none of these pointers need to outlive this call. It also installs
        // the alternate signal stack itself, backed by a C static-lifetime
        // buffer rather than a Swift `Array`, so the stack's storage address
        // is fixed for the process's lifetime regardless of Swift-side
        // retain/copy behavior.
        var systemMetadata = MPKCrashSystemMetadata()
        MPKReadCrashSystemMetadata(&systemMetadata)
        let osBuild = withUnsafeBytes(of: systemMetadata.os_build) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let cacheUUID = withUnsafeBytes(of: systemMetadata.shared_cache_uuid) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let cacheSlide = withUnsafeBytes(of: systemMetadata.shared_cache_slide) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let values = [reservation.reportURL.path, appVersionString, osVersionString, machOUUIDString,
                      aslrSlideString, UUID().uuidString.lowercased(), Observability.processSessionID,
                      osBuild, cacheUUID, cacheSlide]
        withCStringPointers(values) { pointers in
            var metadata = MPKCrashMetadata(
                app_version: pointers[1], os_version: pointers[2], mach_uuid: pointers[3],
                aslr_slide: pointers[4], crash_id: pointers[5], crash_session: pointers[6],
                os_build: pointers[7], shared_cache_uuid: pointers[8], shared_cache_slide: pointers[9]
            )
            MPKInstallCrashSignalHandler(pointers[0], &metadata)
        }

        // 4. Register ObjC uncaught exception handler
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(objcExceptionHandler)
    }

    // MARK: - ObjC Exception Handler (normal Swift context, NOT signal handler)

    private static let objcExceptionHandler: @convention(c) (NSException) -> Void = { exception in
        guard let reportPath = activeReportLease?.reportURL.path else { return }
        let name = String(exception.name.rawValue.prefix(128))
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
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
        var context = [CChar](repeating: 0, count: 8192)
        let contextCount = context.withUnsafeMutableBufferPointer { buffer in
            MPKCopyCrashContext(buffer.baseAddress, buffer.count)
        }
        if contextCount > 0 {
            let count = min(Int(contextCount), context.count)
            let data = context.withUnsafeBytes { Data($0.prefix(count)) }
            lines.append(String(decoding: data, as: UTF8.self))
        }
        lines.append("--- stack ---")

        for address in exception.callStackReturnAddresses.prefix(64) {
            lines.append(String(format: "0x%lx", address.uintValue))
        }

        let content = lines.joined(separator: "\n") + "\n"
        // Strings and frame count above are bounded independently; retain a
        // final byte ceiling so corrupt exception metadata cannot grow the spool.
        let data = Data(content.utf8.prefix(CrashReportStore.maximumReportBytes))
        if (try? data.write(to: URL(fileURLWithPath: reportPath), options: [.atomic])) != nil {
            // Prevent the subsequent SIGABRT (from abort() after uncaught exception)
            // from overwriting this richer exception report with a generic signal report.
            // Only claimed after a successful write — if the write failed, leave the
            // guard unclaimed so the C signal handler's minimal report (still better
            // than nothing) can be written in its place.
            MPKMarkCrashHandlerEntered()
        }

        // Chain to previous handler
        previousExceptionHandler?(exception)
    }

    private static func prepareCrashDirectory(at dir: String) -> Bool {
        var isDir: ObjCBool = false
        do {
            if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
                guard isDir.boolValue else { return false }
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
    public struct CrashReport: Sendable {
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
        /// Validated original-process and system metadata. Raw breadcrumbs stay
        /// in the local report and are never included in this wire value.
        public let diagnosticMetadata: CrashDiagnosticMetadata?
        let archiveContext: CrashContextArchive?
    }

    /// Legacy single-report path, retained for compatibility with older files.
    /// New handlers write only to their leased per-process destination.
    public static var crashReportPath: String {
        AppPaths.appSupportDir + "/crash_report.txt"
    }

    /// Load a pending crash report from disk, if one exists.
    public static func loadPendingReport(from path: String? = nil) -> CrashReport? {
        let filePath = path ?? crashReportPath
        // Use tolerant UTF-8 decoding: a crash mid-write could truncate a
        // multi-byte character, and strict .utf8 would discard the entire report.
        guard let data = CrashReportStore.readReport(at: URL(fileURLWithPath: filePath)) else {
            return nil
        }
        let content = String(decoding: data, as: UTF8.self)

        let lines = content.components(separatedBy: "\n")
        var fields = [String: String]()
        var stackTrace = [String]()
        var breadcrumbs = [String]()
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
                if key == "breadcrumb" {
                    if breadcrumbs.count < 32 { breadcrumbs.append(value) }
                } else {
                    fields[key] = value
                }
            }
        }

        guard let crashType = fields["crash_type"],
              let signal = fields["signal"],
              let name = fields["name"],
              let timestamp = fields["timestamp"],
              let appVer = fields["app_ver"] else {
            return nil
        }

        let diagnosticMetadata = CrashDiagnosticMetadata(fields: fields)
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
            siCode: crashType == "signal" ? validatedDecimal(fields["si_code"]) : nil,
            pc: crashType == "signal" ? validatedHexAddress(fields["pc"]) : nil,
            faultAddr: crashType == "signal" ? validatedHexAddress(fields["fault_addr"]) : nil,
            diagnosticMetadata: diagnosticMetadata.props.isEmpty ? nil : diagnosticMetadata,
            archiveContext: CrashContextArchive(fields: fields, breadcrumbLines: breadcrumbs)
        )
    }

    /// Accepts only a value that is both a bare, optionally `-`-prefixed run
    /// of ASCII digits *and* parses as a valid `Int32` — i.e. within the
    /// signed 32-bit range, including the `-2147483648` boundary (`INT32_MIN`,
    /// which the C handler can legitimately emit for `si_code`). Corrupt or
    /// out-of-range values are dropped (return `nil`) rather than forwarded
    /// as arbitrary text — this field can come from a report file written by
    /// a crashing process mid-corruption. The explicit character check comes
    /// first so a leading `+` or stray whitespace is rejected regardless of
    /// how permissive `Int32.init(_:)` happens to be.
    private static func validatedDecimal(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let digits = raw.hasPrefix("-") ? raw.dropFirst() : raw[raw.startIndex...]
        guard !digits.isEmpty, digits.count <= 10, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        guard Int32(raw) != nil else { return nil }
        return raw
    }

    /// Accepts only a bounded `0x`-prefixed hex address (up to 64 bits).
    /// Corrupt or oversized values are dropped (return `nil`) rather than
    /// forwarded as arbitrary text.
    private static func validatedHexAddress(_ raw: String?, maxHexDigits: Int = 16) -> String? {
        guard let raw, raw.hasPrefix("0x") else { return nil }
        let digits = raw.dropFirst(2)
        guard !digits.isEmpty, digits.count <= maxHexDigits,
              digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return nil
        }
        return raw
    }

    /// Send any pending crash report as a telemetry event. Delete the file only
    /// when telemetry reports that the event was delivered or intentionally dropped.
    /// Call after TelemetryService is initialized.
    public static func sendPendingReport(via telemetry: TelemetryServiceProtocol) async {
        await sendPendingReports(via: telemetry, store: reportStore)
    }

    /// Injectable spool for filesystem/ownership tests; actor execution keeps
    /// scanning and parsing off the main actor even when startup calls from it.
    static func sendPendingReports(
        via telemetry: TelemetryServiceProtocol,
        store: CrashReportStore,
        archive: @escaping @Sendable (CrashContextArchive) throws -> Void = {
            try $0.persist(to: AudioCaptureDiagnostics.diagnosticLogFileURL)
        }
    ) async {
        await drain.sendPendingReports(via: telemetry, store: store, archive: archive)
    }

    /// Internal variant with injectable path for testing.
    static func sendPendingReport(via telemetry: TelemetryServiceProtocol, from path: String) async {
        guard let report = loadPendingReport(from: path) else { return }

        let delivered = await send(report, via: telemetry)
        if delivered {
            deleteCrashFile(at: path)
        }
    }

    private static func send(_ report: CrashReport, via telemetry: TelemetryServiceProtocol) async -> Bool {
        await telemetry.sendAndFlush(.crashOccurred(
            crashType: report.crashType,
            signal: report.signal,
            name: report.name,
            crashTimestamp: report.timestamp,
            crashAppVer: report.appVersion,
            crashOsVer: report.osVersion,
            uuid: report.uuid,
            slide: report.slide,
            reason: report.reason,
            stackTrace: report.stackTrace.joined(separator: "\n"),
            siCode: report.siCode,
            pc: report.pc,
            faultAddr: report.faultAddr,
            diagnosticMetadata: report.diagnosticMetadata
        ))
    }

    private actor PendingReportDrain {
        private var drainingRoots: Set<String> = []

        func sendPendingReports(
            via telemetry: TelemetryServiceProtocol,
            store: CrashReportStore,
            archive: @Sendable (CrashContextArchive) throws -> Void
        ) async {
            let key = store.rootURL.standardizedFileURL.path
            guard drainingRoots.insert(key).inserted else { return }
            defer { drainingRoots.remove(key) }
            let claims = store.claimPendingReports()
            for claim in claims {
                guard let report = CrashReporter.loadPendingReport(from: claim.reportURL.path) else {
                    // A read error can be transient; nil does not establish a
                    // malformed file. Retain it subject to the capacity bound.
                    continue
                }
                // Archival is best effort and never decides retention. Keeping a
                // report after an opt-out drop would let a later opt-in upload it.
                if let context = report.archiveContext { try? archive(context) }
                if await CrashReporter.send(report, via: telemetry) { _ = store.discard(claim) }
            }
        }
    }

    private static func withCStringPointers<Result>(
        _ strings: [String],
        _ body: ([UnsafePointer<CChar>]) -> Result
    ) -> Result {
        func visit(_ index: Int, _ pointers: [UnsafePointer<CChar>]) -> Result {
            guard index < strings.count else { return body(pointers) }
            return strings[index].withCString { visit(index + 1, pointers + [$0]) }
        }
        return visit(0, [])
    }

    private static func deleteCrashFile(at path: String? = nil) {
        try? FileManager.default.removeItem(atPath: path ?? crashReportPath)
    }
}
