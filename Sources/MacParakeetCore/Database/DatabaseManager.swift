import Foundation
import GRDB
import OSLog
import Darwin

public final class DatabaseManager: Sendable {
    public let dbQueue: DatabaseQueue

    /// Identifiers of every migration this build knows, in registration order.
    /// Derived from the migrator itself so it can never drift from `migrate()`.
    public static var registeredMigrationIdentifiers: [String] {
        makeMigrator().migrations
    }

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

    /// Open an existing database without initializing or migrating its schema.
    public init(readOnlyPath path: String) throws {
        var config = Self.makeConfiguration()
        config.readonly = true
        dbQueue = try DatabaseQueue(path: path, configuration: config)
    }

    /// Create a DatabaseManager with an in-memory database (for tests)
    public init() throws {
        let config = Self.makeConfiguration()
        dbQueue = try DatabaseQueue(configuration: config)
        try migrate()
    }

    public func appliedMigrationIdentifiers() throws -> [String] {
        try Self.appliedMigrationIdentifiers(in: dbQueue)
    }

    public static func appliedMigrationIdentifiers(at path: String) throws -> [String] {
        var config = makeConfiguration()
        config.readonly = true
        let queue = try DatabaseQueue(path: path, configuration: config)
        return try appliedMigrationIdentifiers(in: queue)
    }

    public static func unknownAppliedMigrationIdentifiers(at path: String) throws -> [String] {
        let registered = Set(registeredMigrationIdentifiers)
        return try appliedMigrationIdentifiers(at: path)
            .filter { !registered.contains($0) }
            .sorted()
    }

