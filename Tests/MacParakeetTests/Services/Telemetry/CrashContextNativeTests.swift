import Darwin
import XCTest
@testable import MacParakeetCore

/// Isolate process-global native state and deliberate fatal interruption from XCTest.
final class CrashContextNativeTests: XCTestCase {
    func testNativeRingBoundsConcurrentReadersAndInterruptedWriter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("context-probe")
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = [
            "-O2", "-std=c11", "-Wall", "-Wextra", "-Werror", "-DMPK_CRASH_CONTEXT_TESTING",
            "-I", root.appendingPathComponent("Sources/MacParakeetObjCShims/include").path,
            root.appendingPathComponent("Sources/MacParakeetObjCShims/MPKCrashSignalHandler.c").path,
            root.appendingPathComponent("scripts/dev/tests/crash_context_probe.c").path,
            "-o", binary.path,
        ]
        let pipe = Pipe()
        compile.standardOutput = pipe
        compile.standardError = pipe
        try compile.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else { XCTFail(output); return }

        for mode in ["checks", "concurrent", "interrupted"] {
            let reportURL = directory.appendingPathComponent("report.txt")
            let process = Process()
            process.executableURL = binary
            process.arguments = [mode, reportURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()  // Child-owned alarm bounds every mode.
            if mode == "interrupted" {
                XCTAssertEqual(process.terminationReason, .uncaughtSignal)
                XCTAssertEqual(process.terminationStatus, SIGABRT)
                let data = try Data(contentsOf: reportURL)
                XCTAssertLessThan(data.count, CrashReportStore.maximumReportBytes)
                let content = String(decoding: data, as: UTF8.self)
                let records = content.split(separator: "\n").filter { $0.hasPrefix("breadcrumb: ") }
                XCTAssertEqual(records.count, 31, "The invalidated slot must never expose a torn record")
                XCTAssertTrue(records.allSatisfy { $0.hasSuffix(",0xfedcba9876543210") })
                let report = try XCTUnwrap(CrashReporter.loadPendingReport(from: reportURL.path))
                XCTAssertEqual(report.diagnosticMetadata?.props["crash_id"], "12345678-1234-1234-1234-123456789abc")
                XCTAssertEqual(report.diagnosticMetadata?.props["crash_context_version"], "1")
                XCTAssertEqual(report.diagnosticMetadata?.props["crash_breadcrumbs_incomplete"], "2")
            } else {
                XCTAssertEqual(process.terminationReason, .exit, mode)
                XCTAssertEqual(process.terminationStatus, 0, mode)
            }
        }
    }
}
