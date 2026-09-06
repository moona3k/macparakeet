# Database

> SQLite via GRDB. One file (`macparakeet.db`), one repository per
> table, inline migrations registered in `DatabaseManager`.

## Entry point

`DatabaseManager` — owns the `DatabaseQueue`. Normal initializers run migrations;
`init(readOnlyPath:)` opens an existing database without initialization or
migrations for non-mutating probes such as CLI `health`. Every repository takes
a `DatabaseManager` (or its `dbQueue`). The app shares one manager; separate CLI
processes own their connections.

## What's here

- `DatabaseManager.swift` — connection setup, migrator registration,
  schema versions. The single source of truth for the database
  schema.
- One repository per table:
  - `DictationRepository.swift` — dictation history + lifetime stats.
  - `TranscriptionRepository.swift` — file/YouTube/meeting transcriptions.
  - `SegmentRepository.swift` — derived transcript segments, FTS5 search, slicing, and deterministic rebuilds.
  - `CardRepository.swift` — derived per-recording knowledge cards, provenance staleness, deterministic joins, and card FTS sync.
  - `CustomWordRepository.swift` — vocabulary entries.
  - `TextSnippetRepository.swift` — snippets (text + action).
  - `PromptRepository.swift` — prompt-library entries.
  - `PromptVersionRepository.swift` — immutable prompt request versions.
  - `PromptResultRepository.swift` — saved prompt outputs.
  - `QuickPromptRepository.swift` — quick-prompt entries (Ask tab).
  - `ChatConversationRepository.swift` — multi-turn chat history.
  - `TransformHistoryRepository.swift` — local Transform run history (input/output/source app/timings; ADR-022).
  - `LLMRunRepository.swift` — local metadata ledger for persisted LLM runs (provider/model/tokens/latency/status/required source link; no prompt/input/output content).

## Cross-references

- `spec/01-data-model.md` — the canonical schema spec; mirrors
  what's in `DatabaseManager`'s migrator. Update both when schema
  changes.
- ADR-013 — prompt library + multi-summary architecture (drives
  several of the repositories above).
- `Sources/MacParakeetCore/Models/` — the row types each repository
  reads and writes.

## What to know before editing

**Migrations are inline in `DatabaseManager`, not separate files.**
Each migration is a `migrator.registerMigration("vX.Y-name") { db in
... }` block. The naming convention is `vX.Y-<table-or-feature>` so
the migration ledger doubles as a release-version trail. Migrations
run once and are never edited after a release ships — to change a
shipped schema, register a *new* migration that performs the
adjustment. The registered identifiers are exposed via
`DatabaseManager.registeredMigrationIdentifiers`, and
`unknownAppliedMigrationIdentifiers(at:)` compares them (read-only)
against a database's `grdb_migrations` ledger — the CLI `health`
command uses this to report schema skew when a stale CLI opens a
database migrated by a newer app.
The health probe uses `init(readOnlyPath:)` for its subsequent statistics reads
too, so inspecting an older database does not apply pending migrations.

**One repository per table. Don't combine tables in one repo.**
Each repository implements a `…Protocol` so callers can be tested
against a mock. The repository owns CRUD plus any table-specific
helpers (FTS search, stats aggregation). Cross-table writes and workflow
orchestration live at the service layer. A table-owned read-model query may
join immutable metadata when SQL-level filtering or ranking requires it; for
example, segment search joins transcription dates, sources, and titles.

Meeting rename uses `TranscriptionRepository.updateFileName` to return the
updated row from the same write transaction, or `nil` when the ID is missing.
Publish state and refresh artifacts from that returned row; do not synthesize
success from a stale snapshot or make a second fetch part of write success.

Transcription completion uses `savePreservingUserMetadata` and publishes the
returned row. The repository merges current notes, meeting type, favorite,
title override, legacy chat, artifact-folder and audio pointers, and concurrent meeting
renames inside the same write transaction. Explicit clears remain clears and `updatedAt` never moves behind the current row.
Pass the processing snapshot's original file name so an automatic title may
replace an unchanged name, while a rename during STT wins. The service and GUI
must both use this boundary; a later full-row save would undo the merge.
Transcript output and engine attribution still come from the completed run.
A missing row aborts completion; it must never recreate a recording deleted
during processing. Every repository conformer must implement this transaction
explicitly; a fetch followed by a separate save is not an atomic merge.