    private static func appliedMigrationIdentifiers(in queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            guard try db.tableExists("grdb_migrations") else {
                return []
            }
            return try String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
            )
        }
    }

    #if DEBUG
    func recordAppliedMigrationIdentifierForTesting(_ identifier: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: [identifier]
            )
        }
    }
    #endif

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
        try Self.makeMigrator().migrate(dbQueue)
        try reconcileBuiltInPrompts()
        try reconcileBuiltInQuickPrompts()
    }

    static func makeMigrator() -> DatabaseMigrator {
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
            try db.execute(
                sql: """
                        CREATE VIRTUAL TABLE dictations_fts USING fts5(
                            rawTranscript, cleanTranscript,
                            content='dictations', content_rowid='rowid'
                        )
                    """)

            // Sync triggers
            try db.execute(
                sql: """
                        CREATE TRIGGER dictations_ai AFTER INSERT ON dictations BEGIN
                            INSERT INTO dictations_fts(rowid, rawTranscript, cleanTranscript)
                            VALUES (new.rowid, new.rawTranscript, new.cleanTranscript);
                        END
                    """)
            try db.execute(
                sql: """
                        CREATE TRIGGER dictations_ad AFTER DELETE ON dictations BEGIN
                            INSERT INTO dictations_fts(dictations_fts, rowid, rawTranscript, cleanTranscript)
                            VALUES ('delete', old.rowid, old.rawTranscript, old.cleanTranscript);
                        END
                    """)
            try db.execute(
                sql: """
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
            try db.execute(
                sql: """
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
            try db.execute(
                sql: """
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
            let rows = try Row.fetchAll(
                db,
                sql: """
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
            let rows = try Row.fetchAll(
                db,
                sql: """
                        SELECT id, chatMessages FROM transcriptions WHERE chatMessages IS NOT NULL
                    """)
            let now = Date()
            var migratedRawIDs: [String] = []
            var skippedCount = 0
            for row in rows {
                let rawIDString: String? = row["id"]
                guard let transcriptionId = UUID.fromDatabaseValue(row["id"] as DatabaseValue),
                    let chatMessagesJSON = String.fromDatabaseValue(row["chatMessages"] as DatabaseValue)
                else {
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
                    let messages = try? JSONDecoder().decode([ChatMessage].self, from: data)
                {
                    if let firstUser = messages.first(where: { $0.role == .user }) {
                        title = String(firstUser.content.prefix(50))
                    }
                } else {
                    logger.notice(
                        "v0.5-chat-conversations migration could not decode messages for title derivation transcriptionId=\(transcriptionId.uuidString, privacy: .public)"
                    )
                }

                let conversationId = UUID()
                try db.execute(
                    sql: """
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
            try db.execute(
                sql: """
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

            let rows = try Row.fetchAll(
                db,
                sql: """
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
            if !columns.contains(where: { $0.name == "isDefault" })
                && !columns.contains(where: { $0.name == "isAutoRun" })
            {
                try db.alter(table: "prompts") { t in
                    t.add(column: "isDefault", .boolean).notNull().defaults(to: false)
                }
                try db.execute(
                    sql: """
                            UPDATE prompts SET isDefault = 1 WHERE name = 'General Summary' AND isBuiltIn = 1
                        """)
            }
        }

        // v0.7.2 - Rename isDefault to isAutoRun for multi-auto-run support
        migrator.registerMigration("v0.7.2-prompt-autorun") { db in
            let columns = try db.columns(in: "prompts")
            if columns.contains(where: { $0.name == "isDefault" })
                && !columns.contains(where: { $0.name == "isAutoRun" })
            {
                try db.alter(table: "prompts") { t in
                    t.rename(column: "isDefault", to: "isAutoRun")
                }
            } else if !columns.contains(where: { $0.name == "isAutoRun" }) {
                try db.alter(table: "prompts") { t in
                    t.add(column: "isAutoRun", .boolean).notNull().defaults(to: false)
                }
                try db.execute(
                    sql: """
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
            try db.execute(
                sql: """
                        CREATE INDEX IF NOT EXISTS idx_transcriptions_source_type_created_at
                        ON transcriptions(sourceType, createdAt)
                    """)
            try db.execute(
                sql: """
                        CREATE INDEX IF NOT EXISTS idx_transcriptions_favorite_created_at
                        ON transcriptions(isFavorite, createdAt)
                    """)
            try db.execute(
                sql: """
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
                t.column("day", .text).primaryKey()  // YYYY-MM-DD, local day
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
            let historyAlreadyRestored =
                try Bool.fetchOne(
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
                t.check(
                    sql: """
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

        // v0.20 — Source-scoped auto-run (ADR-020 2026-05 amendment). Adds one
        // nullable JSON column to `prompts` so a `.result` prompt can restrict
        // which transcription sources it auto-runs for (e.g. meeting-only
        // auto-notes). NULL = all sources = the historical behavior, so every
        // existing row keeps running exactly as before. Pre-check existence for
        // re-run safety. No row inserts here — the seed stays in v0.7.
        migrator.registerMigration("v0.20-prompt-applies-to-sources") { db in
            let existingColumns = try db.columns(in: "prompts").map(\.name)
            if !existingColumns.contains("appliesToSources") {
                try db.alter(table: "prompts") { t in
                    t.add(column: "appliesToSources", .text)
                }
            }
        }

        // v0.21 — App-aware AI Formatter profiles. Profiles are local user
        // data: exact app bundle IDs and display names are used only for local
        // prompt resolution and local history/debug provenance.
        migrator.registerMigration("v0.21-ai-formatter-profiles") { db in
            // Freeze the v0.21 category set inside the migration. Future
            // category additions need a follow-up migration so old and fresh
            // databases enforce the same contract.
            let allowedCategories = "'messaging', 'email', 'browser', 'notes', 'docs', 'code', 'terminal', 'other'"
            if !(try db.tableExists("ai_formatter_profiles")) {
                try db.create(table: "ai_formatter_profiles") { t in
                    t.column("id", .text).primaryKey()
                    t.column("name", .text).notNull()
                    t.column("isEnabled", .boolean).notNull().defaults(to: true)
                    t.column("targetKind", .text).notNull()
                    t.column("bundleIdentifier", .text)
                    t.column("appDisplayName", .text)
                    t.column("appCategory", .text)
                    t.column("promptTemplate", .text).notNull()
                    t.column("origin", .text).notNull().defaults(to: AIFormatterProfileOrigin.custom.rawValue)
                    t.column("sortOrder", .integer).notNull().defaults(to: 0)
                    t.column("createdAt", .text).notNull()
                    t.column("updatedAt", .text).notNull()
                    t.check(sql: "targetKind IN ('bundle', 'category')")
                    t.check(sql: "origin IN ('custom', 'template')")
                    t.check(
                        sql: """
                            (
                                targetKind = 'bundle'
                                AND bundleIdentifier IS NOT NULL
                                AND TRIM(bundleIdentifier) != ''
                                AND bundleIdentifier = LOWER(TRIM(bundleIdentifier))
                                AND appCategory IS NULL
                            )
                            OR (
                                targetKind = 'category'
                                AND appCategory IS NOT NULL
                                AND appCategory IN (\(allowedCategories))
                                AND bundleIdentifier IS NULL
                                AND appDisplayName IS NULL
                            )
                            """)
                }
                try db.create(
                    index: "idx_ai_formatter_profiles_enabled_sort",
                    on: "ai_formatter_profiles",
                    columns: ["isEnabled", "sortOrder"]
                )
                try db.create(
                    index: "idx_ai_formatter_profiles_target_kind",
                    on: "ai_formatter_profiles",
                    columns: ["targetKind"]
                )
                try db.execute(
                    sql: """
                        CREATE UNIQUE INDEX idx_ai_formatter_profiles_bundle_unique
                        ON ai_formatter_profiles(LOWER(TRIM(bundleIdentifier)))
                        WHERE targetKind = 'bundle' AND bundleIdentifier IS NOT NULL
                        """)
                try db.execute(
                    sql: """
                        CREATE UNIQUE INDEX idx_ai_formatter_profiles_category_unique
                        ON ai_formatter_profiles(appCategory)
                        WHERE targetKind = 'category' AND appCategory IS NOT NULL
                        """)
            }

            let existingColumns = try db.columns(in: "dictations").map(\.name)
            try db.alter(table: "dictations") { t in
                if !existingColumns.contains("aiFormatterProfileID") {
                    t.add(column: "aiFormatterProfileID", .text)
                }
                if !existingColumns.contains("aiFormatterProfileName") {
                    t.add(column: "aiFormatterProfileName", .text)
                }
                if !existingColumns.contains("aiFormatterProfileMatchKind") {
                    t.add(column: "aiFormatterProfileMatchKind", .text)
                }
            }

            try db.execute(
                sql: """
                    UPDATE dictations
                    SET rawTranscript = '',
                        cleanTranscript = NULL,
                        audioPath = NULL,
                        pastedToApp = NULL,
                        aiFormatterProfileID = NULL,
                        aiFormatterProfileName = NULL,
                        aiFormatterProfileMatchKind = NULL
                    WHERE hidden = 1
                    """)
        }

        // v0.22 — Durable meeting artifact folder locator. `filePath` remains
        // the mixed-audio playback/export path and can be cleared by retention.
        // This column preserves the session folder for Finder, CLI, and
        // automation surfaces after audio is intentionally deleted.
        migrator.registerMigration("v0.22-meeting-artifact-folder-path") { db in
            let columns = try db.columns(in: "transcriptions").map(\.name)
            if !columns.contains("meetingArtifactFolderPath") {
                try db.alter(table: "transcriptions") { t in
                    t.add(column: "meetingArtifactFolderPath", .text)
                }
            }

            let rows = try Row.fetchAll(
                db,
                sql: """
                        SELECT id, filePath
                        FROM transcriptions
                        WHERE sourceType = ?
                          AND filePath IS NOT NULL
                          AND TRIM(filePath) != ''
                          AND meetingArtifactFolderPath IS NULL
                    """, arguments: [Transcription.SourceType.meeting.rawValue])

            for row in rows {
                guard let rawID = String.fromDatabaseValue(row["id"] as DatabaseValue),
                    let filePath = String.fromDatabaseValue(row["filePath"] as DatabaseValue)
                else { continue }
                let folderPath = URL(fileURLWithPath: filePath)
                    .deletingLastPathComponent()
                    .standardizedFileURL
                    .path
                try db.execute(
                    sql: "UPDATE transcriptions SET meetingArtifactFolderPath = ? WHERE id = ?",
                    arguments: [folderPath, rawID]
                )
            }
        }

        // v0.23 — Durable meeting transcript segments. Raw SQL is intentional:
        // historical migrations must not depend on the evolving Codable model.
        migrator.registerMigration("v0.23-transcript-segments") { db in
            let columns = try db.columns(in: "transcriptions").map(\.name)
            if !columns.contains("transcriptSegments") {
                try db.execute(sql: "ALTER TABLE transcriptions ADD COLUMN transcriptSegments TEXT")
            }
        }

        // v0.24 — One-shot meeting start context. Raw SQL by design: migrations
        // must not depend on the evolving Codable model shape for this JSON blob.
        migrator.registerMigration("v0.24-meeting-start-context") { db in
            let columns = try db.columns(in: "transcriptions").map(\.name)
            if !columns.contains("meetingStartContext") {
                try db.execute(sql: "ALTER TABLE transcriptions ADD COLUMN meetingStartContext TEXT")
            }
        }

        // v0.25 — Local EventKit context snapshot for meeting recordings.
        // Keep the ALTER raw SQL so historical migrations never instantiate
        // the evolving Transcription Codable shape while the column is absent.
        migrator.registerMigration("v0.25-meeting-calendar-event-snapshot") { db in
            let columns = try db.columns(in: "transcriptions").map(\.name)
            if !columns.contains("calendarEventSnapshot") {
                try db.execute(sql: "ALTER TABLE transcriptions ADD COLUMN calendarEventSnapshot TEXT")
            }
        }

        // v0.26 — User-authored display titles for local transcription rows.
        // This is app metadata only: source file names and paths stay intact.
        migrator.registerMigration("v0.26-transcription-title-override") { db in
            let columns = try db.columns(in: "transcriptions").map(\.name)
            if !columns.contains("titleOverride") {
                try db.execute(sql: "ALTER TABLE transcriptions ADD COLUMN titleOverride TEXT")
            }
        }

        // v0.27 — Derived, rebuildable transcript retrieval segments and their
        // external-content FTS5 index. Raw SQL is intentional: historical
        // migrations must never depend on the evolving Codable row models.
        migrator.registerMigration("v0.27-segments-fts") { db in
            try db.execute(
                sql: """
                    CREATE TABLE segments (
                        id INTEGER PRIMARY KEY,
                        transcriptionId TEXT NOT NULL
                            REFERENCES transcriptions(id) ON DELETE CASCADE,
                        seq INTEGER NOT NULL,
                        startMs INTEGER,
                        endMs INTEGER,
                        speaker TEXT,
                        text TEXT NOT NULL,
                        segmenterVersion INTEGER NOT NULL,
                        UNIQUE(transcriptionId, seq)
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE INDEX idx_segments_transcription
                    ON segments(transcriptionId, seq)
                    """)
            try db.execute(
                sql: """
                    CREATE VIRTUAL TABLE segments_fts USING fts5(
                        text, speaker UNINDEXED,
                        content='segments', content_rowid='id',
                        tokenize='unicode61 remove_diacritics 2'
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
                        INSERT INTO segments_fts(rowid, text, speaker)
                        VALUES (new.id, new.text, new.speaker);
                    END
                    """)
            try db.execute(
                sql: """
                    CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN
                        INSERT INTO segments_fts(segments_fts, rowid, text, speaker)
                        VALUES ('delete', old.id, old.text, old.speaker);
                    END
                    """)
            try db.execute(
                sql: """
                    CREATE TRIGGER segments_au AFTER UPDATE ON segments BEGIN
                        INSERT INTO segments_fts(segments_fts, rowid, text, speaker)
                        VALUES ('delete', old.id, old.text, old.speaker);
                        INSERT INTO segments_fts(rowid, text, speaker)
                        VALUES (new.id, new.text, new.speaker);
                    END
                    """)
        }

        // v0.28 — Derived per-recording knowledge cards and their small
        // external-content FTS5 index. Raw SQL is intentional: historical
        // migrations must never depend on evolving Codable card models.
        migrator.registerMigration("v0.28-cards") { db in
            try db.execute(
                sql: """
                    CREATE TABLE cards (
                        transcriptionId TEXT PRIMARY KEY
                            REFERENCES transcriptions(id) ON DELETE CASCADE,
                        cardSchemaVersion INTEGER NOT NULL,
                        transcriptHash TEXT NOT NULL,
                        segmenterVersion INTEGER NOT NULL,
                        promptVersion TEXT NOT NULL,
                        model TEXT NOT NULL,
                        generatedAt TEXT NOT NULL,
                        synopsis TEXT NOT NULL,
                        topics TEXT NOT NULL,
                        decisions TEXT NOT NULL,
                        actions TEXT NOT NULL
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE cards_search_content (
                        rowid INTEGER PRIMARY KEY,
                        synopsis TEXT NOT NULL,
                        topics TEXT NOT NULL
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE VIRTUAL TABLE cards_fts USING fts5(
                        synopsis, topics,
                        content='cards_search_content', content_rowid='rowid',
                        tokenize='unicode61 remove_diacritics 2'
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE TRIGGER cards_ai AFTER INSERT ON cards BEGIN
                        INSERT INTO cards_search_content(rowid, synopsis, topics)
                        VALUES (
                            new.rowid,
                            new.synopsis,
                            COALESCE(
                                (SELECT group_concat(CAST(value AS TEXT), ' ')
                                 FROM json_each(new.topics)),
                                ''
                            )
                        );
                        INSERT INTO cards_fts(rowid, synopsis, topics)
                        VALUES (
                            new.rowid,
                            new.synopsis,
                            COALESCE(
                                (SELECT group_concat(CAST(value AS TEXT), ' ')
                                 FROM json_each(new.topics)),
                                ''
                            )
                        );
                    END
                    """)
            try db.execute(
                sql: """
                    CREATE TRIGGER cards_ad AFTER DELETE ON cards BEGIN
                        INSERT INTO cards_fts(cards_fts, rowid, synopsis, topics)
                        VALUES (
                            'delete',
                            old.rowid,
                            old.synopsis,
                            COALESCE(
                                (SELECT group_concat(CAST(value AS TEXT), ' ')
                                 FROM json_each(old.topics)),
                                ''
                            )
                        );
                        DELETE FROM cards_search_content WHERE rowid = old.rowid;
                    END
                    """)
            try db.execute(
                sql: """
                    CREATE TRIGGER cards_au AFTER UPDATE ON cards BEGIN
                        INSERT INTO cards_fts(cards_fts, rowid, synopsis, topics)
                        VALUES (
                            'delete',
                            old.rowid,
                            old.synopsis,
                            COALESCE(
                                (SELECT group_concat(CAST(value AS TEXT), ' ')
                                 FROM json_each(old.topics)),
                                ''
                            )
                        );
                        UPDATE cards_search_content
                        SET synopsis = new.synopsis,
                            topics = COALESCE(
                                (SELECT group_concat(CAST(value AS TEXT), ' ')
                                 FROM json_each(new.topics)),
                                ''
                            )
                        WHERE rowid = new.rowid;
                        INSERT INTO cards_fts(rowid, synopsis, topics)
                        VALUES (
                            new.rowid,
                            new.synopsis,
                            COALESCE(
                                (SELECT group_concat(CAST(value AS TEXT), ' ')
                                 FROM json_each(new.topics)),
                                ''
                            )
                        );
                    END
                    """)
        }

        // v0.29 — Remember which embedded audio stream a user explicitly
        // selected for local file transcription. Nil preserves legacy
        // automatic/single-track behavior.
        migrator.registerMigration("v0.29-transcription-audio-track") { db in
            try db.alter(table: "transcriptions") { t in
                t.add(column: "audioTrackOrdinal", .integer)
            }
        }

        // v0.30 — Durable, frame-derived meeting capture quality. The JSON
        // shape is additive and optional so legacy rows remain "unknown"
        // instead of being mislabeled healthy.
        migrator.registerMigration("v0.30-meeting-capture-report") { db in
            let columns = try db.columns(in: "transcriptions").map(\.name)
            if !columns.contains("meetingCaptureReport") {
                try db.execute(sql: "ALTER TABLE transcriptions ADD COLUMN meetingCaptureReport TEXT")
            }
        }

        // v0.31 — Per-prompt inference settings and the effective settings
        // snapshot retained with each generated result. Both are optional JSON
        // so existing rows preserve the historical provider-default behavior.
        migrator.registerMigration("v0.31-prompt-inference-settings") { db in
            let promptColumns = try db.columns(in: "prompts").map(\.name)
            if !promptColumns.contains("inferenceSettings") {
                try db.execute(sql: "ALTER TABLE prompts ADD COLUMN inferenceSettings TEXT")
            }

            let summaryColumns = try db.columns(in: "summaries").map(\.name)
            if !summaryColumns.contains("inferenceSettingsSnapshot") {
                try db.execute(sql: "ALTER TABLE summaries ADD COLUMN inferenceSettingsSnapshot TEXT")
            }
        }

        // v0.32 — Append-only speaker-attribution corrections and their
        // transcript-scoped persistent undo/redo cursor. Keep this state out
        // of `transcriptions`: callers often save whole Transcription values,
        // and an older value must not be able to overwrite correction history.
        migrator.registerMigration("v0.32-speaker-corrections") { db in
            try db.execute(sql: """
                CREATE TABLE speaker_corrections (
                    id TEXT PRIMARY KEY NOT NULL,
                    transcriptionId TEXT NOT NULL
                        REFERENCES transcriptions(id) ON DELETE CASCADE,
                    parentId TEXT,
                    sequence INTEGER NOT NULL CHECK (sequence > 0),
                    transcriptFingerprint TEXT NOT NULL,
                    operation TEXT NOT NULL CHECK (
                        operation IN (
                            'rename', 'add', 'assign', 'split', 'unsplit',
                            'merge', 'remove', 'reset'
                        )
                    ),
                    payload TEXT NOT NULL,
                    branchState TEXT NOT NULL CHECK (
                        branchState IN ('current', 'redo', 'abandoned')
                    ),
                    createdAt TEXT NOT NULL,
                    UNIQUE (transcriptionId, sequence),
                    UNIQUE (id, transcriptionId),
                    FOREIGN KEY (parentId, transcriptionId)
                        REFERENCES speaker_corrections(id, transcriptionId)
                        ON DELETE CASCADE
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_speaker_corrections_replay
                ON speaker_corrections (
                    transcriptionId,
                    transcriptFingerprint,
                    branchState,
                    sequence
                )
                """)
            try db.execute(sql: """
                CREATE TABLE speaker_correction_states (
                    transcriptionId TEXT PRIMARY KEY NOT NULL
                        REFERENCES transcriptions(id) ON DELETE CASCADE,
                    transcriptFingerprint TEXT NOT NULL,
                    headId TEXT,
                    revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
                    updatedAt TEXT NOT NULL,
                    FOREIGN KEY (headId, transcriptionId)
                        REFERENCES speaker_corrections(id, transcriptionId)
                        ON DELETE CASCADE
                )
                """)
        }

        // v0.33 — Per-result-prompt opt-in for adding meeting notes to LLM
        // context, plus the immutable preference receipt on saved results.
        migrator.registerMigration("v0.33-prompt-meeting-notes-context") { db in
            let promptColumns = try db.columns(in: "prompts").map(\.name)
            if !promptColumns.contains("includeMeetingNotes") {
                try db.alter(table: "prompts") { t in
                    t.add(column: "includeMeetingNotes", .boolean).notNull().defaults(to: false)
                }
            }

            let summaryColumns = try db.columns(in: "summaries").map(\.name)
            if !summaryColumns.contains("includeMeetingNotesSnapshot") {
                try db.alter(table: "summaries") { t in
                    t.add(column: "includeMeetingNotesSnapshot", .boolean).notNull().defaults(to: false)
                }
            }
        }

        // v0.32 — Immutable prompt versions. The legacy content/settings
        // columns remain for one bounded compatibility window, but all current
        // reads resolve them from the active version join.
        migrator.registerMigration("v0.32-prompt-versions") { db in
            try db.create(table: "prompt_versions") { t in
                t.column("id", .text).primaryKey()
                // The FK is installed after `prompts` is rebuilt below.
                t.column("promptId", .text).notNull()
                t.column("versionNumber", .integer).notNull()
                t.column("content", .text).notNull()
                t.column("inferenceSettings", .text)
                t.column("modelOverride", .text)
                t.column("origin", .text).notNull()
                t.column("changeNote", .text)
                t.column("createdAt", .text).notNull()
                t.uniqueKey(["promptId", "versionNumber"])
            }
            try db.create(
                index: "idx_prompt_versions_prompt_version",
                on: "prompt_versions",
                columns: ["promptId", "versionNumber"]
            )

            try db.alter(table: "prompts") { t in
                t.add(column: "activeVersionId", .text)
                t.add(column: "canonicalKey", .text)
                t.add(column: "lastAppliedCanonicalRevision", .integer)
                t.add(column: "userCustomizedAt", .text)
                t.add(column: "deletedAt", .text)
            }

            let canonicalByID = Dictionary(
                uniqueKeysWithValues: Prompt.builtInPrompts().map { ($0.id, $0) }
            )
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, content, isBuiltIn, inferenceSettings, updatedAt
                    FROM prompts
                    """
            )
            for row in rows {
                let promptIDValue: DatabaseValue = row["id"]
                let promptID: UUID = row["id"]
                let name: String = row["name"]
                let content: String = row["content"]
                let isBuiltIn: Bool = row["isBuiltIn"]
                let inferenceSettings: String? = row["inferenceSettings"]
                let updatedAt: Date = row["updatedAt"]
                let versionID = UUID()

                try db.execute(
                    sql: """
                        INSERT INTO prompt_versions (
                            id, promptId, versionNumber, content,
                            inferenceSettings, modelOverride, origin,
                            changeNote, createdAt
                        ) VALUES (?, ?, 1, ?, ?, NULL, ?, NULL, ?)
                        """,
                    arguments: [
                        versionID,
                        promptIDValue,
                        content,
                        inferenceSettings,
                        PromptVersion.Origin.`import`.rawValue,
                        updatedAt,
                    ]
                )

                let canonical = canonicalByID[promptID]
                let canonicalKey = isBuiltIn ? canonical?.canonicalKey : nil
                let definitionDiffers = canonical.map {
                    name != $0.name || content != $0.content
                } ?? false
                let customizedAt: Date? = {
                    guard isBuiltIn else { return nil }
                    let hasVersionCustomization: Bool
                    if let canonical {
                        hasVersionCustomization =
                            inferenceSettings != nil
                            || (canonical.category == .transform && definitionDiffers)
                    } else {
                        // A removed built-in has no bundled body to compare.
                        // Persisted per-prompt settings are nevertheless
                        // unambiguous user intent and must prevent retirement.
                        hasVersionCustomization = inferenceSettings != nil
                    }
                    return hasVersionCustomization ? updatedAt : nil
                }()
                // Result built-ins were not editable before this migration, so
                // a definition mismatch without settings is an older bundled
                // revision, not user intent. Revision zero lets reconciliation
                // append the current canonical version after migration.
                let canonicalRevision: Int? = {
                    guard isBuiltIn, let canonical else { return nil }
                    if definitionDiffers, customizedAt == nil { return 0 }
                    return canonical.lastAppliedCanonicalRevision
                }()
                try db.execute(
                    sql: """
                        UPDATE prompts
                        SET activeVersionId = ?, canonicalKey = ?,
                            lastAppliedCanonicalRevision = ?, userCustomizedAt = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        versionID,
                        canonicalKey,
                        canonicalRevision,
                        customizedAt,
                        promptIDValue,
                    ]
                )
            }

            // Soft-deleted rows must not reserve their old display name.
            try db.execute(sql: "DROP INDEX idx_prompts_name")
            try db.execute(
                sql: """
                    CREATE UNIQUE INDEX idx_prompts_name
                    ON prompts(name COLLATE NOCASE)
                    WHERE deletedAt IS NULL
                    """
            )
            try db.create(index: "idx_prompts_deleted_at", on: "prompts", columns: ["deletedAt"])
        }

        // v0.33 — Nullable prompt/version and provider/model provenance for
        // historical prompt results. Existing snapshots remain authoritative.
        migrator.registerMigration("v0.33-prompt-result-provenance") { db in
            try db.alter(table: "summaries") { t in
                t.add(column: "promptId", .text)
                    .references("prompts", onDelete: .setNull)
                t.add(column: "promptVersionId", .text)
                    .references("prompt_versions", onDelete: .setNull)
                t.add(column: "providerSnapshot", .text)
                t.add(column: "modelSnapshot", .text)
            }
        }

        // v0.34 — Meeting classification and prompt applicability policies.
        migrator.registerMigration("v0.34-meeting-classification-policies") { db in
            try db.create(table: "meeting_types") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("colorToken", .text)
                t.column("iconName", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.execute(
                sql: "CREATE UNIQUE INDEX idx_meeting_types_name ON meeting_types(name COLLATE NOCASE)"
            )

            try db.create(table: "meeting_labels") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("colorToken", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.execute(
                sql: "CREATE UNIQUE INDEX idx_meeting_labels_name ON meeting_labels(name COLLATE NOCASE)"
            )

            try db.alter(table: "transcriptions") { t in
                t.add(column: "meetingTypeId", .text)
                    .references("meeting_types", onDelete: .setNull)
            }
            try db.create(
                index: "idx_transcriptions_meeting_type",
                on: "transcriptions",
                columns: ["meetingTypeId"]
            )

            try db.create(table: "transcription_meeting_labels") { t in
                t.column("transcriptionId", .text)
                    .notNull()
                    .references("transcriptions", onDelete: .cascade)
                t.column("labelId", .text)
                    .notNull()
                    .references("meeting_labels", onDelete: .cascade)
                t.primaryKey(["transcriptionId", "labelId"])
            }
            try db.create(
                index: "idx_transcription_meeting_labels_label",
                on: "transcription_meeting_labels",
                columns: ["labelId", "transcriptionId"]
            )

            try db.create(table: "prompt_meeting_policies") { t in
                t.column("id", .text).primaryKey()
                t.column("promptId", .text)
                    .notNull()
                    .references("prompts", onDelete: .cascade)
                t.column("scopeKind", .text).notNull()
                t.column("meetingTypeId", .text)
                    .references("meeting_types", onDelete: .cascade)
                t.column("isAvailable", .boolean).notNull()
                t.column("isAutoRun", .boolean).notNull()
                t.column("sortOrder", .integer)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
                t.check(
                    sql:
                        "(scopeKind = 'all' AND meetingTypeId IS NULL) OR (scopeKind = 'type' AND meetingTypeId IS NOT NULL)"
                )
                t.check(sql: "isAutoRun = 0 OR isAvailable = 1")
            }
            try db.execute(
                sql: """
                    CREATE UNIQUE INDEX idx_prompt_meeting_policies_all
                    ON prompt_meeting_policies(promptId)
                    WHERE scopeKind = 'all'
                    """
            )
            try db.execute(
                sql: """
                    CREATE UNIQUE INDEX idx_prompt_meeting_policies_type
                    ON prompt_meeting_policies(promptId, meetingTypeId)
                    WHERE scopeKind = 'type'
                    """
            )

            let promptRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, isAutoRun, appliesToSources, sortOrder
                    FROM prompts
                    WHERE category = ? AND deletedAt IS NULL
                    """,
                arguments: [Prompt.Category.result.rawValue]
            )
            let now = Date()
            for row in promptRows {
                let promptID: DatabaseValue = row["id"]
                let isAutoRun: Bool = row["isAutoRun"]
                let appliesJSON: String? = row["appliesToSources"]
                let decodedSources = appliesJSON.flatMap {
                    try? JSONDecoder().decode(Set<Transcription.SourceType>.self, from: Data($0.utf8))
                }
                let meetingAutoRun: Bool
                if appliesJSON == nil {
                    meetingAutoRun = isAutoRun
                } else {
                    meetingAutoRun = isAutoRun && decodedSources?.contains(.meeting) == true
                }
                let sortOrder: Int = row["sortOrder"]
                try db.execute(
                    sql: """
                        INSERT INTO prompt_meeting_policies (
                            id, promptId, scopeKind, meetingTypeId, isAvailable,
                            isAutoRun, sortOrder, createdAt, updatedAt
                        ) VALUES (?, ?, 'all', NULL, 1, ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID(),
                        promptID,
                        meetingAutoRun,
                        sortOrder,
                        now,
                        now,
                    ]
                )
            }
        }

        // v0.35 — User-defined prompt organization collections.
        migrator.registerMigration("v0.35-prompt-collections") { db in
            try db.create(table: "prompt_collections") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("colorToken", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
            }
            try db.execute(
                sql: "CREATE UNIQUE INDEX idx_prompt_collections_name ON prompt_collections(name COLLATE NOCASE)"
            )
            try db.alter(table: "prompts") { t in
                t.add(column: "collectionId", .text)
                    .references("prompt_collections", onDelete: .setNull)
            }
            try db.create(
                index: "idx_prompts_collection",
                on: "prompts",
                columns: ["collectionId"]
            )
        }

        migrator.registerMigration("v0.36-drop-legacy-prompt-values") { db in
            // End the compatibility window with a forward-only rebuild:
            // migration: prompt_versions is the only source of versioned
            // values. Rebuilding is required because SQLite cannot drop these
            // legacy columns safely on every supported macOS SQLite version.
            try db.create(table: "prompts_rebuilt") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("category", .text).notNull().defaults(to: "summary")
                t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
                t.column("isVisible", .boolean).notNull().defaults(to: true)
                t.column("isAutoRun", .boolean).notNull().defaults(to: false)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
                t.column("keyboardShortcut", .text)
                t.column("runningLabel", .text)
                t.column("appliesToSources", .text)
                t.column("includeMeetingNotes", .boolean).notNull().defaults(to: false)
                t.column("collectionId", .text)
                    .references("prompt_collections", onDelete: .setNull)
                t.column("activeVersionId", .text).notNull()
                t.column("canonicalKey", .text)
                t.column("lastAppliedCanonicalRevision", .integer)
                t.column("userCustomizedAt", .text)
                t.column("deletedAt", .text)
            }
            try db.execute(
                sql: """
                    INSERT INTO prompts_rebuilt (
                        id, name, category, isBuiltIn, isVisible, isAutoRun,
                        sortOrder, createdAt, updatedAt, keyboardShortcut,
                        runningLabel, appliesToSources, includeMeetingNotes,
                        collectionId, activeVersionId,
                        canonicalKey, lastAppliedCanonicalRevision,
                        userCustomizedAt, deletedAt
                    )
                    SELECT id, name, category, isBuiltIn, isVisible, isAutoRun,
                           sortOrder, createdAt, updatedAt, keyboardShortcut,
                           runningLabel, appliesToSources, includeMeetingNotes,
                           collectionId, activeVersionId,
                           canonicalKey, lastAppliedCanonicalRevision,
                           userCustomizedAt, deletedAt
                    FROM prompts
                    """
            )
            try db.drop(table: "prompts")
            try db.rename(table: "prompts_rebuilt", to: "prompts")
            try db.execute(
                sql: """
                    CREATE UNIQUE INDEX idx_prompts_name
                    ON prompts(name COLLATE NOCASE)
                    WHERE deletedAt IS NULL
                    """
            )
            try db.create(index: "idx_prompts_deleted_at", on: "prompts", columns: ["deletedAt"])
            try db.create(index: "idx_prompts_collection", on: "prompts", columns: ["collectionId"])

            try db.create(table: "prompt_versions_rebuilt") { t in
                t.column("id", .text).primaryKey()
                t.column("promptId", .text)
                    .notNull()
                    .references("prompts", onDelete: .cascade)
                t.column("versionNumber", .integer).notNull()
                t.column("content", .text).notNull()
                t.column("inferenceSettings", .text)
                t.column("modelOverride", .text)
                t.column("origin", .text).notNull()
                t.column("changeNote", .text)
                t.column("createdAt", .text).notNull()
                t.uniqueKey(["promptId", "versionNumber"])
            }
            try db.execute(sql: "INSERT INTO prompt_versions_rebuilt SELECT * FROM prompt_versions")
            try db.drop(table: "prompt_versions")
            try db.rename(table: "prompt_versions_rebuilt", to: "prompt_versions")
            try db.create(
                index: "idx_prompt_versions_prompt_version",
                on: "prompt_versions",
                columns: ["promptId", "versionNumber"]
            )
        }

        // v0.37 — Labels are the single user-defined classification shared by
        // every transcription source. Preserve legacy custom meeting types by
        // copying them to labels and attaching those labels to their meetings.
        // The old columns/tables remain readable for downgrade compatibility.
        migrator.registerMigration("v0.37-general-transcription-labels") { db in
            let meetingTypes = try MeetingType.fetchAll(db)
            for meetingType in meetingTypes {
                let existingByName = try MeetingLabel
                    .filter(sql: "name = ? COLLATE NOCASE", arguments: [meetingType.name])
                    .fetchOne(db)

                let label: MeetingLabel
                if let existingByName {
                    label = existingByName
                } else {
                    let idIsAvailable = try MeetingLabel.fetchOne(db, key: meetingType.id) == nil
                    label = MeetingLabel(
                        id: idIsAvailable ? meetingType.id : UUID(),
                        name: meetingType.name,
                        colorToken: meetingType.colorToken,
                        sortOrder: meetingType.sortOrder,
                        isArchived: meetingType.isArchived,
                        createdAt: meetingType.createdAt,
                        updatedAt: meetingType.updatedAt
                    )
                    try label.insert(db)
                }

                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO transcription_meeting_labels (transcriptionId, labelId)
                        SELECT id, ? FROM transcriptions WHERE meetingTypeId = ?
                        """,
                    arguments: [label.id, meetingType.id]
                )
            }
        }

        // v0.38 — Prompt availability is now label-based for every
        // transcription source. Keep the meeting-type policies for downgrade
        // compatibility, but copy their effective scopes to the new model.
        migrator.registerMigration("v0.38-prompt-label-policies") { db in
            try db.create(table: "prompt_label_policies") { t in
                t.column("id", .text).primaryKey()
                t.column("promptId", .text)
                    .notNull()
                    .references("prompts", onDelete: .cascade)
                t.column("scopeKind", .text).notNull()
                t.column("labelId", .text)
                    .references("meeting_labels", onDelete: .cascade)
                t.column("isAvailable", .boolean).notNull()
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull()
                t.check(
                    sql:
                        "(scopeKind = 'all' AND labelId IS NULL) OR (scopeKind = 'label' AND labelId IS NOT NULL)"
                )
            }
            try db.execute(
                sql: """
                    CREATE UNIQUE INDEX idx_prompt_label_policies_all
                    ON prompt_label_policies(promptId)
                    WHERE scopeKind = 'all'
                    """
            )
            try db.execute(
                sql: """
                    CREATE UNIQUE INDEX idx_prompt_label_policies_label
                    ON prompt_label_policies(promptId, labelId)
                    WHERE scopeKind = 'label'
                    """
            )
            try db.create(
                index: "idx_prompt_label_policies_label_lookup",
                on: "prompt_label_policies",
                columns: ["labelId", "promptId"]
            )

            let labelRows = try Row.fetchAll(db, sql: "SELECT * FROM meeting_labels")
            let labels = try labelRows.map { try MeetingLabel(row: $0) }
            let storedLabelIDs = Dictionary(
                uniqueKeysWithValues: labelRows.map { row in
                    (row["id"] as UUID, row["id"] as DatabaseValue)
                }
            )
            let labelsByID = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
            let labelsByName = Dictionary(
                labels.map { ($0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let typesByID = Dictionary(uniqueKeysWithValues: try MeetingType.fetchAll(db).map { ($0.id, $0) })

            for row in try Row.fetchAll(db, sql: "SELECT * FROM prompt_meeting_policies") {
                let legacy = try PromptMeetingPolicy(row: row)
                let scope: PromptLabelPolicy.ScopeKind
                let labelID: UUID?
                switch legacy.scopeKind {
                case .all:
                    scope = .all
                    labelID = nil
                case .type:
                    guard let typeID = legacy.meetingTypeId,
                        let meetingType = typesByID[typeID]
                    else { continue }
                    scope = .label
                    labelID = labelsByID[typeID]?.id
                        ?? labelsByName[
                            meetingType.name.folding(
                                options: [.caseInsensitive, .diacriticInsensitive],
                                locale: nil
                            )
                        ]?.id
                    guard labelID != nil else { continue }
                }

                // Copy foreign keys as stored: decoding a TEXT UUID and then
                // encoding it through a record changes it to a BLOB, which no
                // longer matches the original parent row in SQLite.
                let promptID: DatabaseValue = row["promptId"]
                let storedLabelID = labelID.flatMap { storedLabelIDs[$0] } ?? .null
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO prompt_label_policies (
                            id, promptId, scopeKind, labelId, isAvailable, createdAt, updatedAt
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID(), promptID, scope.rawValue, storedLabelID, legacy.isAvailable,
                        row["createdAt"] as DatabaseValue, row["updatedAt"] as DatabaseValue,
                    ]
                )
            }
        }

        return migrator
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
            let userHasAnyAutoRunPrompt =
                try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM prompts WHERE isAutoRun = 1 AND deletedAt IS NULL)"
                ) ?? false

            for prompt in builtInPrompts {
                if let existing = try PromptQuery.fetch(id: prompt.id, includingDeleted: true, db: db) {
                    // A deleted or customized built-in is fully user-owned.
                    // Never resurrect it or insert a bundled candidate into its
                    // history without an explicit user action.
                    guard existing.deletedAt == nil, existing.userCustomizedAt == nil else {
                        continue
                    }

                    let canonicalRevision = prompt.lastAppliedCanonicalRevision ?? 1
                    let appliedRevision = existing.lastAppliedCanonicalRevision ?? 0
                    if canonicalRevision > appliedRevision {
                        let canonicalNameIsClaimed =
                            try Bool.fetchOne(
                                db,
                                sql: """
                                    SELECT EXISTS(
                                        SELECT 1 FROM prompts
                                        WHERE name = ? COLLATE NOCASE
                                          AND deletedAt IS NULL
                                          AND id != ?
                                    )
                                    """,
                                arguments: [prompt.name, existing.id]
                            ) ?? false
                        // Preserve both active identities. The bundled update
                        // remains pending until the collision is resolved by
                        // an explicit user rename; do not create hidden history.
                        if canonicalNameIsClaimed { continue }
                        let nextVersion =
                            (try Int.fetchOne(
                                db,
                                sql: "SELECT MAX(versionNumber) FROM prompt_versions WHERE promptId = ?",
                                arguments: [existing.id]
                            ) ?? 0) + 1
                        let version = PromptVersion(
                            promptId: existing.id,
                            versionNumber: nextVersion,
                            content: prompt.content,
                            inferenceSettings: prompt.inferenceSettings,
                            modelOverride: prompt.modelOverride,
                            origin: .systemUpdate,
                            createdAt: prompt.updatedAt
                        )
                        try version.insert(db)
                        try db.execute(
                            sql: """
                                UPDATE prompts
                                SET name = ?, category = ?, isBuiltIn = 1,
                                    activeVersionId = ?, canonicalKey = ?,
                                    lastAppliedCanonicalRevision = ?, updatedAt = ?
                                WHERE id = ?
                                """,
                            arguments: [
                                prompt.name,
                                prompt.category.rawValue,
                                version.id,
                                prompt.canonicalKey,
                                canonicalRevision,
                                prompt.updatedAt,
                                existing.id,
                            ]
                        )
                    } else {
                        var shortcut = existing.keyboardShortcut
                        if prompt.category == .transform {
                            shortcut = try Self.reconciledBuiltInTransformShortcut(
                                existing: existing,
                                canonical: prompt,
                                db: db
                            )
                        }
                        try db.execute(
                            sql: """
                                UPDATE prompts
                                SET isBuiltIn = 1, canonicalKey = ?,
                                    lastAppliedCanonicalRevision = ?,
                                    isAutoRun = ?, keyboardShortcut = ?
                                WHERE id = ?
                                """,
                            arguments: [
                                prompt.canonicalKey,
                                canonicalRevision,
                                prompt.category == .transform ? false : existing.isAutoRun,
                                shortcut,
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
                    // Preserve the legacy row and its history, but retire it so
                    // the stable canonical identity can be inserted safely.
                    try db.execute(
                        sql: "UPDATE prompts SET deletedAt = ?, updatedAt = ? WHERE id = ?",
                        arguments: [prompt.updatedAt, prompt.updatedAt, legacyPromptID]
                    )
                }

                // A custom prompt already owns this name. Preserve the user's prompt and
                // skip re-inserting the built-in because names are globally unique today.
                let hasCustomPromptWithSameName =
                    try Bool.fetchOne(
                        db,
                        sql: """
                            SELECT EXISTS(
                                SELECT 1
                                FROM prompts
                                WHERE name = ? COLLATE NOCASE
                                  AND isBuiltIn = 0
                                  AND deletedAt IS NULL
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
                try Self.insertCanonicalPrompt(promptToInsert, db: db)
            }

            // Retire removed built-ins without destroying prompt history.
            var retirementArguments: StatementArguments = [Date(), Date()]
            retirementArguments += StatementArguments(canonicalIDs)
            try db.execute(
                sql: """
                    UPDATE prompts
                    SET deletedAt = COALESCE(deletedAt, ?), updatedAt = ?
                    WHERE isBuiltIn = 1
                      AND deletedAt IS NULL
                      AND userCustomizedAt IS NULL
                      AND id NOT IN (\(canonicalIDs.map { _ in "?" }.joined(separator: ",")))
                    """,
                arguments: retirementArguments
            )
        }
    }

    private static func insertCanonicalPrompt(_ prompt: Prompt, db: Database) throws {
        let version = PromptVersion(
            promptId: prompt.id,
            versionNumber: 1,
            content: prompt.content,
            inferenceSettings: prompt.inferenceSettings,
            modelOverride: prompt.modelOverride,
            origin: .systemUpdate,
            createdAt: prompt.createdAt
        )
        try db.execute(
            sql: """
                INSERT INTO prompts (
                    id, name, category, isBuiltIn, isVisible, isAutoRun,
                    sortOrder, createdAt, updatedAt, keyboardShortcut,
                    runningLabel, appliesToSources, includeMeetingNotes, activeVersionId,
                    canonicalKey, lastAppliedCanonicalRevision,
                    userCustomizedAt, deletedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, NULL, NULL)
                """,
            arguments: [
                prompt.id,
                prompt.name,
                prompt.category.rawValue,
                prompt.isBuiltIn,
                prompt.isVisible,
                prompt.isAutoRun,
                prompt.sortOrder,
                prompt.createdAt,
                prompt.updatedAt,
                prompt.keyboardShortcut,
                prompt.runningLabel,
                prompt.includeMeetingNotes,
                version.id,
                prompt.canonicalKey,
                prompt.lastAppliedCanonicalRevision,
            ]
        )
        let storedVersion = version
        try storedVersion.insert(db)
        if prompt.category == .result, try db.tableExists("prompt_meeting_policies") {
            let policy = PromptMeetingPolicy.defaultForNewPrompt(prompt, now: prompt.createdAt)
            try policy.insert(db)
        }
    }

    /// The Phase-2 built-in Transforms moved from bare Option+digit to
    /// Control-Option+digit defaults so they stop stealing the Option-only
    /// symbols some Mac layouts type (⌥1 = ¡, ⌥2 = ™, ⌥3 = # / £, …). Migrate a
    /// built-in row that still carries the exact legacy Option+digit default to
    /// the new chord; leave custom or cleared bindings untouched, and clear
    /// rather than duplicate when the new chord is already claimed.
    private static func reconciledBuiltInTransformShortcut(
        existing: Prompt,
        canonical: Prompt,
        db: Database
    ) throws -> String? {
        guard let legacyShortcut = legacyTransformOptionDefaults[canonical.name],
            existing.shortcut == legacyShortcut
        else {
            return existing.keyboardShortcut
        }

        guard let canonicalShortcut = canonical.shortcut else { return nil }
        if try transformShortcutIsUsed(canonicalShortcut, excluding: existing.id, db: db) {
            return nil
        }
        return canonical.keyboardShortcut
    }

    /// Legacy Option+digit defaults that predate the Control-Option+digit move,
    /// keyed by built-in Transform name. A row still carrying exactly this
    /// shortcut migrates to its canonical Control-Option+digit default.
    private static let legacyTransformOptionDefaults: [String: KeyboardShortcut] = [
        "Polish": KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x12,  // kVK_ANSI_1
            keyLabel: "1"
        ),
        "Distill": KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x13,  // kVK_ANSI_2
            keyLabel: "2"
        ),
        "Decide": KeyboardShortcut(
            modifiers: KeyboardShortcut.ModifierFlag.option.rawValue,
            keyCode: 0x14,  // kVK_ANSI_3
            keyLabel: "3"
        ),
    ]

    private static func transformShortcutIsUsed(
        _ shortcut: KeyboardShortcut,
        excluding id: UUID,
        db: Database
    ) throws -> Bool {
        let transforms = try PromptQuery.fetchAll(category: .transform, db: db)
        return transforms.contains { $0.id != id && $0.shortcut == shortcut }
    }
}
