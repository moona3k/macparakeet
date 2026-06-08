# MacParakeet Data Model

> Status: **ACTIVE**

## Overview

MacParakeet uses **SQLite via GRDB** for all persistent storage. Single database file, no cloud sync, no accounts. Data lives at `~/Library/Application Support/MacParakeet/macparakeet.db`.

**Design Principle (YAGNI):** Only add tables when a version needs them. Don't create empty tables for future features.

## Relationship Diagram

```
┌──────────────────┐       ┌──────────────────────────────┐
│    dictations    │ ╌╌╌▶  │ lifetime_dictation_stats     │  v0.7.4 — Singleton counter
└──────────────────┘       └──────────────────────────────┘    (survives row deletion)
   v0.1 — Voice dictation history    (logical write-path, no FK)

┌──────────────────┐       ┌─────────────────────────┐
│  transcriptions  │◄──FK──│   chat_conversations    │  v0.5 — Multi-conversation chat
│                  │◄──FK──│      summaries          │  v0.7 — Prompt results per transcript
└──────────────────┘       └─────────────────────────┘
   v0.1 — File transcription records

┌──────────────────┐
│   custom_words   │   v0.2 — Vocabulary corrections
└──────────────────┘

┌──────────────────┐
│  text_snippets   │   v0.2 — Trigger → expansion shortcuts
└──────────────────┘

┌──────────────────┐
│     prompts      │   v0.7 — Reusable prompt templates
└──────────────────┘

┌──────────────────┐
│  quick_prompts   │   v0.10 migration — v0.6 Live Ask shortcut pills
└──────────────────┘

┌──────────────────┐
│     llm_runs     │   v0.18 — Local LLM run metadata ledger
└──────────────────┘   FK -> dictations / transcriptions / summaries /
                       chat_conversations / transform_history

┌───────────────────────┐
│ ai_formatter_profiles │   v0.21 — Local app/category formatter prompts
└───────────────────────┘
```

Tables are self-contained domains with three exceptions: `chat_conversations` and `summaries` have foreign keys to `transcriptions` with cascading delete, and `llm_runs` has nullable foreign-key columns back to the feature-owned source rows that triggered each LLM call. At least one `llm_runs` source link is required. The Swift model for `summaries` is `PromptResult`; the table name is retained for migration compatibility.

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
    updatedAt TEXT NOT NULL,                          -- ISO 8601 timestamp
    hidden INTEGER NOT NULL DEFAULT 0,                -- v0.5: Private dictation mode (excluded from history)
    wordCount INTEGER NOT NULL DEFAULT 0,             -- v0.5: Cached word count for voice stats
    engine TEXT,                                      -- v0.8: STT engine (`parakeet` / `nemotron` / `whisper`)
    engineVariant TEXT,                               -- v0.8: Engine-specific model variant
    language TEXT,                                    -- v0.19: Normalized detected STT language code
    displayRawTranscript INTEGER NOT NULL DEFAULT 0,  -- v0.12: Show raw transcript instead of cleaned text
    aiFormatterProfileID TEXT,                        -- v0.21: Local formatter profile UUID used
    aiFormatterProfileName TEXT,                      -- v0.21: Local formatter profile display name snapshot
    aiFormatterProfileMatchKind TEXT                  -- v0.21: exact_app / category / global
);

CREATE INDEX idx_dictations_created_at ON dictations(createdAt);

-- Note: FTS5 virtual table + sync triggers were created in v0.1 but dropped in v0.5
-- (never queried — search uses LIKE). Kept in migration history but not in active schema.
```

**Notes:**
- `audioPath` is nullable because audio retention is configurable (Settings > Storage).
- `pastedToApp` captures the frontmost app's bundle ID at paste time (e.g., `com.apple.TextEdit`). Useful for history context.
- Hidden/no-history dictation rows are metric-only: `rawTranscript` is empty, transcript/audio/app/profile provenance fields are `NULL`, while duration and word-count stats remain.
- `processingMode` records which mode was active when the dictation was captured.
- `engine` / `engineVariant` record the STT engine attribution for rows created after the v0.8 migration. Legacy rows keep `NULL` rather than being silently relabeled.
- `language` records the normalized detected STT language code for rows created after the v0.19 migration. Unknown, auto-detect, or non-catalog values remain `NULL`.
- `displayRawTranscript` lets history/export/menu surfaces show the raw STT text while preserving the cleaned text for reversible "Undo AI edit" behavior.
- `aiFormatterProfileID`, `aiFormatterProfileName`, and `aiFormatterProfileMatchKind` are local-only AI Formatter routing provenance. Global formatter runs store `aiFormatterProfileMatchKind = 'global'` with no profile id/name; `NULL` means the row predates the v0.21 metadata or AI Formatter did not run.
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
    recoveredFromCrash INTEGER NOT NULL DEFAULT 0,       -- v0.7.5: recovered interrupted meeting flag
    isTranscriptEdited INTEGER NOT NULL DEFAULT 0,       -- v0.7.7: user-edited transcript flag
    userNotes TEXT,                                      -- v0.8: meeting notes used to steer prompt results
    engine TEXT,                                         -- v0.8: STT engine (`parakeet` / `nemotron` / `whisper`)
    engineVariant TEXT,                                  -- v0.8: Engine-specific model variant
    derivedTitle TEXT,                                   -- v0.9: Display title derived from transcript content
    derivedSnippet TEXT,                                 -- v0.9: Display preview snippet derived from transcript content
    updatedAt TEXT NOT NULL                              -- ISO 8601 timestamp
);

CREATE INDEX idx_transcriptions_created_at ON transcriptions(createdAt);
CREATE INDEX idx_transcriptions_source_type_created_at ON transcriptions(sourceType, createdAt);
CREATE INDEX idx_transcriptions_favorite_created_at ON transcriptions(isFavorite, createdAt);
CREATE INDEX idx_transcriptions_status_created_at ON transcriptions(status, createdAt);
```

