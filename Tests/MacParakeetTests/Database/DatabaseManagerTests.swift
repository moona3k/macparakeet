import XCTest
import GRDB
@testable import MacParakeetCore

final class DatabaseManagerTests: XCTestCase {
    private let prePromptLibraryMigrationIDs = [
        "v0.1-dictations",
        "v0.1-transcriptions",
        "v0.2-custom-words",
        "v0.2-text-snippets",
        "v0.3-transcription-source-url",
        "v0.4-transcription-diarization-segments",
        "v0.4-transcription-llm-content",
        "v0.5-private-dictation",
        "v0.5-chat-conversations",
        "v0.5-drop-unused-fts",
        "v0.5-transcription-video-metadata",
        "v0.6-transcription-source-type",
        "v0.7-snippet-key-action",
    ]

    func testInMemoryDatabaseCreates() throws {
        let manager = try DatabaseManager()
        XCTAssertNotNil(manager.dbQueue)
    }

    func testMigrationsCreateTables() throws {
        let manager = try DatabaseManager()
        try manager.dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("dictations"))
            XCTAssertTrue(try db.tableExists("transcriptions"))
            XCTAssertTrue(try db.tableExists("prompts"))
            XCTAssertTrue(try db.tableExists("summaries"))
            // dictations_fts was dropped in v0.5-drop-unused-fts (never queried, wasted write overhead)
            XCTAssertFalse(try db.tableExists("dictations_fts"))
        }
    }

    func testMigrationsCreateIndexes() throws {
        let manager = try DatabaseManager()
        try manager.dbQueue.read { db in
            let dictationIndexes = try db.indexes(on: "dictations")
            XCTAssertTrue(dictationIndexes.contains { $0.name == "idx_dictations_created_at" })

            let transcriptionIndexes = try db.indexes(on: "transcriptions")
            XCTAssertTrue(transcriptionIndexes.contains { $0.name == "idx_transcriptions_created_at" })

            let promptIndexes = try db.indexes(on: "prompts")
            XCTAssertTrue(promptIndexes.contains { $0.name == "idx_prompts_name" })

            let summaryIndexes = try db.indexes(on: "summaries")
            XCTAssertTrue(summaryIndexes.contains { $0.name == "idx_summaries_transcription_id" })
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

    func testVideoMetadataColumnsExist() throws {
        let manager = try DatabaseManager()
        try manager.dbQueue.read { db in
            let columns = try db.columns(in: "transcriptions").map(\.name)
            XCTAssertTrue(columns.contains("thumbnailURL"), "transcriptions should have thumbnailURL column")
            XCTAssertTrue(columns.contains("channelName"), "transcriptions should have channelName column")
            XCTAssertTrue(columns.contains("videoDescription"), "transcriptions should have videoDescription column")
            XCTAssertTrue(columns.contains("isFavorite"), "transcriptions should have isFavorite column")
            XCTAssertTrue(columns.contains("sourceType"), "transcriptions should have sourceType column")
            XCTAssertTrue(columns.contains("recoveredFromCrash"), "transcriptions should have recoveredFromCrash column")
        }
    }

    func testSourceTypeMigrationBackfillsYouTubeRows() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("source_type_migration_\(UUID().uuidString).db").path

        let seedQueue = try DatabaseQueue(path: dbPath)
        try seedQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (
                    identifier TEXT NOT NULL PRIMARY KEY
                )
            """)
            for migrationID in [
                "v0.1-dictations",
                "v0.1-transcriptions",
                "v0.2-custom-words",
                "v0.2-text-snippets",
                "v0.3-transcription-source-url",
                "v0.4-transcription-diarization-segments",
                "v0.4-transcription-llm-content",
                "v0.5-private-dictation",
                "v0.5-chat-conversations",
                "v0.5-drop-unused-fts",
                "v0.5-transcription-video-metadata",
            ] {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [migrationID]
                )
            }

            try db.execute(sql: """
                CREATE TABLE transcriptions (
                    id TEXT PRIMARY KEY,
                    createdAt TEXT NOT NULL,
                    fileName TEXT NOT NULL,
                    filePath TEXT,
                    fileSizeBytes INTEGER,
                    durationMs INTEGER,
                    rawTranscript TEXT,
                    cleanTranscript TEXT,
                    wordTimestamps TEXT,
                    language TEXT DEFAULT 'en',
                    speakerCount INTEGER,
                    speakers TEXT,
                    status TEXT NOT NULL DEFAULT 'processing',
                    errorMessage TEXT,
                    exportPath TEXT,
                    updatedAt TEXT NOT NULL,
                    sourceURL TEXT,
                    diarizationSegments TEXT,
                    summary TEXT,
                    chatMessages TEXT,
                    thumbnailURL TEXT,
                    channelName TEXT,
                    videoDescription TEXT,
                    isFavorite INTEGER NOT NULL DEFAULT 0
                )
            """)

            // dictations table is required by the v0.7.4 lifetime stats backfill.
            try Self.createV05DictationsTable(db: db)

            try db.execute(sql: """
                CREATE TABLE text_snippets (
                    id TEXT PRIMARY KEY,
                    trigger TEXT NOT NULL,
                    expansion TEXT NOT NULL,
                    isEnabled INTEGER NOT NULL DEFAULT 1,
                    useCount INTEGER NOT NULL DEFAULT 0,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL
                )
            """)

            let now = Date()
            try db.execute(
                sql: """
                    INSERT INTO transcriptions (id, createdAt, fileName, updatedAt, sourceURL)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [UUID(), now, "youtube.mp3", now, "https://youtube.com/watch?v=test"]
            )
        }

        let manager = try DatabaseManager(path: dbPath)
        try manager.dbQueue.read { db in
            let sourceType = try String.fetchOne(db, sql: "SELECT sourceType FROM transcriptions LIMIT 1")
            XCTAssertEqual(sourceType, Transcription.SourceType.youtube.rawValue)
        }

        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testSummariesTableIncludesUpdatedAtColumn() throws {
        let manager = try DatabaseManager()
        try manager.dbQueue.read { db in
            let columns = try db.columns(in: "summaries").map(\.name)
            XCTAssertTrue(columns.contains("updatedAt"), "summaries should have updatedAt column")
        }
    }

    func testPromptSummaryMigrationPreservesLegacySummaryColumn() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("prompt_summary_migration_\(UUID().uuidString).db").path
        let transcriptionID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_712_345_678)
        let legacySummary = "Existing migrated summary"

        let seedQueue = try DatabaseQueue(path: dbPath)
        try seedQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (
                    identifier TEXT NOT NULL PRIMARY KEY
                )
            """)
            for migrationID in prePromptLibraryMigrationIDs {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [migrationID]
                )
            }

            try db.execute(sql: """
                CREATE TABLE text_snippets (
                    id TEXT PRIMARY KEY,
                    trigger TEXT NOT NULL,
                    expansion TEXT NOT NULL,
                    isEnabled INTEGER NOT NULL DEFAULT 1,
                    useCount INTEGER NOT NULL DEFAULT 0,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL,
                    action TEXT
                )
            """)

            try db.execute(sql: """
                CREATE TABLE transcriptions (
                    id TEXT PRIMARY KEY,
                    createdAt TEXT NOT NULL,
                    fileName TEXT NOT NULL,
                    filePath TEXT,
                    fileSizeBytes INTEGER,
                    durationMs INTEGER,
                    rawTranscript TEXT,
                    cleanTranscript TEXT,
                    wordTimestamps TEXT,
                    language TEXT DEFAULT 'en',
                    speakerCount INTEGER,
                    speakers TEXT,
                    status TEXT NOT NULL DEFAULT 'processing',
                    errorMessage TEXT,
                    exportPath TEXT,
                    updatedAt TEXT NOT NULL,
                    sourceURL TEXT,
                    diarizationSegments TEXT,
                    summary TEXT,
                    chatMessages TEXT,
                    thumbnailURL TEXT,
                    channelName TEXT,
                    videoDescription TEXT,
                    isFavorite INTEGER NOT NULL DEFAULT 0,
                    sourceType TEXT NOT NULL DEFAULT 'file'
                )
            """)

            // dictations table is required by the v0.7.4 lifetime stats backfill.
            try Self.createV05DictationsTable(db: db)

            try db.execute(
                sql: """
                    INSERT INTO transcriptions (
                        id, createdAt, fileName, updatedAt, summary
                    ) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [transcriptionID, createdAt, "fixture.wav", createdAt, legacySummary]
            )
        }

        let manager = try DatabaseManager(path: dbPath)
        try manager.dbQueue.read { db in
            let migratedSummaryCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM summaries WHERE transcriptionId = ?",
                arguments: [transcriptionID]
            )
            let migratedSummaryContent = try String.fetchOne(
                db,
                sql: "SELECT content FROM summaries WHERE transcriptionId = ?",
                arguments: [transcriptionID]
            )
            let preservedLegacySummary = try String.fetchOne(
                db,
                sql: "SELECT summary FROM transcriptions WHERE id = ?",
                arguments: [transcriptionID]
            )

            XCTAssertEqual(migratedSummaryCount, 1)
            XCTAssertEqual(migratedSummaryContent, legacySummary)
            XCTAssertEqual(preservedLegacySummary, legacySummary)
        }

        try? FileManager.default.removeItem(atPath: dbPath)
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

    /// Recreates the dictations table at its v0.5 shape (after `v0.5-private-dictation`
    /// added `hidden` and `wordCount`). Used by partial-migration test fixtures so the
    /// v0.7.4 lifetime-stats backfill has a real table to read from.
    static func createV05DictationsTable(db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE dictations (
                id TEXT PRIMARY KEY,
                createdAt TEXT NOT NULL,
                durationMs INTEGER NOT NULL,
                rawTranscript TEXT NOT NULL,
                cleanTranscript TEXT,
                audioPath TEXT,
                pastedToApp TEXT,
                processingMode TEXT NOT NULL DEFAULT 'raw',
                status TEXT NOT NULL DEFAULT 'completed',
                errorMessage TEXT,
                updatedAt TEXT NOT NULL,
                hidden INTEGER NOT NULL DEFAULT 0,
                wordCount INTEGER NOT NULL DEFAULT 0
            )
        """)
    }
}
