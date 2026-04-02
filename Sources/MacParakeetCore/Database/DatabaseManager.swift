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

        // v0.4 — Add diarizationSegments to transcriptions (speaker diarization)
        migrator.registerMigration("v0.4-transcription-diarization-segments") { db in
            try db.alter(table: "transcriptions") { t in
                t.add(column: "diarizationSegments", .text)
            }
        }

        // v0.4 — Add LLM content columns to transcriptions (summary + chat persistence)
        migrator.registerMigration("v0.4-transcription-llm-content") { db in
            try db.alter(table: "transcriptions") { t in
                t.add(column: "summary", .text)
                t.add(column: "chatMessages", .text)
            }
        }

        // v0.5 — Private dictation mode: hidden flag + wordCount column
        migrator.registerMigration("v0.5-private-dictation") { db in
            try db.alter(table: "dictations") { t in
                t.add(column: "hidden", .boolean).notNull().defaults(to: false)
                t.add(column: "wordCount", .integer).notNull().defaults(to: 0)
            }
            // Backfill wordCount for existing completed rows.
            // Use DatabaseValue to safely skip rows with corrupt/non-UUID ids.
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, COALESCE(cleanTranscript, rawTranscript) AS text
                FROM dictations WHERE status = 'completed'
            """)
            for row in rows {
                guard let id = UUID.fromDatabaseValue(row["id"] as DatabaseValue) else { continue }
                let text: String = row["text"] ?? ""
                let wc = text.split(whereSeparator: \.isWhitespace).count
                try db.execute(sql: "UPDATE dictations SET wordCount = ? WHERE id = ?", arguments: [wc, id])
            }
        }

        // v0.5 — Chat conversations table (multi-conversation per transcript)
        migrator.registerMigration("v0.5-chat-conversations") { db in
            try db.create(table: "chat_conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("transcriptionId", .text)
                    .notNull()
                    .references("transcriptions", onDelete: .cascade)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("messages", .text)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.create(
                index: "idx_chat_conversations_transcription_id",
                on: "chat_conversations",
                columns: ["transcriptionId"]
            )

            // Migrate existing chatMessages from transcriptions into chat_conversations
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, chatMessages FROM transcriptions WHERE chatMessages IS NOT NULL
            """)
            let now = Date()
            for row in rows {
                guard let transcriptionId = UUID.fromDatabaseValue(row["id"] as DatabaseValue),
                      let chatMessagesJSON = String.fromDatabaseValue(row["chatMessages"] as DatabaseValue) else { continue }

                // Derive title from first user message
                var title = "Chat"
                if let data = chatMessagesJSON.data(using: .utf8),
                   let messages = try? JSONDecoder().decode([ChatMessage].self, from: data) {
                    if let firstUser = messages.first(where: { $0.role == .user }) {
                        title = String(firstUser.content.prefix(50))
                    }
                }

                let conversationId = UUID()
                try db.execute(sql: """
                    INSERT INTO chat_conversations (id, transcriptionId, title, messages, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [conversationId, transcriptionId, title, chatMessagesJSON, now, now])
            }

            // Null out migrated chatMessages (keep column for backward compat)
            try db.execute(sql: "UPDATE transcriptions SET chatMessages = NULL WHERE chatMessages IS NOT NULL")
        }

        // v0.5 — Remove unused FTS5 infrastructure
        // The FTS5 virtual table + 3 sync triggers were created in v0.1 but never queried
        // (search uses LIKE). This removes the write overhead on every INSERT/UPDATE/DELETE.
        migrator.registerMigration("v0.5-drop-unused-fts") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS dictations_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS dictations_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS dictations_au")
            try db.execute(sql: "DROP TABLE IF EXISTS dictations_fts")
        }

        // v0.5 — Video metadata + favorites for transcriptions
        migrator.registerMigration("v0.5-transcription-video-metadata") { db in
            try db.alter(table: "transcriptions") { t in
                t.add(column: "thumbnailURL", .text)
                t.add(column: "channelName", .text)
                t.add(column: "videoDescription", .text)
                t.add(column: "isFavorite", .boolean).notNull().defaults(to: false)
            }
        }

        // v0.7 — Keystroke action snippets (issue #40)
        migrator.registerMigration("v0.7-snippet-key-action") { db in
            try db.alter(table: "text_snippets") { t in
                t.add(column: "action", .text)
            }
        }

        try migrator.migrate(dbQueue)
    }
}
