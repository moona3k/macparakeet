# MacParakeet Data Model

> Status: **ACTIVE**

## Overview

MacParakeet uses **SQLite via GRDB** for all persistent storage. Single database file, no cloud sync, no accounts. Data lives at `~/Library/Application Support/MacParakeet/macparakeet.db`.

**Design Principle (YAGNI):** Only add tables when a version needs them. Don't create empty tables for future features.

## Relationship Diagram

```
┌──────────────────┐       ┌──────────────────────────────┐
│    dictations    │ ────▶ │ lifetime_dictation_stats     │  v0.7.4 — Singleton counter
└──────────────────┘       └──────────────────────────────┘    (survives row deletion)
   v0.1 — Voice dictation history

┌──────────────────┐       ┌─────────────────────────┐
│  transcriptions  │◄──FK──│   chat_conversations    │  v0.5 — Multi-conversation chat
│                  │◄──FK──│      summaries          │  v0.5 — Multi-summary per transcript
└──────────────────┘       └─────────────────────────┘
   v0.1 — File transcription records

┌──────────────────┐
│   custom_words   │   v0.2 — Vocabulary corrections
└──────────────────┘

┌──────────────────┐
│  text_snippets   │   v0.2 — Trigger → expansion shortcuts
└──────────────────┘

┌──────────────────┐
│     prompts      │   v0.5 — Reusable prompt templates
└──────────────────┘
```

Tables are self-contained domains with two exceptions: `chat_conversations` and `summaries` have foreign keys to `transcriptions` with cascading delete.

---

## Tables

### `dictations` (v0.1)

Stores every voice dictation captured via the system-wide hotkey.

```sql
CREATE TABLE dictations (
    id TEXT PRIMARY KEY,                            -- UUID string
    createdAt TEXT NOT NULL,                         -- ISO 8601 timestamp
    durationMs INTEGER NOT NULL,                     -- Recording duration in milliseconds
    rawTranscript TEXT NOT NULL,                      -- Unprocessed STT output
    cleanTranscript TEXT,                             -- Post-processed text (nullable if mode=raw)
    audioPath TEXT,                                   -- Path to saved audio file (nullable if not retained)
    pastedToApp TEXT,                                 -- Bundle ID of app text was pasted into
    processingMode TEXT NOT NULL DEFAULT 'raw',        -- 'raw' (v0.1) or 'clean' (v0.2 default)
    status TEXT NOT NULL DEFAULT 'completed',          -- 'recording', 'processing', 'completed', 'error'
    errorMessage TEXT,                                -- Error details if status='error'
    hidden INTEGER NOT NULL DEFAULT 0,                -- v0.5: Private dictation mode (excluded from history)
    wordCount INTEGER NOT NULL DEFAULT 0,             -- v0.5: Cached word count for voice stats
    updatedAt TEXT NOT NULL                           -- ISO 8601 timestamp
);

CREATE INDEX idx_dictations_created_at ON dictations(createdAt DESC);

-- Note: FTS5 virtual table + sync triggers were created in v0.1 but dropped in v0.5
-- (never queried — search uses LIKE). Kept in migration history but not in active schema.
```

**Notes:**
- `audioPath` is nullable because audio retention is configurable (Settings > Storage).
- `pastedToApp` captures the frontmost app's bundle ID at paste time (e.g., `com.apple.TextEdit`). Useful for history context.
- `processingMode` records which mode was active when the dictation was captured.
- ~~FTS5 was created in v0.1 but dropped in v0.5~~ — search uses `LIKE` queries instead. The FTS5 table and its 3 sync triggers added write overhead on every INSERT/UPDATE/DELETE without being queried.

---

### `transcriptions` (v0.1)

Stores file transcription records. Separate from dictations because the data shape and lifecycle differ significantly (file metadata, word timestamps, speaker info, export paths).