**Notes:**
- `wordTimestamps` is a JSON text column, not a separate table. One transcription = one blob of timestamps. GRDB can decode this via `Codable`.
- `language` stores the normalized detected/specified STT language code when available. New transcription service rows start unknown and are filled from the STT result; legacy/default rows may still contain `en`.
- `speakerCount` and `speakers` are nullable, populated only when diarization is available (v0.4).
- `filePath` is nullable because the original file may be moved or deleted after transcription.
- For meeting recordings, `filePath` points to the mixed `meeting.m4a` artifact used for playback/export, while the per-source `microphone.m4a`, `system.m4a`, and `meeting-recording-metadata.json` sidecar remain inside the same session folder. When the user typed notes during the meeting, a `notes.md` companion file is written into that folder at finalize/recovery time so the notes are inspectable in Finder / any editor without launching the app. The DB column `transcriptions.userNotes` is canonical; `notes.md` is a snapshot at finalize and is not synced with later edits via `macparakeet-cli meetings notes`.
- Saved meeting retranscribes reconstruct the archived meeting from that folder when the sidecar exists, so the library path can reuse the same aligned dual-source finalization flow as the immediate post-stop path.
- `sourceURL` distinguishes URL-sourced transcriptions (YouTube) from local file transcriptions. Added in v0.3.
- `thumbnailURL`, `channelName`, `videoDescription` store YouTube metadata fetched during download. Local file imports also reuse `channelName` / `videoDescription` for embedded author / description metadata when present. Added in v0.5.
- `isFavorite` enables user-marked favorites with filtered library view. Added in v0.5.
- `sourceType` distinguishes the origin of a transcription: `'file'` (drag-drop), `'youtube'` (URL), or `'meeting'` (meeting recording). Added in v0.6. Default `'file'` for backward compatibility. Existing rows with `sourceURL IS NOT NULL` are backfilled to `'youtube'`.
- `recoveredFromCrash` marks meeting recordings recovered from an interrupted session. Added in v0.7.5.
- `isTranscriptEdited` marks transcript text changed by the user after automatic processing. Added in v0.7.7.
- `userNotes` stores free-form meeting notes typed during recording; prompt generation snapshots this value on `summaries.userNotesSnapshot`. Added in v0.8.
- `engine` / `engineVariant` record the STT engine attribution for Parakeet, Nemotron Beta, and optional WhisperKit paths. Added in v0.8; legacy rows keep `NULL`.
- `derivedTitle` / `derivedSnippet` cache display copy derived from the completed transcript. Added in v0.9 so Library cards do not need to recompute preview text on every render.
- The legacy `summary` column was migrated into `summaries` in v0.7 and dropped in v0.7.6.
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
    action TEXT,                                       -- v0.7: optional post-paste action (Voice Return)
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
- `action` stores optional post-paste actions for terminal action snippets. These rows are extracted before text snippet expansion; `expansion` remains non-null for schema compatibility.

---

### `chat_conversations` (v0.5)

Stores multi-conversation chat history per transcription. Migrated from the `chatMessages` JSON field on `transcriptions` (v0.4) to a proper table for multi-conversation support. Each transcription can have multiple conversations.

