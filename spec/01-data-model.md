# MacParakeet Data Model

> Status: **ACTIVE**

## Overview

MacParakeet uses **SQLite via GRDB** for all persistent storage. Single database file, no cloud sync, no accounts. Data lives at `~/Library/Application Support/MacParakeet/macparakeet.db`.

**Design Principle (YAGNI):** Only add tables when a version needs them. Don't create empty tables for future features.

## Relationship Diagram

```
┌──────────────────┐
│    dictations    │   v0.1 — Voice dictation history
└──────────────────┘

┌──────────────────┐
│  transcriptions  │   v0.1 — File transcription records
└──────────────────┘

┌──────────────────┐
│   custom_words   │   v0.2 — Vocabulary corrections
└──────────────────┘

┌──────────────────┐
│  text_snippets   │   v0.2 — Trigger → expansion shortcuts
└──────────────────┘
```

No foreign keys between tables. Each table is a self-contained domain. This keeps the schema simple and allows tables to be added independently per version.

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
    updatedAt TEXT NOT NULL                           -- ISO 8601 timestamp
);

CREATE INDEX idx_dictations_created_at ON dictations(createdAt DESC);

-- Full-text search across both transcript variants
CREATE VIRTUAL TABLE dictations_fts USING fts5(
    rawTranscript,
    cleanTranscript,
    content='dictations',
    content_rowid='rowid'
);
```

**Notes:**
- `audioPath` is nullable because audio retention is configurable (Settings > Storage).
- `pastedToApp` captures the frontmost app's bundle ID at paste time (e.g., `com.apple.TextEdit`). Useful for history context.
- `processingMode` records which mode was active when the dictation was captured.
- FTS5 content-sync table enables fast search across dictation history.

**FTS5 Sync Triggers:**

```sql
-- Keep FTS in sync with dictations table
CREATE TRIGGER dictations_ai AFTER INSERT ON dictations BEGIN
    INSERT INTO dictations_fts(rowid, rawTranscript, cleanTranscript)
    VALUES (new.rowid, new.rawTranscript, new.cleanTranscript);
END;

CREATE TRIGGER dictations_ad AFTER DELETE ON dictations BEGIN
    INSERT INTO dictations_fts(dictations_fts, rowid, rawTranscript, cleanTranscript)
    VALUES ('delete', old.rowid, old.rawTranscript, old.cleanTranscript);
END;

CREATE TRIGGER dictations_au AFTER UPDATE ON dictations BEGIN
    INSERT INTO dictations_fts(dictations_fts, rowid, rawTranscript, cleanTranscript)
    VALUES ('delete', old.rowid, old.rawTranscript, old.cleanTranscript);
    INSERT INTO dictations_fts(rowid, rawTranscript, cleanTranscript)
    VALUES (new.rowid, new.rawTranscript, new.cleanTranscript);
END;
```

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
    wordTimestamps TEXT,                                -- JSON: [{"word":"Hello","startMs":0,"endMs":500,"confidence":0.98}]
    language TEXT DEFAULT 'en',                         -- Detected or specified language code
    speakerCount INTEGER,                              -- Number of detected speakers (v0.4 diarization)
    speakers TEXT,                                      -- JSON: ["Speaker 1","Speaker 2"] (v0.4 diarization)
    status TEXT NOT NULL DEFAULT 'processing',          -- 'processing', 'completed', 'error', 'cancelled'
    errorMessage TEXT,                                  -- Error details if status='error'
    exportPath TEXT,                                    -- Path to last export (nullable)
    updatedAt TEXT NOT NULL                             -- ISO 8601 timestamp
);

CREATE INDEX idx_transcriptions_created_at ON transcriptions(createdAt DESC);
```

**Notes:**
- `wordTimestamps` is a JSON text column, not a separate table. One transcription = one blob of timestamps. GRDB can decode this via `Codable`.
- `speakerCount` and `speakers` are nullable, populated only when diarization is available (v0.4).
- `filePath` is nullable because the original file may be moved or deleted after transcription.
- No FTS on transcriptions in v0.1. Search by filename or scroll the list. Revisit if the list grows large.

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
        case audioPath, pastedToApp, processingMode, status, errorMessage, updatedAt
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
    var speakers: [String]?
    var status: TranscriptionStatus
    var errorMessage: String?
    var exportPath: String?
    var updatedAt: Date

    struct WordTimestamp: Codable {
        var word: String
        var startMs: Int
        var endMs: Int
        var confidence: Double
    }

    enum TranscriptionStatus: String, Codable {
        case processing
        case completed
        case error
        case cancelled
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
```

### Migration Rules

1. **Never delete a migration.** Once shipped, a migration is permanent.
2. **Never modify an existing migration.** Add a new migration instead.
3. **Name migrations with version prefix** (e.g., `v0.1-dictations`).
4. **One table per migration** for clarity and debuggability.
5. **Test migrations** with in-memory SQLite in unit tests.

---

## Version Annotations

| Table | Introduced | Notes |
|-------|-----------|-------|
| `dictations` | v0.1 | Core dictation history |
| `dictations_fts` | v0.1 | Full-text search for dictations |
| `transcriptions` | v0.1 | File transcription records |
| `custom_words` | v0.2 | Vocabulary anchors and corrections |
| `text_snippets` | v0.2 | Trigger-based text expansion |

### Tables NOT Planned (YAGNI)

These might be needed someday but are explicitly deferred:

- **`settings`** -- Use `UserDefaults` / plist. No need for a settings table.
- **`exports`** -- Track via `exportPath` on `transcriptions`. No separate table.
- **`speakers`** -- Speaker labels live as JSON on `transcriptions`. Normalize only if diarization becomes a first-class feature.
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
    ├── Storage = "keep all"  ──► Move to ~/Library/Application Support/MacParakeet/dictations/{id}.wav
    │                             Set audioPath on dictation record
    │
    ├── Storage = "keep 7 days" ─► Same, but background job prunes after 7 days
    │
    └── Storage = "never keep" ──► Delete temp file immediately
                                   audioPath stays null
```

### Transcription Files

Transcription source files are **never moved or copied**. We store the original path for reference but don't manage the file. The transcript text and word timestamps are the durable artifacts.

---

## Querying Patterns

### Search Dictations (FTS5)

```swift
// Search dictation history
let dictations = try dbQueue.read { db in
    let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
    return try Dictation
        .joining(required: Dictation.hasOne(
            FTS5TokenizedColumn.self,
            using: ForeignKey(["rowid"])
        ))
        .filter(sql: "dictations_fts MATCH ?", arguments: [pattern])
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

*Last updated: 2026-02-08*