```sql
CREATE TABLE transcriptions (
    id TEXT PRIMARY KEY,                              -- UUID string
    createdAt TEXT NOT NULL,                           -- ISO 8601 timestamp
    fileName TEXT NOT NULL,                            -- Original filename (e.g., "interview.mp3")
    filePath TEXT,                                     -- Original file path (nullable, may be moved/deleted)
    fileSizeBytes INTEGER,                             -- Original file size
    durationMs INTEGER,                                -- Audio/video duration in milliseconds
    rawTranscript TEXT,                                 -- Unprocessed STT output (nullable while processing)
    cleanTranscript TEXT,                               -- Post-processed text
    wordTimestamps TEXT,                                -- JSON: [{"word":"Hello","startMs":0,"endMs":500,"confidence":0.98,"speakerId":"S1"}]
    language TEXT DEFAULT 'en',                         -- Detected or specified language code
    speakerCount INTEGER,                              -- Number of detected speakers (v0.4 diarization)
    speakers TEXT,                                      -- JSON: [{"id":"S1","label":"Speaker 1"},{"id":"S2","label":"Sarah"}] (v0.4 diarization)
    diarizationSegments TEXT,                           -- JSON: [{"speakerId":"S1","startMs":0,"endMs":5000},...] (v0.4 diarization)
    summary TEXT,                                       -- v0.4: LLM-generated transcript summary
    chatMessages TEXT,                                  -- v0.4: JSON array of LLM chat messages
    status TEXT NOT NULL DEFAULT 'processing',          -- 'processing', 'completed', 'error', 'cancelled'
    errorMessage TEXT,                                  -- Error details if status='error'
    exportPath TEXT,                                    -- Path to last export (nullable)
    sourceURL TEXT,                                     -- YouTube/web URL if transcription sourced from URL (v0.3)
    thumbnailURL TEXT,                                  -- v0.5: YouTube video thumbnail URL
    channelName TEXT,                                   -- v0.5: YouTube channel name
    videoDescription TEXT,                              -- v0.5: YouTube video description
    isFavorite INTEGER NOT NULL DEFAULT 0,              -- v0.5: User favorite marker
    sourceType TEXT NOT NULL DEFAULT 'file',            -- v0.6: 'file', 'youtube', or 'meeting'
    updatedAt TEXT NOT NULL                             -- ISO 8601 timestamp
);

CREATE INDEX idx_transcriptions_created_at ON transcriptions(createdAt DESC);
```

**Notes:**
- `wordTimestamps` is a JSON text column, not a separate table. One transcription = one blob of timestamps. GRDB can decode this via `Codable`.
- `speakerCount` and `speakers` are nullable, populated only when diarization is available (v0.4).
- `filePath` is nullable because the original file may be moved or deleted after transcription.
- For meeting recordings, `filePath` points to the mixed `meeting.m4a` artifact used for playback/export, while the per-source `microphone.m4a`, `system.m4a`, and `meeting-recording-metadata.json` sidecar remain inside the same session folder.
- Saved meeting retranscribes reconstruct the archived meeting from that folder when the sidecar exists, so the library path can reuse the same aligned dual-source finalization flow as the immediate post-stop path.
- `sourceURL` distinguishes URL-sourced transcriptions (YouTube) from local file transcriptions. Added in v0.3.
- `thumbnailURL`, `channelName`, `videoDescription` store YouTube metadata fetched during download. Added in v0.5.
- `isFavorite` enables user-marked favorites with filtered library view. Added in v0.5.
- `sourceType` distinguishes the origin of a transcription: `'file'` (drag-drop), `'youtube'` (URL), or `'meeting'` (meeting recording). Added in v0.6. Default `'file'` for backward compatibility. Existing rows with `sourceURL IS NOT NULL` are backfilled to `'youtube'`.
- No FTS on transcriptions in v0.1. Search by filename or scroll the list. Revisit if the list grows large.

**Diarization data (v0.4):**
- `speakerCount`: Number of detected speakers (e.g., 2). Nil if diarization not run or failed.
- `speakers`: JSON array of `SpeakerInfo` objects mapping stable IDs to display labels (e.g., `[{"id":"S1","label":"Speaker 1"},{"id":"S2","label":"Sarah"}]`). Rename updates the `label` field only — no word rewrite needed.
- `diarizationSegments`: JSON array of raw diarization segments (e.g., `[{"speakerId":"S1","startMs":0,"endMs":5000}]`). Used for accurate speaking time analytics. Nil if diarization not run or failed.
- Speaker assignment per word is stored via `speakerId` on each `WordTimestamp` entry using **stable IDs** (`"S1"`, `"S2"`) — not display labels. Display labels are resolved via the `speakers` mapping.
- All diarization fields are nullable. If diarization fails, ASR result is still persisted with these fields as nil.