```sql
CREATE TABLE chat_conversations (
    id TEXT PRIMARY KEY,                              -- UUID string
    transcriptionId TEXT NOT NULL                      -- FK to transcriptions
        REFERENCES transcriptions(id) ON DELETE CASCADE,
    title TEXT NOT NULL DEFAULT '',                    -- Derived from first user message (auto-titled)
    messages TEXT,                                     -- JSON: [{"role":"user","content":"...","modelPromptOverride":"..."},{"role":"assistant","content":"..."}]
    createdAt TEXT NOT NULL,                           -- ISO 8601 timestamp
    updatedAt TEXT NOT NULL                            -- ISO 8601 timestamp
);

CREATE INDEX idx_chat_conversations_transcription_id ON chat_conversations(transcriptionId);
```

**Notes:**
- `transcriptionId` has a cascading delete — deleting a transcription removes all its conversations.
- `messages` is a JSON array of `ChatMessage` objects, decoded via GRDB's `Codable` pattern.
- `messages[].modelPromptOverride` is optional and only present for rich-prompt user turns; `content` remains the visible chat label, while regenerate/model-history assembly use `modelPromptOverride`.
- `title` is auto-derived from the first user message (up to 50 chars) during creation or migration.
- Legacy `chatMessages` field on `transcriptions` is nulled out after migration but kept for backward compatibility.

---

### `prompts` (v0.7)

Reusable prompt templates for LLM-powered transcript processing. Community prompts are seeded during migration; custom prompts support full CRUD. Community prompts can be hidden but not edited or deleted.

```sql
CREATE TABLE prompts (
    id        TEXT PRIMARY KEY,                          -- UUID string
    name      TEXT NOT NULL,                              -- Display name ("Summary", "Action Items & Decisions")
    content   TEXT NOT NULL,                              -- The actual instruction text
    category  TEXT NOT NULL DEFAULT 'summary',            -- .summary (extensible to .transform)
    isBuiltIn INTEGER NOT NULL DEFAULT 0,                 -- Community prompt — hide only, no edit/delete
    isVisible INTEGER NOT NULL DEFAULT 1,                 -- false = hidden from picker
    isAutoRun INTEGER NOT NULL DEFAULT 0,                 -- true = auto-generate for new transcriptions
    sortOrder INTEGER NOT NULL DEFAULT 0,                 -- Display ordering
    createdAt TEXT NOT NULL,                              -- ISO 8601 timestamp
    updatedAt TEXT NOT NULL,                              -- ISO 8601 timestamp
    keyboardShortcut TEXT,                                -- v0.13 Transform shortcut (encoded KeyboardShortcut)
    runningLabel TEXT,                                    -- v0.13 Transform progress label override
    appliesToSources TEXT                                 -- v0.20 JSON Set<SourceType> for auto-run scoping; NULL = all sources
);

CREATE UNIQUE INDEX idx_prompts_name ON prompts(name COLLATE NOCASE);
```

**Notes:**
- `name` has a case-insensitive unique index — no duplicate names across community and custom prompts.
- `isBuiltIn` prompts are seeded from `Prompt.builtInPrompts()` during migration. The repository layer enforces the hide-only invariant (delete returns `false` for built-in prompts).
- `isAutoRun` is independent of `isVisible`, but repository/UI behavior forces auto-run prompts visible while auto-run is enabled.
- `category` currently stores the raw value `"summary"` for compatibility, while the Swift enum case is `Prompt.Category.result`.
- Built-ins currently come from `Prompt.builtInPrompts()` in Swift. "Summary" is the lone auto-run built-in for users who have not disabled every auto-run prompt. ("Memo-Steered Notes" was a second auto-run built-in introduced in ADR-020 and reverted on 2026-05-02 — see ADR-020 amendment.)
- `category = "transform"` rows use `keyboardShortcut` for global Transform bindings and `runningLabel` for the floating progress label. Summary/result prompts leave both fields `NULL`.
- `appliesToSources` (v0.20) scopes auto-run to specific transcription sources (JSON-encoded `Set<Transcription.SourceType>`). `NULL` means "all sources" — the canonical unscoped form. The Meetings "After each meeting" card sets `[.meeting]`; the global Prompt Library toggle and CLI `--auto-run` reset it to `NULL`. `restoreDefaults()` also clears it. A set covering every source is normalized back to `NULL` so future `SourceType` cases are auto-included. Only consulted when `isAutoRun = true` (see `Prompt.autoRuns(for:)`).

---

### `summaries` (v0.7, Swift model: `PromptResult`)

Stores generated prompt results per transcription. Each transcript can have multiple results from different prompts. Results snapshot the prompt content and meeting notes used at generation time for reproducibility.

