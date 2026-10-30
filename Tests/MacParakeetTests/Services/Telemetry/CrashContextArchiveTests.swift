import Foundation
import XCTest
@testable import MacParakeetCore

final class CrashContextArchiveTests: XCTestCase {
    private var fields: [String: String] {
        [
            "crash_context_version": "1",
            "crash_id": "a17e1881-3d55-4ab8-af5f-32dedd0571c4",
            "crash_session": "57b2573a-8629-4d7e-8c24-42304d44d388",
            "timestamp": "123",
            "crash_registered_consumers": "2",
            "reason": "private transcript /private/customer/path",
        ]
    }

    private var packed: UInt64 {
        CrashAudioContext.Record(kind: .phase, phase: .startEngine, attempt: 7).packed
    }

    func testFiniteArchiveRetainsOriginalIdentityAndOmitsRawReportContent() throws {
        let archive = try XCTUnwrap(
            CrashContextArchive(
                fields: fields, breadcrumbLines: ["1,0x\(String(packed, radix: 16))"]
            ))
        XCTAssertEqual(archive.breadcrumbs.count, 1)
        XCTAssertTrue(archive.message.contains("crash_context_recovered"))
        XCTAssertTrue(archive.message.contains("crash_session=57b2573a-8629-4d7e-8c24-42304d44d388"))
        XCTAssertTrue(archive.message.contains("crash_timestamp=123"))
        XCTAssertFalse(archive.message.contains("private"))
        XCTAssertFalse(archive.message.contains("reason="))
    }

    func testInvalidUnknownOutOfOrderAndExcessRecordsAreNotArchived() throws {
        let valid = "0x\(String(packed, radix: 16))"
        let archive = try XCTUnwrap(
            CrashContextArchive(
                fields: fields,
                breadcrumbLines: [
                    "2,\(valid)", "1,\(valid)", "2,\(valid)", "3,0xffffffffffffffff",
                    "4,/private/path", "5,\(valid)",
                ]
            ))
        XCTAssertEqual(archive.breadcrumbs.map(\.sequence), [2, 5])
        let bounded = try XCTUnwrap(
            CrashContextArchive(
                fields: fields, breadcrumbLines: (1...100).map { "\($0),\(valid)" }
            ))
        XCTAssertEqual(bounded.breadcrumbs.count, 32)
        XCTAssertLessThan(bounded.message.utf8.count, 4096)
        var unknown = fields
        unknown["crash_context_version"] = "2"
        XCTAssertNil(CrashContextArchive(fields: unknown, breadcrumbLines: ["1,\(valid)"]))
        XCTAssertNil(CrashContextArchive(fields: fields, breadcrumbLines: ["not a record"]))
    }

    func testArchiveUsesExistingLogAndPropagatesWriteFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try XCTUnwrap(
            CrashContextArchive(
                fields: fields, breadcrumbLines: ["1,0x\(String(packed, radix: 16))"]
            ))
        let log = directory.appendingPathComponent("diagnostic.log")
        try archive.persist(to: log)
        XCTAssertTrue(try String(contentsOf: log).contains(archive.message))
        let invalidParent = directory.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: invalidParent)
        XCTAssertThrowsError(try archive.persist(to: invalidParent.appendingPathComponent("diagnostic.log")))
        XCTAssertEqual(try String(contentsOf: invalidParent), "keep")
    }
    func testArchiveDeclinesRotationWithoutChangingExistingLog() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try XCTUnwrap(
            CrashContextArchive(
                fields: fields, breadcrumbLines: ["1,0x\(String(packed, radix: 16))"]
            ))
        let log = directory.appendingPathComponent("diagnostic.log")
        let original = Data(repeating: 65, count: Int(AudioCaptureDiagnostics.diagnosticLogMaxBytes))
        try original.write(to: log)
        XCTAssertThrowsError(try archive.persist(to: log))
        XCTAssertEqual(try Data(contentsOf: log), original)
    }

}
