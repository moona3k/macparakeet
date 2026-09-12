import Darwin
import XCTest
@testable import MacParakeetCore

/// Runs the production `MPKCrashSignalHandler.c` (compiled unmodified from its
/// checked-in source) in a real, disposable child process that deliberately
/// faults or aborts. This is the only way to observe real signal-exit
/// disposition and a real interrupted instruction pointer without risking the
/// test runner itself — none of this ever executes in-process.
final class CrashReporterSignalProbeTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/clang"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/nm") else {
            throw XCTSkip("clang and nm are required to compile/inspect the crash-signal probe harness.")
        }
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashReporterSignalProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - SIGABRT: minimal evidence + default termination

    func testSubprocessAbortWritesMinimalSignalReportAndExitsViaDefaultDisposition() throws {
        let result = try runProbe(mode: "abort")

        XCTAssertEqual(result.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(result.process.terminationStatus, SIGABRT)

        let report = try XCTUnwrap(CrashReporter.loadPendingReport(from: result.crashFilePath))
        XCTAssertEqual(report.crashType, "signal")
        XCTAssertEqual(report.signal, "\(SIGABRT)")
        XCTAssertEqual(report.name, "SIGABRT")
        XCTAssertEqual(report.appVersion, "probe-app-ver")
        XCTAssertNotNil(report.siCode)
        XCTAssertNotNil(report.faultAddr)
    }

    // MARK: - Fault: interrupted PC must reflect the faulting code, not the handler

    func testSubprocessSegfaultPCPointsIntoInterruptedFunctionNotHandler() throws {
        let result = try runProbe(mode: "segv")

        XCTAssertEqual(result.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(result.process.terminationStatus, SIGSEGV)

        let report = try XCTUnwrap(CrashReporter.loadPendingReport(from: result.crashFilePath))
        XCTAssertEqual(report.crashType, "signal")
        XCTAssertEqual(report.signal, "\(SIGSEGV)")
        XCTAssertEqual(report.faultAddr, "0x0", "A null-pointer store should fault at address 0")

        let slideHex = report.slide
        guard slideHex.hasPrefix("0x"), let slide = UInt64(slideHex.dropFirst(2), radix: 16) else {
            XCTFail("Expected a parsable ASLR slide, got \(slideHex)")
            return
        }
        guard let pcRaw = report.pc, pcRaw.hasPrefix("0x"),
              let pc = UInt64(pcRaw.dropFirst(2), radix: 16) else {
            XCTFail("Expected a recognized-architecture PC in the report, got \(String(describing: report.pc))")
            return
        }
        let staticPC = pc - slide

        let triggerRange = try symbolRange(in: result.binaryPath, symbol: "mpk_probe_trigger_segv")
        XCTAssertTrue(
            triggerRange.contains(staticPC),
            "interrupted pc 0x\(String(staticPC, radix: 16)) not within the faulting function's range \(triggerRange)"
        )

        let handlerRange = try symbolRange(in: result.binaryPath, symbol: "mpk_signal_handler")
        XCTAssertFalse(
            handlerRange.contains(staticPC),
            "interrupted pc unexpectedly falls inside the signal handler's own code"
        )
    }

    // MARK: - Duplicate handler safety

    func testSubprocessReinstallDoesNotCorruptStateAndUsesLatestMetadata() throws {
        let result = try runProbe(mode: "reinstall_abort")

        XCTAssertEqual(result.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(result.process.terminationStatus, SIGABRT)

        let report = try XCTUnwrap(CrashReporter.loadPendingReport(from: result.crashFilePath))
        XCTAssertEqual(report.crashType, "signal")
        XCTAssertEqual(report.name, "SIGABRT")
        XCTAssertEqual(report.appVersion, "second-install-version")
    }

    // MARK: - Output truncation safety

    func testSubprocessLongMetadataIsTruncatedWithoutOverflow() throws {
        let result = try runProbe(mode: "long_meta_abort")

        XCTAssertEqual(result.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(result.process.terminationStatus, SIGABRT)

        let report = try XCTUnwrap(CrashReporter.loadPendingReport(from: result.crashFilePath))
        XCTAssertEqual(report.crashType, "signal")
        // The harness passes a 255-character app_version; the handler's fixed
        // internal buffer is 64 bytes, so it must come back truncated, intact,
        // and otherwise not have corrupted the rest of the report.
        XCTAssertLessThan(report.appVersion.count, 255)
        XCTAssertFalse(report.appVersion.isEmpty)
        XCTAssertTrue(report.appVersion.allSatisfy { $0 == "A" })
        XCTAssertEqual(report.name, "SIGABRT")
    }

    // MARK: - Write-loop robustness (short writes / EINTR / zero-write)
    //
    // These modes link a harness-side `write()` override ahead of libSystem's
    // (see crash_signal_probe_harness.c) to drive the production write loop
    // in `MPKCrashSignalHandler.c` through conditions a real crash can hit —
    // short writes, `EINTR`, and a destination that never accepts a byte —
    // without needing a real full disk or a real interrupting signal.

    func testSubprocessShortWritesStillProduceCompleteMinimalReport() throws {
        let result = try runProbe(mode: "short_write_abort")

        XCTAssertEqual(result.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(result.process.terminationStatus, SIGABRT)

        let report = try XCTUnwrap(CrashReporter.loadPendingReport(from: result.crashFilePath))
        XCTAssertEqual(report.crashType, "signal")
        XCTAssertEqual(report.name, "SIGABRT")
        XCTAssertEqual(report.appVersion, "probe-app-ver")
        XCTAssertNotNil(report.siCode)
        XCTAssertNotNil(report.faultAddr)
    }

    func testSubprocessEINTRWritesStillProduceCompleteMinimalReport() throws {
        let result = try runProbe(mode: "eintr_write_abort")

        XCTAssertEqual(result.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(result.process.terminationStatus, SIGABRT)

        let report = try XCTUnwrap(CrashReporter.loadPendingReport(from: result.crashFilePath))
        XCTAssertEqual(report.crashType, "signal")
        XCTAssertEqual(report.name, "SIGABRT")
        XCTAssertEqual(report.appVersion, "probe-app-ver")
        XCTAssertNotNil(report.siCode)
    }

    func testSubprocessZeroByteWritesDoNotHangAndProcessStillTerminatesViaSignal() throws {
        let result = try runProbe(mode: "zero_write_abort")

        // The core guarantee under test: a `write()` that always reports 0
        // bytes accepted must not make the handler spin or block — the
        // process still terminates via the signal's default disposition
        // within the bounded runProbe timeout below, and whatever is on disk
        // is either absent or empty, never a spin-induced hang.
        XCTAssertEqual(result.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(result.process.terminationStatus, SIGABRT)

        if FileManager.default.fileExists(atPath: result.crashFilePath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: result.crashFilePath))
            XCTAssertTrue(
                data.isEmpty,
                "write() always returning 0 should leave no bytes committed, not a partial report"
            )
        }
    }

    func testSubprocessFailedBacktraceStillLeavesMinimalReport() throws {
        let result = try runProbe(mode: "backtrace_fails_abort")

        XCTAssertEqual(result.process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(result.process.terminationStatus, SIGABRT)

        let report = try XCTUnwrap(CrashReporter.loadPendingReport(from: result.crashFilePath))
        XCTAssertEqual(report.crashType, "signal")
        XCTAssertEqual(report.name, "SIGABRT")
        XCTAssertNotNil(report.siCode)
        XCTAssertTrue(
            report.stackTrace.isEmpty,
            "backtrace() reporting 0 frames must not prevent the minimal report from being written"
        )
    }

    func testSubprocessAbruptBacktraceExitPreservesAlreadyWrittenMinimum() throws {
        let result = try runProbe(mode: "backtrace_exits_abort")
        XCTAssertEqual(result.process.terminationReason, .exit)
        XCTAssertEqual(result.process.terminationStatus, 73)
        let report = try XCTUnwrap(CrashReporter.loadPendingReport(from: result.crashFilePath))
        XCTAssertEqual(report.name, "SIGABRT")
        XCTAssertNotNil(report.siCode)
        XCTAssertNotNil(report.pc)
        XCTAssertNotNil(report.faultAddr)
        XCTAssertTrue(report.stackTrace.isEmpty)
    }

    // MARK: - Probe compilation and execution

    private struct ProbeResult {
        let crashFilePath: String
        let binaryPath: String
        let process: Process
    }

    private func runProbe(mode: String) throws -> ProbeResult {
        let repo = try Self.repoRoot()
        let objcShimsDir = repo.appendingPathComponent("Sources/MacParakeetObjCShims")
        let harnessSource = repo.appendingPathComponent("scripts/dev/tests/crash_signal_probe_harness.c")
        let handlerSource = objcShimsDir.appendingPathComponent("MPKCrashSignalHandler.c")
        let includeDir = objcShimsDir.appendingPathComponent("include")

        let binaryURL = tempDir.appendingPathComponent("crash_signal_probe")
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = [
            "-g", "-O0",
            "-I", includeDir.path,
            harnessSource.path,
            handlerSource.path,
            "-o", binaryURL.path,
        ]
        let compilePipe = Pipe()
        compile.standardOutput = compilePipe
        compile.standardError = compilePipe
        try compile.run()
        // Drain the pipe before waiting on exit: if clang's combined
        // stdout+stderr output ever exceeded the pipe's kernel buffer, reading
        // only after waitUntilExit() would deadlock (clang blocked writing to
        // a full pipe, this test blocked waiting for a clang that can't exit).
        // readDataToEndOfFile() itself blocks until clang closes the pipe by
        // exiting, so this ordering is also sufficient — no separate wait needed.
        let compileOutput = String(
            data: compilePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0, "clang failed to build the probe harness: \(compileOutput)")

        // Test-owned crash file path: unique per probe run, inside this test's
        // own temp directory, never the real app's crash report path.
        let crashFileURL = tempDir.appendingPathComponent("crash_report_\(mode).txt")

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [crashFileURL.path, mode]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // The harness arms a child-owned alarm before triggering any crash.
        // A hang therefore exits with SIGALRM and fails the expected signal
        // assertion, without a delayed parent callback targeting a reused PID.
        process.waitUntilExit()

        return ProbeResult(crashFilePath: crashFileURL.path, binaryPath: binaryURL.path, process: process)
    }

    // MARK: - Symbol address lookup (nm)

    private struct Symbol {
        let address: UInt64
        let name: String
    }

    private func addressedSymbols(in binaryPath: String) throws -> [Symbol] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = ["-n", binaryPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Same drain-before-wait ordering as the clang compile above.
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        var symbols = [Symbol]()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, parts[0].count == 16, let address = UInt64(parts[0], radix: 16) else {
                continue
            }
            symbols.append(Symbol(address: address, name: String(parts[2])))
        }
        return symbols
    }

    /// Half-open `[start, end)` byte range for `symbol` in the linked binary,
    /// bounded above by the next symbol's address (numeric `nm` ordering).
    private func symbolRange(in binaryPath: String, symbol: String) throws -> Range<UInt64> {
        let symbols = try addressedSymbols(in: binaryPath)
        let target = "_" + symbol
        guard let index = symbols.firstIndex(where: { $0.name == target }) else {
            throw XCTSkip("Could not locate symbol \(target) via nm in the probe binary.")
        }
        let start = symbols[index].address
        let end = index + 1 < symbols.count ? symbols[index + 1].address : start + 0x1000
        return start..<end
    }

    private static func repoRoot(filePath: String = #filePath) throws -> URL {
        var url = URL(fileURLWithPath: filePath)
        if !url.hasDirectoryPath {
            url.deleteLastPathComponent()
        }
        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else {
                throw NSError(
                    domain: "CrashReporterSignalProbeTests",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not find Package.swift from test file path: \(filePath)"
                    ]
                )
            }
            url = parent
        }
    }
}