---

### `custom_words` (v0.2)

User-defined vocabulary corrections. When Parakeet outputs "para keet", a custom word can correct it to "Parakeet".

```sql
CREATE TABLE custom_words (
    id TEXT PRIMARY KEY,                              -- UUID string
    word TEXT NOT NULL,                                -- The word/phrase to match in STT output
    replacement TEXT,                                  -- What to replace it with (nullable = vocabulary anchor)
    source TEXT NOT NULL DEFAULT 'manual',              -- 'manual' or 'learned' (future)
    isEnabled INTEGER NOT NULL DEFAULT 1,              -- Toggle without deleting
    createdAt TEXT NOT NULL,                           -- ISO 8601 timestamp
    updatedAt TEXT NOT NULL                            -- ISO 8601 timestamp
);

CREATE UNIQUE INDEX idx_custom_words_word ON custom_words(word COLLATE NOCASE);
```

**Notes:**
- `replacement` nullable means "vocabulary anchor" mode: the word is correct as-is, just ensure STT doesn't mangle it.
- `source` distinguishes user-created entries from future auto-learned ones.
- Case-insensitive unique index prevents duplicate entries for "Parakeet" vs "parakeet".

---

### `text_snippets` (v0.2)

Natural language trigger phrase expansion. Say a trigger phrase during dictation, get a full expansion. Applied during clean text processing. Triggers are natural phrases (not abbreviations) because STT outputs natural speech.

```sql
CREATE TABLE text_snippets (
    id TEXT PRIMARY KEY,                              -- UUID string
    trigger TEXT NOT NULL,                             -- Natural language trigger phrase (e.g., "my address")
    expansion TEXT NOT NULL,                           -- Full expansion text
    isEnabled INTEGER NOT NULL DEFAULT 1,              -- Toggle without deleting
    useCount INTEGER NOT NULL DEFAULT 0,               -- Track usage for sorting/display
    createdAt TEXT NOT NULL,                           -- ISO 8601 timestamp
    updatedAt TEXT NOT NULL                            -- ISO 8601 timestamp
);

CREATE UNIQUE INDEX idx_text_snippets_trigger ON text_snippets(trigger COLLATE NOCASE);
```

**Notes:**
- Case-insensitive unique index on trigger prevents conflicts.
- `use_count` enables "most used" sorting in the management UI.

---

### `chat_conversations` (v0.5)

Stores multi-conversation chat history per transcription. Migrated from the `chatMessages` JSON field on `transcriptions` (v0.4) to a proper table for multi-conversation support. Each transcription can have multiple conversations.

```sql
CREATE TABLE chat_conversations (
    id TEXT PRIMARY KEY,                              -- UUID string
    transcriptionId TEXT NOT NULL                      -- FK to transcriptions
        REFERENCES transcriptions(id) ON DELETE CASCADE,
    title TEXT NOT NULL DEFAULT '',                    -- Derived from first user message (auto-titled)
    messages TEXT,                                     -- JSON: [{"role":"user","content":"..."},{"role":"assistant","content":"..."}]
    createdAt TEXT NOT NULL,                           -- ISO 8601 timestamp
    updatedAt TEXT NOT NULL                            -- ISO 8601 timestamp
);

CREATE INDEX idx_chat_conversations_transcription_id ON chat_conversations(transcriptionId);
```

**Notes:**
- `transcriptionId` has a cascading delete — deleting a transcription removes all its conversations.
- `messages` is a JSON array of `ChatMessage` objects, decoded via GRDB's `Codable` pattern.
- `title` is auto-derived from the first user message (up to 50 chars) during creation or migration.
- Legacy `chatMessages` field on `transcriptions` is nulled out after migration but kept for backward compatibility.

---

### `prompts` (v0.5)

Reusable prompt templates for LLM-powered transcript processing. Community prompts are seeded during migration; custom prompts support full CRUD. Community prompts can be hidden but not edited or deleted.

