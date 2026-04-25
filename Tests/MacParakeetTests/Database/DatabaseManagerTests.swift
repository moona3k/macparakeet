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

    // MARK: - ADR-020 v0.8 schema additions

    func testUserNotesColumnExistsOnTranscriptions() throws {
        let manager = try DatabaseManager()
        try manager.dbQueue.read { db in
            let columns = try db.columns(in: "transcriptions").map(\.name)
            XCTAssertTrue(columns.contains("userNotes"), "transcriptions should have userNotes column (ADR-020 §3)")
        }
    }

    func testUserNotesSnapshotColumnExistsOnSummaries() throws {
        let manager = try DatabaseManager()
        try manager.dbQueue.read { db in
            let columns = try db.columns(in: "summaries").map(\.name)
            XCTAssertTrue(columns.contains("userNotesSnapshot"), "summaries should have userNotesSnapshot column (ADR-020 §6)")
        }
    }

    func testTranscriptionUserNotesRoundTrips() throws {
        let manager = try DatabaseManager()
        let transcriptionID = UUID()

        let transcription = Transcription(
            id: transcriptionID,
            fileName: "meeting.m4a",
            sourceType: .meeting,
            userNotes: "key decision: ship Friday\nfollow up with QA"
        )
        try manager.dbQueue.write { db in
            try transcription.insert(db)
        }

        let loaded = try manager.dbQueue.read { db in
            try Transcription.fetchOne(db, key: transcriptionID)
        }
        XCTAssertEqual(loaded?.userNotes, "key decision: ship Friday\nfollow up with QA")
    }

    func testTranscriptionUserNotesNilByDefault() throws {
        let manager = try DatabaseManager()
        let transcriptionID = UUID()

        let transcription = Transcription(id: transcriptionID, fileName: "no-notes.m4a")
        try manager.dbQueue.write { db in
            try transcription.insert(db)
        }

        let loaded = try manager.dbQueue.read { db in
            try Transcription.fetchOne(db, key: transcriptionID)
        }
        XCTAssertNil(loaded?.userNotes)
    }

    func testPromptResultUserNotesSnapshotRoundTrips() throws {
        let manager = try DatabaseManager()
        let transcriptionID = UUID()
        let promptResultID = UUID()

        try manager.dbQueue.write { db in
            try Transcription(id: transcriptionID, fileName: "fixture.m4a").insert(db)
            try PromptResult(
                id: promptResultID,
                transcriptionId: transcriptionID,
                promptName: "Memo-Steered Notes",
                promptContent: "...",
                content: "Generated summary",
                userNotesSnapshot: "snapshot of notes at gen time"
            ).insert(db)
        }

        let loaded = try manager.dbQueue.read { db in
            try PromptResult.fetchOne(db, key: promptResultID)
        }
        XCTAssertEqual(loaded?.userNotesSnapshot, "snapshot of notes at gen time")
    }

    func testReconcileBuiltInPromptsHonorsAutoRunGuardWhenZeroAutoRun() throws {
        // Seed a v0.7-shaped database where the user has explicitly disabled
        // every auto-run prompt (a valid state per ADR-013). Then run the
        // current migrator: the new "Memo-Steered Notes" prompt must be
        // inserted with isAutoRun=false to preserve the user's choice.
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("autorun_guard_zero_\(UUID().uuidString).db").path

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
            try Self.createV05DictationsTable(db: db)
            // Pre-seed prompts table with all auto-run flags off — simulating
            // a user who has explicitly disabled every auto-run prompt.
            try db.execute(sql: """
                CREATE TABLE prompts (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    content TEXT NOT NULL,
                    category TEXT NOT NULL DEFAULT 'summary',
                    isBuiltIn INTEGER NOT NULL DEFAULT 0,
                    isVisible INTEGER NOT NULL DEFAULT 1,
                    isAutoRun INTEGER NOT NULL DEFAULT 0,
                    sortOrder INTEGER NOT NULL DEFAULT 0,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_prompts_name ON prompts(name COLLATE NOCASE)
            """)
            try db.execute(sql: """
                CREATE TABLE summaries (
                    id TEXT PRIMARY KEY,
                    transcriptionId TEXT NOT NULL REFERENCES transcriptions(id) ON DELETE CASCADE,
                    promptName TEXT NOT NULL,
                    promptContent TEXT NOT NULL,
                    extraInstructions TEXT,
                    content TEXT NOT NULL,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE INDEX idx_summaries_transcription_id ON summaries(transcriptionId)
            """)
            // Insert a single dummy prompt with isAutoRun = 0 so the table is
            // non-empty but no row qualifies as auto-run. (The reconciler
            // would NOT touch this row's isAutoRun on UPDATE.)
            let now = Date()
            try db.execute(
                sql: "INSERT INTO prompts (id, name, content, category, isBuiltIn, isVisible, isAutoRun, sortOrder, createdAt, updatedAt) VALUES (?, ?, ?, ?, 0, 1, 0, 0, ?, ?)",
                arguments: [UUID(), "User's Custom Prompt", "do stuff", "summary", now, now]
            )
            // Also mark the prior autorun-related migrations as already run
            // so we don't re-trigger the v0.7.x auto-run setters on this seed.
            for migrationID in [
                "v0.7-prompts-and-summaries",
                "v0.7.1-prompt-default",
                "v0.7.2-prompt-autorun",
                "v0.7.3-prompt-autorun-visibility",
                "v0.7.4-lifetime-dictation-stats",
                "v0.7.5-meeting-recovery-flag",
            ] {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [migrationID]
                )
            }
        }

        let manager = try DatabaseManager(path: dbPath)
        try manager.dbQueue.read { db in
            // Memo-Steered Notes was inserted by reconcile (its canonical UUID
            // wasn't in the DB before). Auto-run guard kicked in: no pre-existing
            // auto-run row, so the new built-in must be inserted with auto-run
            // disabled.
            let row = try Row.fetchOne(
                db,
                sql: "SELECT isAutoRun FROM prompts WHERE name = 'Memo-Steered Notes'"
            )
            XCTAssertNotNil(row, "Memo-Steered Notes should have been inserted by reconcile")
            let isAutoRun = (row?["isAutoRun"] as Int?) ?? 0
            XCTAssertEqual(isAutoRun, 0, "Auto-run guard must preserve zero-auto-run state (ADR-020 §5)")
        }

        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testReconcileBuiltInPromptsHonorsAutoRunGuardWhenAtLeastOneAutoRun() throws {
        // Same shape as the above test, but seed with one existing auto-run
        // prompt. The new built-in must be inserted with auto-run enabled
        // (its canonical value) because the guard is satisfied.
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("autorun_guard_some_\(UUID().uuidString).db").path

        let seedQueue = try DatabaseQueue(path: dbPath)
        try seedQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (
                    identifier TEXT NOT NULL PRIMARY KEY
                )
            """)
            for migrationID in prePromptLibraryMigrationIDs + [
                "v0.7-prompts-and-summaries",
                "v0.7.1-prompt-default",
                "v0.7.2-prompt-autorun",
                "v0.7.3-prompt-autorun-visibility",
                "v0.7.4-lifetime-dictation-stats",
                "v0.7.5-meeting-recovery-flag",
            ] {
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
                    sourceType TEXT NOT NULL DEFAULT 'file',
                    recoveredFromCrash INTEGER NOT NULL DEFAULT 0
                )
            """)
            try Self.createV05DictationsTable(db: db)
            try db.execute(sql: """
                CREATE TABLE prompts (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    content TEXT NOT NULL,
                    category TEXT NOT NULL DEFAULT 'summary',
                    isBuiltIn INTEGER NOT NULL DEFAULT 0,
                    isVisible INTEGER NOT NULL DEFAULT 1,
                    isAutoRun INTEGER NOT NULL DEFAULT 0,
                    sortOrder INTEGER NOT NULL DEFAULT 0,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_prompts_name ON prompts(name COLLATE NOCASE)
            """)
            try db.execute(sql: """
                CREATE TABLE summaries (
                    id TEXT PRIMARY KEY,
                    transcriptionId TEXT NOT NULL REFERENCES transcriptions(id) ON DELETE CASCADE,
                    promptName TEXT NOT NULL,
                    promptContent TEXT NOT NULL,
                    extraInstructions TEXT,
                    content TEXT NOT NULL,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE INDEX idx_summaries_transcription_id ON summaries(transcriptionId)
            """)
            // Insert one auto-run prompt — guard is satisfied.
            let now = Date()
            try db.execute(
                sql: "INSERT INTO prompts (id, name, content, category, isBuiltIn, isVisible, isAutoRun, sortOrder, createdAt, updatedAt) VALUES (?, ?, ?, ?, 0, 1, 1, 0, ?, ?)",
                arguments: [UUID(), "User's Auto Prompt", "do stuff", "summary", now, now]
            )
        }

        let manager = try DatabaseManager(path: dbPath)
        try manager.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT isAutoRun FROM prompts WHERE name = 'Memo-Steered Notes'"
            )
            XCTAssertNotNil(row, "Memo-Steered Notes should have been inserted by reconcile")
            let isAutoRun = (row?["isAutoRun"] as Int?) ?? 0
            XCTAssertEqual(isAutoRun, 1, "Auto-run guard satisfied; new built-in honors canonical isAutoRun=true (ADR-020 §5)")
        }

        try? FileManager.default.removeItem(atPath: dbPath)
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

    func testPromptSummaryMigrationMovesLegacySummaryAndDropsColumn() throws {
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
            let transcriptionColumns = try db.columns(in: "transcriptions").map(\.name)

            XCTAssertEqual(migratedSummaryCount, 1)
            XCTAssertEqual(migratedSummaryContent, legacySummary)
            XCTAssertFalse(transcriptionColumns.contains("summary"))
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