```sql
CREATE TABLE summaries (
    id                TEXT PRIMARY KEY,                    -- UUID string
    transcriptionId   TEXT NOT NULL                        -- FK to transcriptions
        REFERENCES transcriptions(id) ON DELETE CASCADE,
    promptName        TEXT NOT NULL,                       -- Snapshot: prompt name at generation time
    promptContent     TEXT NOT NULL,                       -- Snapshot: full prompt text used
    extraInstructions TEXT,                                -- User's per-run extra instructions (if any)
    content           TEXT NOT NULL,                       -- The generated summary text
    userNotesSnapshot TEXT,                                -- v0.8: notes used when generating this result
    createdAt         TEXT NOT NULL,                       -- ISO 8601 timestamp
    updatedAt         TEXT NOT NULL                        -- ISO 8601 timestamp
);

CREATE INDEX idx_summaries_transcription_id ON summaries(transcriptionId);
```

**Notes:**
- `transcriptionId` has a cascading delete — deleting a transcription removes all its prompt results.
- `promptName` and `promptContent` are snapshots, not references to the `prompts` table. Editing or deleting a prompt after generation doesn't change the result's metadata.
- `userNotesSnapshot` captures `Transcription.userNotes` at generation time so later note edits do not rewrite historical prompt results.
- Migration from existing data: legacy `transcriptions.summary` values migrate into `summaries` with classic "Summary" prompt metadata, then the legacy column is dropped by `v0.7.6-drop-legacy-transcription-summary`.

---

### `quick_prompts` (v0.10 migration; v0.6 product feature)

Stores user-customizable live meeting Ask tab shortcut pills. These are separate from `prompts`: prompt library rows generate persistent transcript results, while quick prompts are lightweight chat shortcuts with a visible chip label and a richer LLM instruction body.

```sql
CREATE TABLE quick_prompts (
    id        TEXT PRIMARY KEY,                          -- UUID string
    label     TEXT NOT NULL,                              -- Chip / chat bubble text
    prompt    TEXT NOT NULL,                              -- Full instruction sent to the LLM
    groupLabel TEXT,                                      -- Optional grouping for empty state / sparkle menu
    sortOrder INTEGER NOT NULL DEFAULT 0,                 -- Display ordering within pin bucket
    isVisible INTEGER NOT NULL DEFAULT 1,                 -- false = hidden from Ask UI
    isPinned INTEGER NOT NULL DEFAULT 0,                  -- true = after-response strip candidate
    isBuiltIn INTEGER NOT NULL DEFAULT 0,                 -- Shipped seed row; editable/resettable, not deletable
    createdAt TEXT NOT NULL,                              -- ISO 8601 timestamp
    updatedAt TEXT NOT NULL                               -- ISO 8601 timestamp
);

CREATE INDEX idx_quick_prompts_pinned_sort ON quick_prompts(isPinned, sortOrder);
```

**Notes:**
- Built-ins are seeded from `QuickPrompt.builtInPrompts()` by `QuickPromptRepository.seedIfNeeded()` after migrations complete. The reconciler inserts missing built-ins and retires removed built-ins, but never overwrites an existing user's edited row.
- Built-ins are editable, hideable, reorderable, and resettable. They cannot be deleted. Reset restores canonical label/prompt/group/order and visible-compatible pin state, while preserving visibility.
- Custom rows can be created, edited, reordered, hidden, deleted, exported, and imported.
- `isPinned` controls the after-response strip; the strip is a horizontal `ScrollView` with edge-fade affordance and renders all visible pinned rows by `sortOrder` — pinning is unbounded.
- Hidden rows are never pinned. Repository writes normalize hidden+pinned rows to hidden+unpinned; hiding a pinned row auto-unpins it, and pinning a hidden row auto-shows it.
- The CLI backup/share format is `QuickPromptBundle` with `schema: "macparakeet.quick_prompts"` and `version: 1`; each prompt carries `isPinned: Bool`.

---

### `llm_runs` (v0.18)

Stores local metadata for persisted LLM operations. This table is for later
local analytics, diagnostics, and feature-linked run history; it deliberately
does **not** duplicate transcript text, prompt templates, chat messages,
transform input/output, audio paths, or other user content. Those payloads
remain in their feature-owned tables.