```sql
CREATE TABLE prompts (
    id        TEXT PRIMARY KEY,                          -- UUID string
    name      TEXT NOT NULL,                              -- Display name ("General Summary", "Action Items")
    content   TEXT NOT NULL,                              -- The actual instruction text
    category  TEXT NOT NULL DEFAULT 'summary',            -- .summary (extensible to .transform)
    isBuiltIn INTEGER NOT NULL DEFAULT 0,                 -- Community prompt — hide only, no edit/delete
    isVisible INTEGER NOT NULL DEFAULT 1,                 -- false = hidden from picker
    isAutoRun INTEGER NOT NULL DEFAULT 0,                 -- true = auto-generate for new transcriptions
    sortOrder INTEGER NOT NULL DEFAULT 0,                 -- Display ordering
    createdAt TEXT NOT NULL,                              -- ISO 8601 timestamp
    updatedAt TEXT NOT NULL                               -- ISO 8601 timestamp
);

CREATE UNIQUE INDEX idx_prompts_name ON prompts(name COLLATE NOCASE);
```

**Notes:**
- `name` has a case-insensitive unique index — no duplicate names across community and custom prompts.
- `isBuiltIn` prompts are seeded from `Prompt.builtInPrompts()` during migration. The repository layer enforces the hide-only invariant (delete returns `false` for built-in prompts).
- `isAutoRun` is independent of `isVisible`, but repository/UI behavior forces auto-run prompts visible while auto-run is enabled.
- `category` scopes prompts to their use case (`.summary` today, `.transform` reserved for future).

---

### `summaries` (v0.5)

Stores generated summaries per transcription. Each transcript can have multiple summaries from different prompts. Summaries snapshot the prompt content used at generation time for reproducibility.

```sql
CREATE TABLE summaries (
    id                TEXT PRIMARY KEY,                    -- UUID string
    transcriptionId   TEXT NOT NULL                        -- FK to transcriptions
        REFERENCES transcriptions(id) ON DELETE CASCADE,
    promptName        TEXT NOT NULL,                       -- Snapshot: prompt name at generation time
    promptContent     TEXT NOT NULL,                       -- Snapshot: full prompt text used
    extraInstructions TEXT,                                -- User's per-run extra instructions (if any)
    content           TEXT NOT NULL,                       -- The generated summary text
    createdAt         TEXT NOT NULL,                       -- ISO 8601 timestamp
    updatedAt         TEXT NOT NULL                        -- ISO 8601 timestamp
);

CREATE INDEX idx_summaries_transcription_id ON summaries(transcriptionId);
```

**Notes:**
- `transcriptionId` has a cascading delete — deleting a transcription removes all its summaries.
- `promptName` and `promptContent` are snapshots, not references to the `prompts` table. Editing or deleting a prompt after generation doesn't change the summary's metadata.
- Legacy `transcriptions.summary` column is preserved and mirrors the newest completed summary for backward compatibility with existing export paths.
- Migration from existing data: `transcriptions.summary` values migrate into `summaries` with `General Summary` prompt metadata.

---

### `lifetime_dictation_stats` (v0.7.4)

