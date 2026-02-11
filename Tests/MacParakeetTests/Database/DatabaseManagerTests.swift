import XCTest
import GRDB
@testable import MacParakeetCore

final class DatabaseManagerTests: XCTestCase {

    func testInMemoryDatabaseCreates() throws {
        let manager = try DatabaseManager()
        XCTAssertNotNil(manager.dbQueue)
    }

    func testMigrationsCreateTables() throws {
        let manager = try DatabaseManager()
        try manager.dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("dictations"))
            XCTAssertTrue(try db.tableExists("transcriptions"))
            XCTAssertTrue(try db.tableExists("dictations_fts"))
        }
    }

    func testMigrationsCreateIndexes() throws {
        let manager = try DatabaseManager()
        try manager.dbQueue.read { db in
            let dictationIndexes = try db.indexes(on: "dictations")
            XCTAssertTrue(dictationIndexes.contains { $0.name == "idx_dictations_created_at" })

            let transcriptionIndexes = try db.indexes(on: "transcriptions")
            XCTAssertTrue(transcriptionIndexes.contains { $0.name == "idx_transcriptions_created_at" })
        }
    }

    func testSourceURLColumnExists() throws {
        let manager = try DatabaseManager()
        try manager.dbQueue.read { db in
            let columns = try db.columns(in: "transcriptions")
            let columnNames = columns.map(\.name)
            XCTAssertTrue(columnNames.contains("sourceURL"), "transcriptions should have sourceURL column")
        }
    }

    func testMigrationsAreIdempotent() throws {
        // Running migrations twice on the SAME database file should not error
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("idempotent_test_\(UUID().uuidString).db").path

        // First run — creates tables and indexes
        let manager1 = try DatabaseManager(path: dbPath)
        try manager1.dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("dictations"))
            XCTAssertTrue(try db.tableExists("transcriptions"))
        }

        // Second run on the SAME file — migrations should be skipped gracefully
        let manager2 = try DatabaseManager(path: dbPath)
        try manager2.dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("dictations"))
            XCTAssertTrue(try db.tableExists("transcriptions"))
        }

        // Clean up
        try? FileManager.default.removeItem(atPath: dbPath)
    }
}