```sql
CREATE TABLE llm_runs (
    id                    TEXT PRIMARY KEY,                 -- UUID string
    operationID           TEXT,                              -- Observability operation id, when available
    feature               TEXT NOT NULL,                     -- formatter_dictation, formatter_transcription, prompt_result, chat, transform
    status                TEXT NOT NULL,                     -- succeeded, failed, cancelled
    dictationId           TEXT REFERENCES dictations(id) ON DELETE CASCADE,
    transcriptionId       TEXT REFERENCES transcriptions(id) ON DELETE CASCADE,
    promptResultId        TEXT REFERENCES summaries(id) ON DELETE CASCADE,
    chatConversationId    TEXT REFERENCES chat_conversations(id) ON DELETE CASCADE,
    transformHistoryId    TEXT REFERENCES transform_history(id) ON DELETE CASCADE,
    provider              TEXT,                              -- openai, anthropic, ollama, lmstudio, local_cli, etc.
    model                 TEXT,                              -- provider-reported model name
    errorType             TEXT,                              -- bucketed error type for failures
    promptTokens          INTEGER,                           -- nullable; provider-dependent
    completionTokens      INTEGER,                           -- nullable; provider-dependent
    totalTokens           INTEGER,                           -- nullable; provider-dependent
    latencyMs             INTEGER,                           -- request duration
    inputChars            INTEGER NOT NULL DEFAULT 0,         -- character count only, never input content
    outputChars           INTEGER,                           -- character count only, never output content
    stopReason            TEXT,                              -- provider finish/stop reason
    inputTruncated        INTEGER NOT NULL DEFAULT 0,         -- true if context was truncated before send
    defaultPromptUsed     INTEGER,                           -- nullable for non-prompted/non-formatter calls
    messageCount          INTEGER,                           -- number of chat messages sent
    createdAt             TEXT NOT NULL,                     -- ISO 8601 timestamp
    updatedAt             TEXT NOT NULL,                     -- ISO 8601 timestamp
    CHECK (
        dictationId IS NOT NULL
        OR transcriptionId IS NOT NULL
        OR promptResultId IS NOT NULL
        OR chatConversationId IS NOT NULL
        OR transformHistoryId IS NOT NULL
    )
);

CREATE INDEX idx_llm_runs_feature_created_at ON llm_runs(feature, createdAt);
CREATE INDEX idx_llm_runs_provider_model_created_at ON llm_runs(provider, model, createdAt);
CREATE INDEX idx_llm_runs_status_created_at ON llm_runs(status, createdAt);
CREATE INDEX idx_llm_runs_dictation_id ON llm_runs(dictationId);
CREATE INDEX idx_llm_runs_transcription_id ON llm_runs(transcriptionId);
CREATE INDEX idx_llm_runs_prompt_result_id ON llm_runs(promptResultId);
CREATE INDEX idx_llm_runs_chat_conversation_id ON llm_runs(chatConversationId);
CREATE INDEX idx_llm_runs_transform_history_id ON llm_runs(transformHistoryId);
```

**Notes:**
- `llm_runs` is metadata-only. Queryable counts, latency, provider/model, token usage, status, and source links belong here; full prompts and outputs do not.
- Source columns are nullable because each run links to one feature-owned source type, but at least one source link is required for every persisted ledger row.
- Formatter writes are the first producer. Prompt result, chat, and transform rows should be added only after their streaming app APIs expose a terminal metadata envelope.
- Private/no-history dictations and transient transcriptions do not create formatter run rows because there is no durable user-visible source row to link.
- Deleting a source row cascades associated run metadata.

---

### `ai_formatter_profiles` (v0.21)

Local profile table for Dictation AI Formatter prompt routing. Profiles match
either an exact macOS bundle identifier or a coarse app category, then provide a
prompt template that follows the same `{{TRANSCRIPT}}` contract as the global
formatter prompt.

```sql
CREATE TABLE ai_formatter_profiles (
    id               TEXT PRIMARY KEY,                    -- UUID string
    name             TEXT NOT NULL,                       -- User-visible profile name
    isEnabled        INTEGER NOT NULL DEFAULT 1,
    targetKind       TEXT NOT NULL,                       -- bundle / category
    bundleIdentifier TEXT,                                -- normalized lowercase bundle id
    appDisplayName   TEXT,                                -- local display name snapshot
    appCategory      TEXT,                                -- TelemetryAppCategory raw value
    promptTemplate   TEXT NOT NULL,
    origin           TEXT NOT NULL DEFAULT 'custom',      -- custom / template
    sortOrder        INTEGER NOT NULL DEFAULT 0,
    createdAt        TEXT NOT NULL,
    updatedAt        TEXT NOT NULL,
    CHECK (targetKind IN ('bundle', 'category')),
    CHECK (origin IN ('custom', 'template')),
    CHECK (
        (
            targetKind = 'bundle'
            AND bundleIdentifier IS NOT NULL
            AND TRIM(bundleIdentifier) != ''
            AND bundleIdentifier = LOWER(TRIM(bundleIdentifier))
            AND appCategory IS NULL
        )
        OR
        (
            targetKind = 'category'
            AND appCategory IS NOT NULL
            AND appCategory IN ('messaging', 'email', 'browser', 'notes', 'docs', 'code', 'terminal', 'other')
            AND bundleIdentifier IS NULL
            AND appDisplayName IS NULL
        )
    )
);

CREATE INDEX idx_ai_formatter_profiles_enabled_sort
    ON ai_formatter_profiles(isEnabled, sortOrder);
CREATE INDEX idx_ai_formatter_profiles_target_kind
    ON ai_formatter_profiles(targetKind);
CREATE UNIQUE INDEX idx_ai_formatter_profiles_bundle_unique
    ON ai_formatter_profiles(LOWER(TRIM(bundleIdentifier)))
    WHERE targetKind = 'bundle' AND bundleIdentifier IS NOT NULL;
CREATE UNIQUE INDEX idx_ai_formatter_profiles_category_unique
    ON ai_formatter_profiles(appCategory)
    WHERE targetKind = 'category' AND appCategory IS NOT NULL;
```