Single-row counter table. Headline voice stats (total words, total duration, total count, longest dictation) survive deletion of the underlying `dictations` rows. Fixes [#124](https://github.com/moona3k/macparakeet/issues/124) — clearing dictation history used to wipe stats too because they were SQL aggregates.

```sql
CREATE TABLE lifetime_dictation_stats (
    id                INTEGER PRIMARY KEY CHECK (id = 1),    -- singleton row
    totalCount        INTEGER NOT NULL DEFAULT 0,
    totalDurationMs   INTEGER NOT NULL DEFAULT 0,
    totalWords        INTEGER NOT NULL DEFAULT 0,
    longestDurationMs INTEGER NOT NULL DEFAULT 0,            -- high-water mark
    updatedAt         TEXT NOT NULL
);
```

**Notes:**
- Singleton enforced by `CHECK (id = 1)`. Migration immediately seeds the row from existing `dictations` so subsequent updates are guaranteed plain `UPDATE`s.
- Hot-path increments live in `DictationRepository.save()` inside the same write transaction as the row insert. Status transition guard ensures only `→ .completed` increments fire.
- `applyLifetimeDelta` handles the `(.completed, .completed)` re-save case (e.g. a future "edit transcript" feature) without double-counting.
- `recomputeLifetimeStats(db:)` (recovery / migration helper) uses `INSERT OR REPLACE` so it self-heals if the singleton row is missing. Increment helpers `UPDATE … WHERE id=1` and throw `LifetimeStatsError.singletonMissing` if `db.changesCount != 1`.
- Hidden (private) dictations contribute to lifetime totals — privacy is "no transcript stored," not "no metric counted."
- Weekly streak / "this week" intentionally remain derived from current rows, not lifetime.

---

## Swift Models

All models use GRDB's `Codable` pattern with `FetchableRecord` + `PersistableRecord`.

### Dictation

```swift
import Foundation
import GRDB

struct Dictation: Codable, Identifiable {
    var id: UUID
    var createdAt: Date
    var durationMs: Int
    var rawTranscript: String
    var cleanTranscript: String?
    var audioPath: String?
    var pastedToApp: String?
    var processingMode: ProcessingMode
    var status: DictationStatus
    var hidden: Bool                        // v0.5 — Private dictation mode (excluded from history)
    var wordCount: Int                      // v0.5 — Cached word count for voice stats dashboard
    var errorMessage: String?
    var updatedAt: Date

    enum ProcessingMode: String, Codable {
        case raw
        case clean
    }

    enum DictationStatus: String, Codable {
        case recording
        case processing
        case completed
        case error
    }
}

extension Dictation: FetchableRecord, PersistableRecord {
    static let databaseTableName = "dictations"

    enum Columns: String, ColumnExpression {
        case id, createdAt, durationMs, rawTranscript, cleanTranscript
        case audioPath, pastedToApp, processingMode, status, errorMessage
        case hidden, wordCount, updatedAt
    }
}
```

### Transcription

```swift
import Foundation
import GRDB

struct Transcription: Codable, Identifiable {
    var id: UUID
    var createdAt: Date
    var fileName: String
    var filePath: String?
    var fileSizeBytes: Int?
    var durationMs: Int?
    var rawTranscript: String?
    var cleanTranscript: String?
    var wordTimestamps: [WordTimestamp]?
    var language: String?
    var speakerCount: Int?
    var speakers: [SpeakerInfo]?
    var diarizationSegments: [DiarizationSegmentRecord]?
    var summary: String?                    // v0.4 — LLM-generated transcript summary
    var chatMessages: [ChatMessage]?        // v0.4 — Legacy (migrated to chat_conversations in v0.5)
    var status: TranscriptionStatus
    var errorMessage: String?
    var exportPath: String?
    var sourceURL: String?              // YouTube/web URL (v0.3, nullable)
    var sourceType: SourceType          // v0.6 — file | youtube | meeting
    var thumbnailURL: String?           // v0.5 — YouTube video thumbnail URL
    var channelName: String?            // v0.5 — YouTube channel name
    var videoDescription: String?       // v0.5 — YouTube video description
    var isFavorite: Bool                // v0.5 — User favorite marker
    var updatedAt: Date

    struct WordTimestamp: Codable {
        var word: String
        var startMs: Int
        var endMs: Int
        var confidence: Double
        var speakerId: String?    // v0.4 diarization — stable ID e.g. "S1" (nullable for pre-diarization transcriptions)
    }

    struct SpeakerInfo: Codable, Sendable {
        var id: String            // Stable ID from diarization: "S1", "S2"
        var label: String         // Display label: "Speaker 1" or user-assigned name e.g. "Sarah"
    }

    struct DiarizationSegmentRecord: Codable, Sendable {
        var speakerId: String     // "S1", "S2"
        var startMs: Int
        var endMs: Int
    }

    enum TranscriptionStatus: String, Codable {
        case processing
        case completed
        case error
        case cancelled
    }

    enum SourceType: String, Codable {
        case file
        case youtube
        case meeting
    }
}

extension Transcription: FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcriptions"
}
```

### CustomWord

```swift
import Foundation
import GRDB

struct CustomWord: Codable, Identifiable {
    var id: UUID
    var word: String
    var replacement: String?
    var source: Source
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    enum Source: String, Codable {
        case manual
        case learned
    }
}

extension CustomWord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "custom_words"
}
```

### TextSnippet

```swift
import Foundation
import GRDB

struct TextSnippet: Codable, Identifiable {
    var id: UUID
    var trigger: String
    var expansion: String
    var isEnabled: Bool
    var useCount: Int
    var createdAt: Date
    var updatedAt: Date
}

extension TextSnippet: FetchableRecord, PersistableRecord {
    static let databaseTableName = "text_snippets"
}
```

### ChatConversation

```swift
import Foundation
import GRDB

struct ChatConversation: Codable, Identifiable {
    var id: UUID
    var transcriptionId: UUID
    var title: String
    var messages: [ChatMessage]?
    var createdAt: Date
    var updatedAt: Date
}

extension ChatConversation: FetchableRecord, PersistableRecord {
    static let databaseTableName = "chat_conversations"
}
```

### Prompt

```swift
import Foundation
import GRDB

struct Prompt: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var content: String
    var category: Category
    var isBuiltIn: Bool
    var isVisible: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    enum Category: String, Codable, Sendable {
        case summary
        case transform
    }
}

extension Prompt: FetchableRecord, PersistableRecord {
    static let databaseTableName = "prompts"
}
```

### Summary

```swift
import Foundation
import GRDB

struct Summary: Codable, Identifiable, Sendable {
    var id: UUID
    var transcriptionId: UUID
    var promptName: String
    var promptContent: String
    var extraInstructions: String?
    var content: String
    var createdAt: Date
    var updatedAt: Date
}

extension Summary: FetchableRecord, PersistableRecord {
    static let databaseTableName = "summaries"
}
```

---

## Migration Strategy

Migrations are inline in `DatabaseManager.swift`, using GRDB's `DatabaseMigrator`. Each migration is a named, ordered closure that runs once.

```swift
var migrator = DatabaseMigrator()

// v0.1 — Core tables
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
    try db.create(index: "idx_dictations_created_at",
                  on: "dictations", columns: ["createdAt"])

    // FTS5 for dictation search
    try db.execute(sql: """
        CREATE VIRTUAL TABLE dictations_fts USING fts5(
            rawTranscript, cleanTranscript,
            content='dictations', content_rowid='rowid'
        )
    """)
}

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
    try db.create(index: "idx_transcriptions_created_at",
                  on: "transcriptions", columns: ["createdAt"])
}

// v0.2 — Text processing tables
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

// v0.3 — YouTube URL transcription
migrator.registerMigration("v0.3-transcription-source-url") { db in
    try db.alter(table: "transcriptions") { t in
        t.add(column: "sourceURL", .text)
    }
}

// v0.4 — Speaker diarization segments
migrator.registerMigration("v0.4-transcription-diarization-segments") { db in
    try db.alter(table: "transcriptions") { t in
        t.add(column: "diarizationSegments", .text)  // JSON: [{"speakerId":"S1","startMs":0,"endMs":5000}]
    }
}

// v0.4 — LLM content columns (summary + chat persistence)
migrator.registerMigration("v0.4-transcription-llm-content") { db in
    try db.alter(table: "transcriptions") { t in
        t.add(column: "summary", .text)
        t.add(column: "chatMessages", .text)
    }
}

// v0.5 — Private dictation mode + word count for voice stats
migrator.registerMigration("v0.5-private-dictation") { db in
    try db.alter(table: "dictations") { t in
        t.add(column: "hidden", .boolean).notNull().defaults(to: false)
        t.add(column: "wordCount", .integer).notNull().defaults(to: 0)
    }
    // Backfill wordCount for existing completed rows
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
    // Migrates existing chatMessages from transcriptions into chat_conversations
    // then nulls out the old column
}

// v0.5 — Remove unused FTS5 infrastructure (never queried, search uses LIKE)
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

    try db.execute(sql: """
        UPDATE transcriptions
        SET sourceType = 'youtube'
        WHERE sourceURL IS NOT NULL
    """)
}
```

### Migration Rules

1. **Never delete a migration.** Once shipped, a migration is permanent.
2. **Never modify an existing migration.** Add a new migration instead.
3. **Name migrations with version prefix** (e.g., `v0.1-dictations`).
4. **One table per migration** for clarity and debuggability.
5. **Test migrations** with in-memory SQLite in unit tests.

---

## Version Annotations

| Table / Column | Introduced | Notes |
|-------|-----------|-------|
| `dictations` | v0.1 | Core dictation history |
| ~~`dictations_fts`~~ | ~~v0.1~~ | ~~Full-text search for dictations~~ (dropped in v0.5 — never queried) |
| `transcriptions` | v0.1 | File transcription records |
| `custom_words` | v0.2 | Vocabulary anchors and corrections |
| `text_snippets` | v0.2 | Trigger-based text expansion |
| `transcriptions.diarizationSegments` | v0.4 | Speaker diarization segments (JSON) |
| `transcriptions.summary` | v0.4 | LLM-generated transcript summary |
| `transcriptions.chatMessages` | v0.4 | Legacy — migrated to `chat_conversations` in v0.5 |
| `dictations.hidden` | v0.5 | Private dictation mode flag |
| `dictations.wordCount` | v0.5 | Cached word count for voice stats |
| `chat_conversations` | v0.5 | Multi-conversation chat per transcription (FK → transcriptions) |
| `transcriptions.thumbnailURL` | v0.5 | YouTube video thumbnail URL |
| `transcriptions.channelName` | v0.5 | YouTube channel name |
| `transcriptions.videoDescription` | v0.5 | YouTube video description |
| `transcriptions.isFavorite` | v0.5 | User favorite marker |
| `transcriptions.sourceType` | v0.6 | Origin of transcription: `file`, `youtube`, or `meeting` |
| `text_snippets.action` | v0.5 | Keystroke action type for snippet |
| `prompts` | v0.5 | Reusable prompt templates (community + custom) |
| `summaries` | v0.5 | Multi-summary per transcription (FK → transcriptions, cascade delete) |

### Tables NOT Planned (YAGNI)

These might be needed someday but are explicitly deferred:

- **`settings`** -- Use `UserDefaults` / plist. No need for a settings table.
- **`exports`** -- Track via `exportPath` on `transcriptions`. No separate table.
- **`speakers`** -- Speaker labels and per-word speaker IDs live as JSON on `transcriptions` (v0.4 diarization). No separate table needed — speaker identity is per-transcription, not cross-file. Revisit only if cross-file speaker recognition is added.
- **`usage_stats`** -- Derive from existing tables via queries. No separate tracking table.

---

## Data Lifecycle

### Dictation Audio Retention

```
User dictates
    │
    ▼
Audio saved to temp dir
    │
    ▼
STT processes audio
    │
    ├── Storage = ON  ──► Move to ~/Library/Application Support/MacParakeet/dictations/{id}.wav
    │                     Set audioPath on dictation record
    │
    └── Storage = OFF ──► Delete temp file immediately
                          audioPath stays null
```

### Transcription Files

Transcription source files are **never moved or copied**. We store the original path for reference but don't manage the file. The transcript text and word timestamps are the durable artifacts.

---

## Querying Patterns

### Search Dictations (LIKE)

```swift
// Search dictation history (FTS5 was dropped in v0.5; search uses LIKE)
let dictations = try dbQueue.read { db in
    try Dictation
        .filter(
            Dictation.Columns.rawTranscript.like("%\(query)%")
            || Dictation.Columns.cleanTranscript.like("%\(query)%")
        )
        .order(Column("createdAt").desc)
        .fetchAll(db)
}
```

### Recent Dictations

```swift
// Last 50 dictations, most recent first
let recent = try dbQueue.read { db in
    try Dictation
        .order(Column("createdAt").desc)
        .limit(50)
        .fetchAll(db)
}
```

### Transcription by Status

```swift
// All in-progress transcriptions
let processing = try dbQueue.read { db in
    try Transcription
        .filter(Column("status") == "processing")
        .order(Column("createdAt").desc)
        .fetchAll(db)
}
```

---

*Last updated: 2026-04-04*