**Segments are derived retrieval state, not new source-of-truth transcript
data.** `segments` normalizes meeting and file/URL transcript JSON for search;
`segments_fts` is an external-content FTS5 index kept in sync by triggers.
Both can be rebuilt with `macparakeet-cli search-reindex` from
`transcriptions`. Dictations are excluded. `KnowledgeSegmenter.currentVersion`
freezes the derivation rules: pseudo-segmentation is a pure function of text
using explicit scalar rules, with no locale or NaturalLanguage framework
dependency. Any rule change that can alter `(transcriptionId, seq)` citations
must bump the version. Rebuilds replace one transcription per write transaction
so normal app writes can interleave, and retranscription invalidates old derived
rows before publishing a newly completed transcript so stale text is never
searchable under the new canonical row. App launch performs a detached,
per-recording repair of rows written by older segmenter versions; cards CLI
entry points run the same repair before reading or generating cards.

**Cards are failure-safe derived state.** `CardRepository` enforces the
approximate 350-token persistence budget on every write. Generation validates
JSON, resolves citations against current-version segments, and applies
source-conditional fields before the single upsert, so a malformed, cancelled,
or failed replacement never deletes the previous valid card. Card staleness is
the four-field tuple `(transcriptHash, promptVersion, cardSchemaVersion,
segmenterVersion)`; model and generation time are audit provenance only.
After provider latency, generation revalidates the transcript and segment
snapshot, and the repository repeats that comparison inside the save
transaction. Retranscription publishes replacement segments and deletes the old
card atomically; list queries suppress any stale card that remains after other
canonical edits.

**Never use raw SQL `WHERE id = ?` with `uuid.uuidString`.**
GRDB stores UUID values via Codable encoding, which produces a
representation that is not always equal to `UUID.uuidString`. Use
GRDB's `fetchOne(key:)` + `update()` pattern for primary-key
lookups, and `Codable`-aware filter expressions for predicates. A
raw-SQL UUID lookup will silently miss rows. This has bitten the
repo before and is the single most common database bug shape we see.

**In-memory databases for tests.** `DatabaseManager()` (no args)
returns an in-memory queue with the same migrator applied. Use
this in unit and integration tests — never write to the on-disk
file from tests. In-memory fixtures are fast, isolated, and don't
require cleanup.

**Foreign keys are on.** `Configuration().foreignKeysEnabled = true`
is set in `makeConfiguration`. Migrations and inserts must respect
foreign-key constraints; cascading deletes are explicit on each FK.

**Short concurrent writes wait.** `Configuration.busyMode = .timeout(5)`
is set so separate GUI/CLI/agent processes wait through brief SQLite write
locks instead of surfacing immediate `SQLITE_BUSY` failures. Long-held locks
still fail visibly after the timeout.

**File-backed migrations are process-serialized.** `DatabaseManager(path:)`
uses a sibling `.migration.lock` file while running migrations and built-in
seed reconciliation. This keeps parallel CLI/agent first-run processes from
racing on an empty database.

**SQL tracing in DEBUG.** Set the env var `MACPARAKEET_DEBUG_SQL=1`
to print every executed statement. Useful for diagnosing slow
queries or accidental N+1 patterns during development; off by
default and unavailable in release builds.

**Lifetime-stats counter row.** `DictationRepository` maintains a
singleton row (`lifetime_dictation_stats`) that survives history
deletion. Increments happen in the same transaction as the
dictation save (issue #124). If you add a stat, add it to that row,
the migration for the column, and the `resetLifetimeStats()` path.

## How to verify a change

- `swift test --filter Database` — repository unit tests.
- `swift test --filter Migration` (where applicable) — confirm new
  migrations apply cleanly to an empty database and to a
  previous-version snapshot.
- `swift test` — full suite. Schema changes ripple through services
  and view models.
- Manual: launch a DEBUG build with `MACPARAKEET_DEBUG_APP_STATE_DIR` set to
  a new temporary directory, then confirm migrations initialize its empty
  database. Never delete or reset the normal app database for verification.