**Notes:**
- Exact app profiles store bundle IDs and display names as local user data only. They are used for prompt resolution and local history/debug provenance, not telemetry.
- Matching precedence is exact bundle, then custom coarse category, then built-in category smart default, then the fallback AI Formatter prompt.
- Duplicate exact-bundle and category targets are rejected by both schema unique indexes and `AIFormatterProfileRepository` so the matching rule stays deterministic and direct/future write paths cannot create ambiguous routing.
- Bundle profile rows require a non-empty lowercased/trimmed bundle ID. Category profile rows require a valid `TelemetryAppCategory` raw value.
- Browser hostname/domain matching is intentionally not represented in this schema. V1 treats browsers as exact browser apps or the coarse `browser` category.

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
- User-initiated reset: `DictationRepository.resetLifetimeStats()` zeros the singleton row without touching dictation rows. Symmetric counterpart to `deleteAll()` (rows deleted, stats preserved). Exposed as a "Reset Lifetime Stats..." button in Settings → Storage.

---

### `daily_dictation_stats` (v0.11)

Per-day rollup keyed by local-calendar day. Powers the Stats sub-tab heatmap and current/longest daily streaks. Survives `Clear History` for the same reason `lifetime_dictation_stats` does — the user can wipe transcripts without losing their multi-month streak visualization.

```sql
CREATE TABLE daily_dictation_stats (
    day        TEXT PRIMARY KEY,                      -- 'YYYY-MM-DD' in user's local calendar
    count      INTEGER NOT NULL DEFAULT 0,
    words      INTEGER NOT NULL DEFAULT 0,
    durationMs INTEGER NOT NULL DEFAULT 0,
    updatedAt  TEXT    NOT NULL
);
```

**Notes:**
- `day` is the **local** calendar day. SQLite's `date()` defaults to UTC, which would split a late-night PT session across two cells; we compute the key in Swift via `Calendar.current` instead.
- Hot-path increment lives in `DictationRepository.save()` inside the same write transaction as `lifetime_dictation_stats`. Uses `INSERT … ON CONFLICT(day) DO UPDATE` (UPSERT) — the row's absence is the expected initial state.
- Edit-transcript path (`(.completed, .completed)` save) calls `applyDailyDelta` against `prior.createdAt`'s day so the delta lands on the day that was originally counted.
- Backfilled on migration from existing completed `dictations` rows. Grouping done in Swift so it matches `Calendar.current` exactly.
- Per-app aggregation lives elsewhere (read directly from `dictations.pastedToApp` for the "Where you dictate" card). Only the heatmap is privileged with rollup-table preservation; top-apps clears with history by design.

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
    var engine: String?                     // v0.8 — STT engine (`parakeet` / `nemotron` / `whisper`)
    var engineVariant: String?              // v0.8 — Engine-specific model variant

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
        case hidden, wordCount, updatedAt, engine, engineVariant
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
    var recoveredFromCrash: Bool        // v0.7.5 — Recovered interrupted meeting
    var isTranscriptEdited: Bool        // v0.7.7 — User edited transcript text
    var userNotes: String?              // v0.8 — Free-form meeting notes
    var engine: String?                 // v0.8 — STT engine (`parakeet` / `nemotron` / `whisper`)
    var engineVariant: String?          // v0.8 — Engine-specific model variant
    var derivedTitle: String?           // v0.9 — Display title derived from transcript text
    var derivedSnippet: String?         // v0.9 — Display preview snippet derived from transcript text
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
    var isAutoRun: Bool
    var sortOrder: Int
    var keyboardShortcut: String?
    var runningLabel: String?
    var appliesToSources: Set<Transcription.SourceType>?  // v0.20 auto-run scoping; nil = all sources
    var createdAt: Date
    var updatedAt: Date

    enum Category: String, Codable, Sendable {
        case result = "summary"
        case transform
    }
}

extension Prompt: FetchableRecord, PersistableRecord {
    static let databaseTableName = "prompts"
}
```

### PromptResult

```swift
import Foundation
import GRDB

