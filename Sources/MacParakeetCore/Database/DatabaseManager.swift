import Foundation
import GRDB
import OSLog
import Darwin

public final class DatabaseManager: Sendable {
    public let dbQueue: DatabaseQueue

    #if DEBUG
    private static let sqlTraceEnvKey = "MACPARAKEET_DEBUG_SQL"
    #endif

    /// Create a DatabaseManager with a file-backed database
    public init(path: String) throws {
        let config = Self.makeConfiguration()
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try Self.withMigrationLock(forDatabasePath: path) {
            try migrate()
        }
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
        config.busyMode = .timeout(5)
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

        // v0.5 — Private dictation mode: hidden flag + wordCount column.
        // Pre-check column existence so a hand-restored DB (or one whose
        // grdb_migrations row was lost) doesn't fail with `duplicate column`
        // on re-run. Mirrors the v0.7.1-prompt-default pattern below.
        migrator.registerMigration("v0.5-private-dictation") { db in
            let existingColumns = try db.columns(in: "dictations").map(\.name)
            try db.alter(table: "dictations") { t in
                if !existingColumns.contains("hidden") {
                    t.add(column: "hidden", .boolean).notNull().defaults(to: false)
                }
                if !existingColumns.contains("wordCount") {
                    t.add(column: "wordCount", .integer).notNull().defaults(to: 0)
                }
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

            // Migrate existing chatMessages from transcriptions into chat_conversations.
            //
            // We track exactly which rows successfully migrated so the
            // chatMessages-nullification at the end only touches rows whose
            // content has actually been preserved in chat_conversations.
            // Earlier versions of this migration ran a blanket
            // `UPDATE ... SET chatMessages = NULL WHERE chatMessages IS NOT NULL`
            // after the loop, which silently nulled rows whose primary key
            // couldn't be parsed as a UUID -- their content was dropped with
            // no audit trail. Now: skipped rows are logged via OSLog and
            // their chatMessages column is left intact for forensic recovery.
            let logger = Logger(subsystem: "com.macparakeet.core", category: "DatabaseMigration")
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, chatMessages FROM transcriptions WHERE chatMessages IS NOT NULL
            """)
            let now = Date()
            var migratedRawIDs: [String] = []
            var skippedCount = 0
            for row in rows {
                let rawIDString: String? = row["id"]
                guard let transcriptionId = UUID.fromDatabaseValue(row["id"] as DatabaseValue),
                      let chatMessagesJSON = String.fromDatabaseValue(row["chatMessages"] as DatabaseValue) else {
                    skippedCount += 1
                    if let rawIDString {
                        logger.warning(
                            "v0.5-chat-conversations migration skipped row with unparseable id rawID=\(rawIDString, privacy: .private(mask: .hash))"
                        )
                    } else {
                        logger.warning("v0.5-chat-conversations migration skipped row with missing id")
                    }
                    continue
                }

                // Derive title from first user message. Decode failure here
                // only loses the derived title -- the raw JSON is still
                // preserved in chat_conversations.messages.
                var title = "Chat"
                if let data = chatMessagesJSON.data(using: .utf8),
                   let messages = try? JSONDecoder().decode([ChatMessage].self, from: data) {
                    if let firstUser = messages.first(where: { $0.role == .user }) {
                        title = String(firstUser.content.prefix(50))
                    }
                } else {
                    logger.notice(
                        "v0.5-chat-conversations migration could not decode messages for title derivation transcriptionId=\(transcriptionId.uuidString, privacy: .public)"
                    )
                }

                let conversationId = UUID()
                try db.execute(sql: """
                    INSERT INTO chat_conversations (id, transcriptionId, title, messages, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [conversationId, transcriptionId, title, chatMessagesJSON, now, now])
                migratedRawIDs.append(rawIDString ?? transcriptionId.uuidString)
            }

            if skippedCount > 0 {
                logger.warning(
                    "v0.5-chat-conversations migration finished with skipped=\(skippedCount, privacy: .public) migrated=\(migratedRawIDs.count, privacy: .public). Skipped rows retain their chatMessages column for recovery."
                )
            }

            // Null out migrated chatMessages only -- skipped rows keep their
            // column intact. SQLite has no efficient `id IN (large list)`
            // when the list grows; null per-id which preserves the contract.
            for rawID in migratedRawIDs {
                try db.execute(sql: "UPDATE transcriptions SET chatMessages = NULL WHERE id = ?", arguments: [rawID])
            }
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
            let legacySummaryPrompt = Prompt.classicSummaryPrompt(now: now)
            // Historical v0.7 prompts only — `.transform` category arrives in
            // v0.13. Raw SQL with the v0.7-era column list (no
            // `keyboardShortcut`, no `runningLabel`) so this migration is
            // decoupled from later additions to the Prompt model — same
            // pattern as the `summaries` insert below.
            for prompt in Prompt.builtInPrompts(now: now) where prompt.category == .result {
                try db.execute(
                    sql: """
                        INSERT INTO prompts (
                            id, name, content, category, isBuiltIn, isVisible,
                            isAutoRun, sortOrder, createdAt, updatedAt
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        prompt.id,
                        prompt.name,
                        prompt.content,
                        prompt.category.rawValue,
                        prompt.isBuiltIn,
                        prompt.isVisible,
                        prompt.isAutoRun,
                        prompt.sortOrder,
                        prompt.createdAt,
                        prompt.updatedAt,
                    ]
                )
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
                        legacySummaryPrompt.name,
                        legacySummaryPrompt.content,
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

        // v0.8 - Live meeting notepad: capture user notes alongside the
        // transcript. Surfaced to the user via the transcription detail page,
        // the `notes.md` sidecar in the meeting session folder, and the chat
        // path's optional `userNotes` parameter (ADR-020 + 2026-05-02
        // amendment that reverted the auto-run "Memo-Steered Notes" prompt
        // but kept the column and the {{userNotes}} template variable).
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

        // v0.8 - Engine attribution: capture which STT engine + variant produced
        // each transcript/dictation. NULL for legacy rows is intentional —
        // pre-Whisper data is unambiguously Parakeet but post-Whisper-merge
        // rows of unknown engine should not be silently labeled.
        migrator.registerMigration("v0.8-engine-attribution") { db in
            let transcriptionColumns = try db.columns(in: "transcriptions").map(\.name)
            try db.alter(table: "transcriptions") { t in
                if !transcriptionColumns.contains("engine") {
                    t.add(column: "engine", .text)
                }
                if !transcriptionColumns.contains("engineVariant") {
                    t.add(column: "engineVariant", .text)
                }
            }
            let dictationColumns = try db.columns(in: "dictations").map(\.name)
            try db.alter(table: "dictations") { t in
                if !dictationColumns.contains("engine") {
                    t.add(column: "engine", .text)
                }
                if !dictationColumns.contains("engineVariant") {
                    t.add(column: "engineVariant", .text)
                }
            }
        }

        migrator.registerMigration("v0.9-derived-title-snippet") { db in
            let columns = try db.columns(in: "transcriptions").map(\.name)
            try db.alter(table: "transcriptions") { t in
                if !columns.contains("derivedTitle") {
                    t.add(column: "derivedTitle", .text)
                }
                if !columns.contains("derivedSnippet") {
                    t.add(column: "derivedSnippet", .text)
                }
            }
        }

        // v0.10 — Live meeting Ask tab quick prompts. User-customizable Ask
        // shortcuts with an explicit `isPinned` presentation flag. Built-ins
        // are seeded by the in-app reconciler
        // (`QuickPromptRepository.seedIfNeeded()`), which is the single source
        // of truth for canonical IDs and runs on both first launch and every
        // subsequent launch.
        migrator.registerMigration("v0.10-quick-prompts") { db in
            try db.create(table: "quick_prompts") { t in
                t.column("id", .text).primaryKey()
                t.column("label", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("groupLabel", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("isVisible", .boolean).notNull().defaults(to: true)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.create(
                index: "idx_quick_prompts_pinned_sort",
                on: "quick_prompts",
                columns: ["isPinned", "sortOrder"]
            )
        }

        migrator.registerMigration("v0.10-transcription-library-indexes") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_transcriptions_source_type_created_at
                ON transcriptions(sourceType, createdAt)
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_transcriptions_favorite_created_at
                ON transcriptions(isFavorite, createdAt)
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_transcriptions_status_created_at
                ON transcriptions(status, createdAt)
            """)
        }

        // v0.11 — Per-day dictation rollup (Stats tab heatmap, current/longest
        // streak). Keyed by local-calendar day so the heatmap reflects what the
        // user actually experienced. Survives `Clear History` for the same
        // reason `lifetime_dictation_stats` does (issue #124) — the user can
        // wipe transcripts without losing their streak. Backfilled from
        // existing completed rows in Swift so we use `Calendar.current` rather
        // than SQLite's UTC-leaning `date()` function.
        migrator.registerMigration("v0.11-daily-dictation-stats") { db in
            try db.create(table: "daily_dictation_stats") { t in
                t.column("day", .text).primaryKey()       // YYYY-MM-DD, local day
                t.column("count", .integer).notNull().defaults(to: 0)
                t.column("words", .integer).notNull().defaults(to: 0)
                t.column("durationMs", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .text).notNull()
            }
            try DictationRepository.backfillDailyStats(db: db)
        }

        // v0.12 — "Undo AI edit" per-row override. When true, history /
        // history-copy / menu-bar-paste / export surfaces show `rawTranscript`
        // even if `cleanTranscript` is non-nil. Reversible — the cleaned
        // value stays on the row. Pre-check column existence so a hand-restored
        // DB (or one whose grdb_migrations row was lost) doesn't fail with
        // `duplicate column` on re-run.
        migrator.registerMigration("v0.12-dictation-display-raw") { db in
            let existingColumns = try db.columns(in: "dictations").map(\.name)
            if !existingColumns.contains("displayRawTranscript") {
                try db.alter(table: "dictations") { t in
                    t.add(column: "displayRawTranscript", .boolean).notNull().defaults(to: false)
                }
            }
        }

        // v0.13 — Transforms (ADR-022). Adds two nullable columns to
        // `prompts` so `.transform`-category rows can carry their bound
        // hotkey and an optional running-pill label. `.result` (summary)
        // rows ignore both columns — they remain NULL there. Pre-check
        // existence for re-run safety.
        migrator.registerMigration("v0.13-prompt-transforms") { db in
            let existingColumns = try db.columns(in: "prompts").map(\.name)
            if !existingColumns.contains("keyboardShortcut") || !existingColumns.contains("runningLabel") {
                try db.alter(table: "prompts") { t in
                    if !existingColumns.contains("keyboardShortcut") {
                        t.add(column: "keyboardShortcut", .text)
                    }
                    if !existingColumns.contains("runningLabel") {
                        t.add(column: "runningLabel", .text)
                    }
                }
            }
        }

        // v0.14 — Local-only Transform history. Retained as a registered
        // migration so databases that ran the former workbench schema keep a
        // valid GRDB migration ledger; v0.16 drops the table.
        migrator.registerMigration("v0.14-transform-history") { db in
            try db.create(table: "transform_history") { t in
                t.column("id", .text).primaryKey()
                t.column("transformId", .text)
                t.column("transformName", .text).notNull()
                t.column("inputText", .text).notNull()
                t.column("outputText", .text).notNull()
                t.column("sourceAppBundleID", .text)
                t.column("sourceAppName", .text)
                t.column("capturePath", .text).notNull()
                t.column("replacementPath", .text).notNull()
                t.column("llmElapsedMs", .integer).notNull().defaults(to: 0)
                t.column("totalElapsedMs", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.create(
                index: "idx_transform_history_created_at",
                on: "transform_history",
                columns: ["createdAt"]
            )
            try db.create(
                index: "idx_transform_history_transform_id",
                on: "transform_history",
                columns: ["transformId"]
            )
        }

        // v0.15 — Transform Workbench profiles and writing samples. Retained
        // for migration-ledger compatibility; v0.16 drops these tables because
        // the workbench surface was removed before merge.
        migrator.registerMigration("v0.15-transform-workbench") { db in
            try db.create(table: "transform_profiles") { t in
                t.column("promptId", .text)
                    .primaryKey()
                    .references("prompts", onDelete: .cascade)
                t.column("enabledRuleIDsJSON", .text).notNull().defaults(to: "[]")
                t.column("customInstructions", .text)
                t.column("useWritingSamples", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.create(table: "writing_samples") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("text", .text).notNull()
                t.column("wordCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.create(
                index: "idx_writing_samples_updated_at",
                on: "writing_samples",
                columns: ["updatedAt"]
            )
        }

        // v0.16 — Remove the abandoned Transform Workbench tables. This keeps
        // existing developer/prerelease databases from retaining selected-text
        // rewrite history or writing samples after the feature was reverted.
        migrator.registerMigration("v0.16-drop-transform-workbench-tables") { db in
            let historyAlreadyRestored = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier = ?)",
                arguments: ["v0.17-recreate-transform-history"]
            ) ?? false
            try db.execute(sql: "DROP TABLE IF EXISTS transform_profiles")
            try db.execute(sql: "DROP TABLE IF EXISTS writing_samples")
            if !historyAlreadyRestored {
                try db.execute(sql: "DROP TABLE IF EXISTS transform_history")
            }
        }

        // v0.17 — Restore local Transform run history (without the workbench
        // profiles/writing-samples that v0.16 cleaned up). Recreates the same
        // table v0.14 defined so dev databases that lost it in v0.16 get it
        // back; fresh installs land here after v0.14/v0.15/v0.16 run in order.
        migrator.registerMigration("v0.17-recreate-transform-history") { db in
            try db.create(table: "transform_history", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("transformId", .text)
                t.column("transformName", .text).notNull()
                t.column("inputText", .text).notNull()
                t.column("outputText", .text).notNull()
                t.column("sourceAppBundleID", .text)
                t.column("sourceAppName", .text)
                t.column("capturePath", .text).notNull()
                t.column("replacementPath", .text).notNull()
                t.column("llmElapsedMs", .integer).notNull().defaults(to: 0)
                t.column("totalElapsedMs", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.create(
                index: "idx_transform_history_created_at",
                on: "transform_history",
                columns: ["createdAt"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_transform_history_transform_id",
                on: "transform_history",
                columns: ["transformId"],
                ifNotExists: true
            )
        }

        // v0.18 — Local LLM run metadata. This table intentionally stores
        // operational metadata only; transcript/prompt/chat body content stays
        // in feature-owned tables such as summaries, chat_conversations, and
        // transform_history.
        migrator.registerMigration("v0.18-llm-runs") { db in
            try db.create(table: "llm_runs") { t in
                t.column("id", .text).primaryKey()
                t.column("operationID", .text)
                t.column("feature", .text).notNull()
                t.column("status", .text).notNull()
                t.column("dictationId", .text)
                    .references("dictations", onDelete: .cascade)
                t.column("transcriptionId", .text)
                    .references("transcriptions", onDelete: .cascade)
                t.column("promptResultId", .text)
                    .references("summaries", onDelete: .cascade)
                t.column("chatConversationId", .text)
                    .references("chat_conversations", onDelete: .cascade)
                t.column("transformHistoryId", .text)
                    .references("transform_history", onDelete: .cascade)
                t.column("provider", .text)
                t.column("model", .text)
                t.column("errorType", .text)
                t.column("promptTokens", .integer)
                t.column("completionTokens", .integer)
                t.column("totalTokens", .integer)
                t.column("latencyMs", .integer)
                t.column("inputChars", .integer).notNull().defaults(to: 0)
                t.column("outputChars", .integer)
                t.column("stopReason", .text)
                t.column("inputTruncated", .boolean).notNull().defaults(to: false)
                t.column("defaultPromptUsed", .boolean)
                t.column("messageCount", .integer)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
                t.check(sql: """
                    dictationId IS NOT NULL
                    OR transcriptionId IS NOT NULL
                    OR promptResultId IS NOT NULL
                    OR chatConversationId IS NOT NULL
                    OR transformHistoryId IS NOT NULL
                    """)
            }
            try db.create(
                index: "idx_llm_runs_feature_created_at",
                on: "llm_runs",
                columns: ["feature", "createdAt"]
            )
            try db.create(
                index: "idx_llm_runs_provider_model_created_at",
                on: "llm_runs",
                columns: ["provider", "model", "createdAt"]
            )
            try db.create(
                index: "idx_llm_runs_status_created_at",
                on: "llm_runs",
                columns: ["status", "createdAt"]
            )
            try db.create(
                index: "idx_llm_runs_dictation_id",
                on: "llm_runs",
                columns: ["dictationId"]
            )
            try db.create(
                index: "idx_llm_runs_transcription_id",
                on: "llm_runs",
                columns: ["transcriptionId"]
            )
            try db.create(
                index: "idx_llm_runs_prompt_result_id",
                on: "llm_runs",
                columns: ["promptResultId"]
            )
            try db.create(
                index: "idx_llm_runs_chat_conversation_id",
                on: "llm_runs",
                columns: ["chatConversationId"]
            )
            try db.create(
                index: "idx_llm_runs_transform_history_id",
                on: "llm_runs",
                columns: ["transformHistoryId"]
            )
        }

        // v0.19 — Dictation language attribution. Transcriptions have stored
        // `language` since v0.1; dictations now keep the same normalized STT
        // language code so completion and operation telemetry can use the
        // persisted row as the source of truth without sending transcript text.
        migrator.registerMigration("v0.19-dictation-language") { db in
            let existingColumns = try db.columns(in: "dictations").map(\.name)
            if !existingColumns.contains("language") {
                try db.alter(table: "dictations") { t in
                    t.add(column: "language", .text)
                }
            }
        }

        try migrator.migrate(dbQueue)
        try reconcileBuiltInPrompts()
        try reconcileBuiltInQuickPrompts()
    }

    private static func withMigrationLock<T>(forDatabasePath path: String, _ body: () throws -> T) throws -> T {
        let lockPath = path + ".migration.lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }

        guard flock(fd, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(fd, LOCK_UN) }

        return try body()
    }

    private func reconcileBuiltInQuickPrompts() throws {
        let repo = QuickPromptRepository(dbQueue: dbQueue)
        try repo.seedIfNeeded()
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
                    if prompt.category == .transform {
                        try db.execute(
                            sql: """
                                UPDATE prompts
                                SET category = ?, isBuiltIn = 1, isVisible = 1, isAutoRun = 0, sortOrder = ?
                                WHERE id = ?
                                """,
                            arguments: [
                                prompt.category.rawValue,
                                prompt.sortOrder,
                                existing.id,
                            ]
                        )
                    } else {
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
                    }
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
