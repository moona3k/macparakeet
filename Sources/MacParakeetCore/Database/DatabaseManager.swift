import Foundation
import GRDB

public final class DatabaseManager: Sendable {
    public let dbQueue: DatabaseQueue

    /// Create a DatabaseManager with a file-backed database
    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        #if DEBUG
        config.prepareDatabase { db in
            db.trace { print("SQL: \($0)") }
        }
        #endif
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try migrate()
    }

    /// Create a DatabaseManager with an in-memory database (for tests)
    public init() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(configuration: config)
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        // v0.1 — Dictations table + FTS5
        migrator.registerMigration("v0.1-dictations") { db in
            try db.create(table: "dictations") { t in
                t.column("id", .text).primaryKey()
                t.column("createdAt", .text).notNull()
                t.column("durationMs", .integer).notNull()
                t.column("rawTranscript", .text).notNull()
                t.column("cleanTranscript", .text)
                t.column("audioPath", .text)
                t.column("pastedToApp", .text)
                t.column("processingMode", .text).notNull().defaults(to: "raw")
                t.column("status", .text).notNull().defaults(to: "completed")
                t.column("errorMessage", .text)
                t.column("updatedAt", .text).notNull()
            }
            try db.create(
                index: "idx_dictations_created_at",
                on: "dictations",
                columns: ["createdAt"]
            )

            // FTS5 external content table
            try db.execute(sql: """
                CREATE VIRTUAL TABLE dictations_fts USING fts5(
                    rawTranscript, cleanTranscript,
                    content='dictations', content_rowid='rowid'
                )
            """)

            // Sync triggers
            try db.execute(sql: """
                CREATE TRIGGER dictations_ai AFTER INSERT ON dictations BEGIN
                    INSERT INTO dictations_fts(rowid, rawTranscript, cleanTranscript)
                    VALUES (new.rowid, new.rawTranscript, new.cleanTranscript);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER dictations_ad AFTER DELETE ON dictations BEGIN
                    INSERT INTO dictations_fts(dictations_fts, rowid, rawTranscript, cleanTranscript)
                    VALUES ('delete', old.rowid, old.rawTranscript, old.cleanTranscript);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER dictations_au AFTER UPDATE ON dictations BEGIN
                    INSERT INTO dictations_fts(dictations_fts, rowid, rawTranscript, cleanTranscript)
                    VALUES ('delete', old.rowid, old.rawTranscript, old.cleanTranscript);
                    INSERT INTO dictations_fts(rowid, rawTranscript, cleanTranscript)
                    VALUES (new.rowid, new.rawTranscript, new.cleanTranscript);
                END
            """)
        }

        // v0.1 — Transcriptions table
        migrator.registerMigration("v0.1-transcriptions") { db in
            try db.create(table: "transcriptions") { t in
                t.column("id", .text).primaryKey()
                t.column("createdAt", .text).notNull()
                t.column("fileName", .text).notNull()
                t.column("filePath", .text)
                t.column("fileSizeBytes", .integer)
                t.column("durationMs", .integer)
                t.column("rawTranscript", .text)
                t.column("cleanTranscript", .text)
                t.column("wordTimestamps", .text)
                t.column("language", .text).defaults(to: "en")
                t.column("speakerCount", .integer)
                t.column("speakers", .text)
                t.column("status", .text).notNull().defaults(to: "processing")
                t.column("errorMessage", .text)
                t.column("exportPath", .text)
                t.column("updatedAt", .text).notNull()
            }
            try db.create(
                index: "idx_transcriptions_created_at",
                on: "transcriptions",
                columns: ["createdAt"]
            )
        }

        // v0.2 — Custom words table
        migrator.registerMigration("v0.2-custom-words") { db in
            try db.create(table: "custom_words") { t in
                t.column("id", .text).primaryKey()
                t.column("word", .text).notNull()
                t.column("replacement", .text)
                t.column("source", .text).notNull().defaults(to: "manual")
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_custom_words_word
                ON custom_words(word COLLATE NOCASE)
            """)
        }

        // v0.2 — Text snippets table
        migrator.registerMigration("v0.2-text-snippets") { db in
            try db.create(table: "text_snippets") { t in
                t.column("id", .text).primaryKey()
                t.column("trigger", .text).notNull()
                t.column("expansion", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("useCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_text_snippets_trigger
                ON text_snippets("trigger" COLLATE NOCASE)
            """)
        }

        // v0.3 — Add sourceURL to transcriptions (YouTube URL tracking)
        migrator.registerMigration("v0.3-transcription-source-url") { db in
            try db.alter(table: "transcriptions") { t in
                t.add(column: "sourceURL", .text)
            }
        }

        try migrator.migrate(dbQueue)
    }
}