struct PromptResult: Codable, Identifiable, Sendable {
    var id: UUID
    var transcriptionId: UUID
    var promptName: String
    var promptContent: String
    var extraInstructions: String?
    var content: String
    var userNotesSnapshot: String?
    var createdAt: Date
    var updatedAt: Date
}

extension PromptResult: FetchableRecord, PersistableRecord {
    static let databaseTableName = "summaries"
}
```

### QuickPrompt

```swift
import Foundation
import GRDB

struct QuickPrompt: Codable, Identifiable, Sendable {
    var id: UUID
    var label: String
    var prompt: String
    var groupLabel: String?
    var sortOrder: Int
    var isVisible: Bool
    var isPinned: Bool
    var isBuiltIn: Bool
    var createdAt: Date
    var updatedAt: Date
}

extension QuickPrompt: FetchableRecord, PersistableRecord {
    static let databaseTableName = "quick_prompts"
}
```

### LLMRun

```swift
import Foundation
import GRDB

struct LLMRun: Codable, Identifiable, Sendable {
    var id: UUID
    var operationID: String?
    var feature: Feature
    var status: Status
    var dictationId: UUID?
    var transcriptionId: UUID?
    var promptResultId: UUID?
    var chatConversationId: UUID?
    var transformHistoryId: UUID?
    var provider: String?
    var model: String?
    var errorType: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var latencyMs: Int?
    var inputChars: Int
    var outputChars: Int?
    var stopReason: String?
    var inputTruncated: Bool
    var defaultPromptUsed: Bool?
    var messageCount: Int?
    var createdAt: Date
    var updatedAt: Date

    enum Feature: String, Codable, Sendable {
        case formatterDictation = "formatter_dictation"
        case formatterTranscription = "formatter_transcription"
        case promptResult = "prompt_result"
        case chat
        case transform
    }

    enum Status: String, Codable, Sendable {
        case succeeded
        case failed
        case cancelled
    }
}

extension LLMRun: FetchableRecord, PersistableRecord {
    static let databaseTableName = "llm_runs"
}
```

### AIFormatterProfile

```swift
import Foundation
import GRDB

public enum AIFormatterProfileTargetKind: String, Codable, Sendable {
    case bundle
    case category
}

public enum AIFormatterProfileMatchKind: String, Codable, Sendable {
    case exactApp = "exact_app"
    case category
    case global
}

public enum AIFormatterProfileOrigin: String, Codable, Sendable {
    case custom
    case template
}

public struct AIFormatterProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var targetKind: AIFormatterProfileTargetKind
    public var bundleIdentifier: String?
    public var appDisplayName: String?
    public var appCategory: TelemetryAppCategory?
    public var promptTemplate: String
    public var origin: AIFormatterProfileOrigin
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
}

extension AIFormatterProfile: FetchableRecord, PersistableRecord {
    static let databaseTableName = "ai_formatter_profiles"
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

// v0.7 — Prompt library + prompt results
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
    try db.create(table: "summaries") { t in
        t.column("id", .text).primaryKey()
        t.column("transcriptionId", .text).notNull().references("transcriptions", onDelete: .cascade)
        t.column("promptName", .text).notNull()
        t.column("promptContent", .text).notNull()
        t.column("extraInstructions", .text)
        t.column("content", .text).notNull()
        t.column("createdAt", .text).notNull()
        t.column("updatedAt", .text).notNull()
    }
    // Existing transcriptions.summary values are copied into summaries here.
}

