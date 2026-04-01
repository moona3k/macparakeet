import XCTest
@testable import MacParakeetCore

final class CrashReporterTests: XCTestCase {

    private var testDir: String!

    override func setUp() {
        super.setUp()
        testDir = NSTemporaryDirectory() + "CrashReporterTests-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: testDir)
        super.tearDown()
    }

    private var testCrashPath: String { testDir + "/crash_report.txt" }

    // MARK: - Signal Crash Parsing

    func testLoadPendingReportParsesValidSignalCrash() {
        let content = """
        crash_type: signal
        signal: 11
        name: SIGSEGV
        timestamp: 1711900000
        app_ver: 0.5.1
        os_ver: 15.3.1
        uuid: A1B2C3D4-E5F6-7890-ABCD-EF1234567890
        slide: 0x100000
        --- stack ---
        0x00000001a2f3b4c0
        0x00000001a2f3b4d8
        0x00000001a2f3b500
        """
        try! content.write(toFile: testCrashPath, atomically: true, encoding: .utf8)

        let report = CrashReporter.loadPendingReport(from: testCrashPath)
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.crashType, "signal")
        XCTAssertEqual(report?.signal, "11")
        XCTAssertEqual(report?.name, "SIGSEGV")
        XCTAssertEqual(report?.timestamp, "1711900000")
        XCTAssertEqual(report?.appVersion, "0.5.1")
        XCTAssertEqual(report?.osVersion, "15.3.1")
        XCTAssertEqual(report?.uuid, "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
        XCTAssertEqual(report?.slide, "0x100000")
        XCTAssertNil(report?.reason)
        XCTAssertEqual(report?.stackTrace.count, 3)
        XCTAssertEqual(report?.stackTrace.first, "0x00000001a2f3b4c0")
    }

    // MARK: - Exception Crash Parsing

    func testLoadPendingReportParsesExceptionCrash() {
        let content = """
        crash_type: exception
        signal: exception
        name: NSInvalidArgumentException
        timestamp: 1711900000
        app_ver: 0.5.1
        os_ver: 15.3.1
        uuid: A1B2C3D4-E5F6-7890-ABCD-EF1234567890
        slide: 0x0
        reason: unrecognized selector sent to instance
        --- stack ---
        0x00000001a2f3b4c0
        0x00000001a2f3b4d8
        """
        try! content.write(toFile: testCrashPath, atomically: true, encoding: .utf8)

        let report = CrashReporter.loadPendingReport(from: testCrashPath)
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.crashType, "exception")
        XCTAssertEqual(report?.name, "NSInvalidArgumentException")
        XCTAssertEqual(report?.reason, "unrecognized selector sent to instance")
        XCTAssertEqual(report?.stackTrace.count, 2)
    }

    // MARK: - Edge Cases

    func testLoadPendingReportReturnsNilForMissingFile() {
        let report = CrashReporter.loadPendingReport(from: testDir + "/nonexistent.txt")
        XCTAssertNil(report)
    }

    func testLoadPendingReportReturnsNilForEmptyFile() {
        try! "".write(toFile: testCrashPath, atomically: true, encoding: .utf8)
        let report = CrashReporter.loadPendingReport(from: testCrashPath)
        XCTAssertNil(report)
    }

    func testLoadPendingReportHandlesMalformedFile() {
        try! "garbage data\nno structure here".write(toFile: testCrashPath, atomically: true, encoding: .utf8)
        let report = CrashReporter.loadPendingReport(from: testCrashPath)
        XCTAssertNil(report) // Missing required fields
    }

    func testLoadPendingReportHandlesPartialFile() {
        // Only some fields — simulates interrupted write
        let content = """
        crash_type: signal
        signal: 6
        name: SIGABRT
        timestamp: 1711900000
        app_ver: 0.5.1
        """
        try! content.write(toFile: testCrashPath, atomically: true, encoding: .utf8)

        let report = CrashReporter.loadPendingReport(from: testCrashPath)
        XCTAssertNotNil(report) // Has required fields
        XCTAssertEqual(report?.signal, "6")
        XCTAssertEqual(report?.name, "SIGABRT")
        XCTAssertTrue(report?.stackTrace.isEmpty ?? false)
    }

    // MARK: - Telemetry Integration

    func testSendPendingReportSendsEventAndDeletesFile() {
        let content = """
        crash_type: signal
        signal: 11
        name: SIGSEGV
        timestamp: 1711900000
        app_ver: 0.5.1
        os_ver: 15.3.1
        uuid: TESTID
        slide: 0x100000
        --- stack ---
        0x1234
        0x5678
        """
        try! content.write(toFile: testCrashPath, atomically: true, encoding: .utf8)

        let mock = MockTelemetryService()
        CrashReporter.sendPendingReport(via: mock, from: testCrashPath)

        // Verify event was sent
        XCTAssertEqual(mock.sentEvents.count, 1)
        if case .crashOccurred(let crashType, let signal, let name, _, _, _, _, _, _) = mock.sentEvents.first {
            XCTAssertEqual(crashType, "signal")
            XCTAssertEqual(signal, "11")
            XCTAssertEqual(name, "SIGSEGV")
        } else {
            XCTFail("Expected crashOccurred event")
        }

        // Verify file was deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: testCrashPath))
    }

    func testSendPendingReportDeletesFileEvenWhenTelemetryDisabled() {
        let content = "crash_type: signal\nsignal: 6\nname: SIGABRT\ntimestamp: 0\napp_ver: 0.1\n"
        try! content.write(toFile: testCrashPath, atomically: true, encoding: .utf8)

        // NoOp service simulates disabled telemetry
        let noop = NoOpTelemetryService()
        CrashReporter.sendPendingReport(via: noop, from: testCrashPath)

        // File should still be deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: testCrashPath))
    }

    func testSendPendingReportNoOpWithoutCrashFile() {
        let mock = MockTelemetryService()
        CrashReporter.sendPendingReport(via: mock, from: testDir + "/nonexistent.txt")
        XCTAssertTrue(mock.sentEvents.isEmpty)
    }
}

// MARK: - Mock Telemetry Service

private final class MockTelemetryService: TelemetryServiceProtocol, @unchecked Sendable {
    var sentEvents = [TelemetryEventSpec]()

    func send(_ event: TelemetryEventSpec) {
        sentEvents.append(event)
    }

    func flush() async {}
    func flushForTermination() {}
}

private final class NoOpTelemetryService: TelemetryServiceProtocol, @unchecked Sendable {
    func send(_ event: TelemetryEventSpec) {}
    func flush() async {}
    func flushForTermination() {}
}
