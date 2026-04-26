import Foundation
import GRDB

public final class DatabaseManager: Sendable {
    public let dbQueue: DatabaseQueue

    #if DEBUG
    private static let sqlTraceEnvKey = "MACPARAKEET_DEBUG_SQL"
    #endif

    /// Create a DatabaseManager with a file-backed database
    public init(path: String) throws {
        let config = Self.makeConfiguration()
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try migrate()
    }

    /// Create a DatabaseManager with an in-memory database (for tests)
    public init() throws {
        let config = Self.makeConfiguration()
        dbQueue = try DatabaseQueue(configuration: config)
        try migrate()
    }

    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        #if DEBUG
        if sqlTraceEnabled {
            config.prepareDatabase { db in
                db.trace { print("SQL: \($0)") }
            }
        }
        #endif
        return config
    }

    #if DEBUG
    private static var sqlTraceEnabled: Bool {
        guard let rawValue = ProcessInfo.processInfo.environment[sqlTraceEnvKey] else {
            return false
        }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
    #endif

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

        // v0.6 — Transcription source type (file / youtube / meeting)
        migrator.registerMigration("v0.6-transcription-source-type") { db in
            try db.alter(table: "transcriptions") { t in
                t.add(column: "sourceType", .text).notNull().defaults(to: "file")
            }

            try db.execute(
                sql: """
                    UPDATE transcriptions
                    SET sourceType = ?
                    WHERE sourceURL IS NOT NULL
                """,
                arguments: ["youtube"]
            )
        }

        // v0.7 — Keystroke action snippets (issue #40)
        migrator.registerMigration("v0.7-snippet-key-action") { db in
            try db.alter(table: "text_snippets") { t in
                t.add(column: "action", .text)
            }
        }

        // v0.7 — Prompt library + multi-summary
        migrator.registerMigration("v0.7-prompts-and-summaries") { db in
            try db.create(table: "prompts") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("content", .text).notNull()
                t.column("category", .text).notNull().defaults(to: "summary")
                t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
                t.column("isVisible", .boolean).notNull().defaults(to: true)
                t.column("isAutoRun", .boolean).notNull().defaults(to: false)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_prompts_name ON prompts(name COLLATE NOCASE)
            """)

            let now = Date()
            for prompt in Prompt.builtInPrompts(now: now) {
                try prompt.insert(db)
            }

            try db.create(table: "summaries") { t in
                t.column("id", .text).primaryKey()
                t.column("transcriptionId", .text)
                    .notNull()
                    .references("transcriptions", onDelete: .cascade)
                t.column("promptName", .text).notNull()
                t.column("promptContent", .text).notNull()
                t.column("extraInstructions", .text)
                t.column("content", .text).notNull()
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.create(
                index: "idx_summaries_transcription_id",
                on: "summaries",
                columns: ["transcriptionId"]
            )

            let rows = try Row.fetchAll(db, sql: """
                SELECT id, summary, createdAt
                FROM transcriptions
                WHERE summary IS NOT NULL AND summary != ''
            """)

            for row in rows {
                guard
                    let transcriptionId = UUID.fromDatabaseValue(row["id"] as DatabaseValue),
                    let summaryText = String.fromDatabaseValue(row["summary"] as DatabaseValue)
                else {
                    continue
                }

                let createdAt = Date.fromDatabaseValue(row["createdAt"] as DatabaseValue) ?? now
                // Raw SQL rather than `PromptResult.insert(db)` so this historic
                // migration is decoupled from later additions to the model
                // (e.g. v0.8 added `userNotesSnapshot` to PromptResult — using
                // the model's auto-CRUD here would generate SQL referencing
                // columns that don't exist yet at v0.7 migration time).
                try db.execute(
                    sql: """
                        INSERT INTO summaries (
                            id, transcriptionId, promptName, promptContent,
                            extraInstructions, content, createdAt, updatedAt
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID(),
                        transcriptionId,
                        Prompt.defaultPrompt.name,
                        Prompt.defaultPrompt.content,
                        nil as String?,
                        summaryText,
                        createdAt,
                        createdAt,
                    ]
                )
            }
        }

        // v0.7.1 - Safely add isDefault for users who already ran v0.7 (from older commit)
        migrator.registerMigration("v0.7.1-prompt-default") { db in
            let columns = try db.columns(in: "prompts")
            // Only add isDefault if neither isDefault nor isAutoRun exists
            if !columns.contains(where: { $0.name == "isDefault" }) && !columns.contains(where: { $0.name == "isAutoRun" }) {
                try db.alter(table: "prompts") { t in
                    t.add(column: "isDefault", .boolean).notNull().defaults(to: false)
                }
                try db.execute(sql: """
                    UPDATE prompts SET isDefault = 1 WHERE name = 'General Summary' AND isBuiltIn = 1
                """)
            }
        }

        // v0.7.2 - Rename isDefault to isAutoRun for multi-auto-run support
        migrator.registerMigration("v0.7.2-prompt-autorun") { db in
            let columns = try db.columns(in: "prompts")
            if columns.contains(where: { $0.name == "isDefault" }) && !columns.contains(where: { $0.name == "isAutoRun" }) {
                try db.alter(table: "prompts") { t in
                    t.rename(column: "isDefault", to: "isAutoRun")
                }
            } else if !columns.contains(where: { $0.name == "isAutoRun" }) {
                try db.alter(table: "prompts") { t in
                    t.add(column: "isAutoRun", .boolean).notNull().defaults(to: false)
                }
                try db.execute(sql: """
                    UPDATE prompts SET isAutoRun = 1 WHERE name = 'General Summary' AND isBuiltIn = 1
                """)
            }
        }

        // v0.7.3 - Ensure all Auto-Run prompts are visible (fixes trapped toggles)
        migrator.registerMigration("v0.7.3-prompt-autorun-visibility") { db in
            try db.execute(sql: "UPDATE prompts SET isVisible = 1 WHERE isAutoRun = 1")
        }

        // v0.7.4 - Lifetime dictation stats survive history deletion (issue #124).
        // Single-row counter table, backfilled from existing completed dictations.
        migrator.registerMigration("v0.7.4-lifetime-dictation-stats") { db in
            try db.create(table: "lifetime_dictation_stats") { t in
                t.column("id", .integer).primaryKey().check { $0 == 1 }
                t.column("totalCount", .integer).notNull().defaults(to: 0)
                t.column("totalDurationMs", .integer).notNull().defaults(to: 0)
                t.column("totalWords", .integer).notNull().defaults(to: 0)
                t.column("longestDurationMs", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .text).notNull()
            }
            try DictationRepository.recomputeLifetimeStats(db: db)
        }

        // v0.7.5 - Mark meeting transcripts recovered from interrupted recordings.
        migrator.registerMigration("v0.7.5-meeting-recovery-flag") { db in
            try db.alter(table: "transcriptions") { t in
                t.add(column: "recoveredFromCrash", .boolean).notNull().defaults(to: false)
            }
        }

        // v0.7.6 - Drop legacy one-summary column after v0.7 migrates content to summaries.
        migrator.registerMigration("v0.7.6-drop-legacy-transcription-summary") { db in
            let columns = try db.columns(in: "transcriptions")
            if columns.contains(where: { $0.name == "summary" }) {
                try db.alter(table: "transcriptions") { t in
                    t.drop(column: "summary")
                }
            }
        }

        // v0.7.7 - Distinguish user-edited transcript text from automatic cleanup.
        migrator.registerMigration("v0.7.7-transcript-edited-flag") { db in
            try db.alter(table: "transcriptions") { t in
                t.add(column: "isTranscriptEdited", .boolean).notNull().defaults(to: false)
            }
        }

        // v0.8 - Live meeting notepad: capture user notes alongside the transcript so
        // they can steer the post-meeting summary (ADR-020).
        migrator.registerMigration("v0.8-meeting-notepad-user-notes") { db in
            try db.alter(table: "transcriptions") { t in
                t.add(column: "userNotes", .text)
            }
        }

        // v0.8 - Snapshot the userNotes value used at summary generation time, so
        // editing notes later doesn't retroactively change historic summaries
        // (mirrors the prompt-snapshot pattern from ADR-013).
        migrator.registerMigration("v0.8-summaries-user-notes-snapshot") { db in
            try db.alter(table: "summaries") { t in
                t.add(column: "userNotesSnapshot", .text)
            }
        }

        try migrator.migrate(dbQueue)
        try reconcileBuiltInPrompts()
    }

    private func reconcileBuiltInPrompts() throws {
        let builtInPrompts = Prompt.builtInPrompts(now: Date())
        let canonicalIDs = builtInPrompts.map { $0.id }

        try dbQueue.write { db in
            // Auto-run insertion guard (ADR-020 §5): a brand-new built-in prompt
            // whose canonical isAutoRun is `true` is only inserted with auto-run
            // enabled if the user already has at least one auto-run prompt today.
            // This preserves ADR-013's "zero auto-run is a valid state" invariant
            // for users who have explicitly disabled every auto-run prompt.
            let userHasAnyAutoRunPrompt = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM prompts WHERE isAutoRun = 1)"
            ) ?? false

            for prompt in builtInPrompts {
                if let existing = try Prompt.fetchOne(db, key: prompt.id) {
                    try db.execute(
                        sql: """
                            UPDATE prompts
                            SET name = ?, content = ?, category = ?, isBuiltIn = 1, sortOrder = ?, updatedAt = ?
                            WHERE id = ?
                            """,
                        arguments: [
                            prompt.name,
                            prompt.content,
                            prompt.category.rawValue,
                            prompt.sortOrder,
                            prompt.updatedAt,
                            existing.id,
                        ]
                    )
                    continue
                }

                if let legacyPromptID = try String.fetchOne(
                    db,
                    sql: """
                        SELECT id
                        FROM prompts
                        WHERE name = ? COLLATE NOCASE
                          AND isBuiltIn = 1
                        LIMIT 1
                        """,
                    arguments: [prompt.name]
                ) {
                    try db.execute(
                        sql: """
                            UPDATE prompts
                            SET id = ?, name = ?, content = ?, category = ?, isBuiltIn = 1, sortOrder = ?, updatedAt = ?
                            WHERE id = ?
                            """,
                        arguments: [
                            prompt.id,
                            prompt.name,
                            prompt.content,
                            prompt.category.rawValue,
                            prompt.sortOrder,
                            prompt.updatedAt,
                            legacyPromptID,
                        ]
                    )
                    continue
                }

                // A custom prompt already owns this name. Preserve the user's prompt and
                // skip re-inserting the built-in because names are globally unique today.
                let hasCustomPromptWithSameName = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1
                            FROM prompts
                            WHERE name = ? COLLATE NOCASE
                              AND isBuiltIn = 0
                        )
                        """,
                    arguments: [prompt.name]
                ) ?? false
                if hasCustomPromptWithSameName {
                    continue
                }

                // Apply the auto-run insertion guard (ADR-020 §5): if the user has
                // explicitly disabled every auto-run prompt, do not silently
                // re-introduce one via a new built-in.
                var promptToInsert = prompt
                if promptToInsert.isAutoRun && !userHasAnyAutoRunPrompt {
                    promptToInsert.isAutoRun = false
                }
                try promptToInsert.insert(db)
            }

            // Delete any built-in prompts that are no longer in the canonical list
            try db.execute(
                sql: """
                    DELETE FROM prompts
                    WHERE isBuiltIn = 1 AND id NOT IN (\(canonicalIDs.map { _ in "?" }.joined(separator: ",")))
                    """,
                arguments: StatementArguments(canonicalIDs)
            )
        }
    }
}