// Later additive migrations:
// v0.7.4 — lifetime_dictation_stats
// v0.7.5 — transcriptions.recoveredFromCrash
// v0.7.6 — drop legacy transcriptions.summary
// v0.7.7 — transcriptions.isTranscriptEdited
// v0.8 — transcriptions.userNotes and summaries.userNotesSnapshot
// v0.8 — dictations.engine/engineVariant and transcriptions.engine/engineVariant
// v0.9 — transcriptions.derivedTitle and transcriptions.derivedSnippet
// v0.10 — quick_prompts (v0.6 Live Ask product surface)
// v0.10 — transcription library indexes (sourceType/favorite/status + createdAt)
// v0.11 — daily_dictation_stats
// v0.12 — dictations.displayRawTranscript
// v0.13 — prompts.keyboardShortcut and prompts.runningLabel for Transforms
// v0.14 — transform_history (removed by v0.16 before merge)
// v0.15 — transform_profiles and writing_samples (removed by v0.16 before merge)
// v0.16 — drop abandoned Transform Workbench tables
// v0.17 — recreate transform_history (workbench tables stay dropped)
// v0.18 — llm_runs metadata ledger
// v0.19 — dictations.language
// v0.20 — prompts.appliesToSources (auto-run source scoping; NULL = all sources)
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
| ~~`transcriptions.summary`~~ | ~~v0.4~~ | ~~Legacy single summary~~ (migrated to `summaries` in v0.7, dropped in v0.7.6) |
| `transcriptions.chatMessages` | v0.4 | Legacy — migrated to `chat_conversations` in v0.5; retained as nullable backward-compatible column |
| `dictations.hidden` | v0.5 | Private dictation mode flag |
| `dictations.wordCount` | v0.5 | Cached word count for voice stats |
| `chat_conversations` | v0.5 | Multi-conversation chat per transcription (FK → transcriptions) |
| `transcriptions.thumbnailURL` | v0.5 | YouTube video thumbnail URL |
| `transcriptions.channelName` | v0.5 | YouTube channel name |
| `transcriptions.videoDescription` | v0.5 | YouTube video description |
| `transcriptions.isFavorite` | v0.5 | User favorite marker |
| `transcriptions.sourceType` | v0.6 | Origin of transcription: `file`, `youtube`, or `meeting` |
| `text_snippets.action` | v0.7 | Keystroke action type for snippet |
| `prompts` | v0.7 | Reusable prompt templates (built-in + custom) |
| `summaries` | v0.7 | Prompt results per transcription (FK → transcriptions, cascade delete; Swift model `PromptResult`) |
| `lifetime_dictation_stats` | v0.7.4 | Singleton lifetime voice-stat counters |
| `daily_dictation_stats` | v0.11 | Per-day rollup powering Stats-tab heatmap + daily streaks |
| `transcriptions.recoveredFromCrash` | v0.7.5 | Interrupted meeting recovery marker |
| `transcriptions.isTranscriptEdited` | v0.7.7 | User-edited transcript marker |
| `transcriptions.userNotes` | v0.8 | Free-form notes captured during meeting recording |
| `summaries.userNotesSnapshot` | v0.8 | Snapshot of notes used for prompt generation |
| `dictations.engine` | v0.8 | STT engine that produced the dictation; `NULL` for legacy rows |
| `dictations.engineVariant` | v0.8 | Engine-specific variant id; `NULL` for engines without variants and legacy rows |
| `transcriptions.engine` | v0.8 | STT engine that produced the transcription; `NULL` for legacy rows |
| `transcriptions.engineVariant` | v0.8 | Engine-specific variant id; `NULL` for engines without variants and legacy rows |
| `transcriptions.derivedTitle` | v0.9 | Cached display title derived from transcript content |
| `transcriptions.derivedSnippet` | v0.9 | Cached display preview snippet derived from transcript content |
| `quick_prompts` | v0.10 | User-customizable live Ask tab shortcut pills; v0.6 product feature |
| `idx_transcriptions_source_type_created_at` / `idx_transcriptions_favorite_created_at` / `idx_transcriptions_status_created_at` | v0.10 | Library filter/sort indexes for source type, favorites, and status |
| `dictations.displayRawTranscript` | v0.12 | Reversible local "Undo AI edit" display override |
| `transform_history` | v0.14 (re-created v0.17) | Local Transform run history (input/output/source app/timings). Dropped by v0.16 along with the workbench tables, then recreated standalone in v0.17 once history was restored without the workbench. |
| ~~`transform_profiles`~~ / ~~`writing_samples`~~ | ~~v0.15~~ | ~~Transform Workbench tables~~ (dropped in v0.16; workbench feature removed) |
| `llm_runs` | v0.18 | Local metadata ledger for persisted LLM operations. Stores source links, feature/status, provider/model, latency, token counts, character counts, and errors; never stores prompt/input/output content. |
| `ai_formatter_profiles` | v0.21 | Local Dictation AI Formatter profiles keyed by exact bundle or coarse app category |
| `dictations.aiFormatterProfileID` / `dictations.aiFormatterProfileName` / `dictations.aiFormatterProfileMatchKind` | v0.21 | Local formatter routing provenance; not emitted in telemetry |

### Tables NOT Planned (YAGNI)

These might be needed someday but are explicitly deferred:

- **`settings`** -- Use `UserDefaults` / plist. No need for a settings table.
- **`exports`** -- Track via `exportPath` on `transcriptions`. No separate table.
- **`speakers`** -- Speaker labels and per-word speaker IDs live as JSON on `transcriptions` (v0.4 diarization). No separate table needed — speaker identity is per-transcription, not cross-file. Revisit only if cross-file speaker recognition is added.
- **`usage_stats`** -- Derive aggregate usage from existing tables and `llm_runs` queries. No separate aggregate tracking table.

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

*Last updated: 2026-05-16*
