# Prompt Library + Multi-Summary Implementation Plan

> Status: **ACTIVE**
> Spec: [spec/12-processing-layer.md](../../spec/12-processing-layer.md)
> ADR: [ADR-013](../../spec/adr/013-prompt-library-multi-summary.md)
> Issue: [#51](https://github.com/moona3k/macparakeet/issues/51)

## Overview

Implement the Prompt Library and multi-summary feature (Layer 1 of the processing layer architecture). Users can select from built-in or custom prompts to generate summaries, generate multiple different summaries per transcript, and manage their prompt library.

## Design Decisions

See ADR-013 for full rationale. Key choices:
- `prompts` table in SQLite (not UserDefaults, not "summary_presets")
- `summaries` table with one-to-many relationship to transcriptions
- Prompt snapshots on summaries (not foreign keys)
- Dropdown picker (not chips)
- Auto-summary always uses "General Summary" default
- SummaryViewModel extracted (follows TranscriptChatViewModel pattern)

## New Files

| File | Target | Purpose |
|------|--------|---------|
| `Sources/MacParakeetCore/Models/Prompt.swift` | Core | Prompt model (GRDB) |
| `Sources/MacParakeetCore/Models/Summary.swift` | Core | Summary model (GRDB) |
| `Sources/MacParakeetCore/Database/PromptRepository.swift` | Core | Prompt CRUD (protocol + impl) |
| `Sources/MacParakeetCore/Database/SummaryRepository.swift` | Core | Summary CRUD (protocol + impl) |
| `Sources/MacParakeetViewModels/PromptsViewModel.swift` | ViewModels | Prompt management |
| `Sources/MacParakeetViewModels/SummaryViewModel.swift` | ViewModels | Summary generation + navigation |
| `Sources/MacParakeet/Views/Transcription/SummaryPromptsView.swift` | GUI | Management sheet |
| `Tests/MacParakeetTests/PromptRepositoryTests.swift` | Tests | Prompt CRUD + seeding |
| `Tests/MacParakeetTests/SummaryRepositoryTests.swift` | Tests | Summary CRUD + migration |
| `Tests/MacParakeetTests/PromptsViewModelTests.swift` | Tests | ViewModel logic |
| `Tests/MacParakeetTests/SummaryViewModelTests.swift` | Tests | Generation + navigation |
| `Tests/MacParakeetTests/LLMServicePromptTests.swift` | Tests | Custom system prompt assembly |

## Modified Files

| File | Change |
|------|--------|
| `Sources/MacParakeetCore/Database/DatabaseManager.swift` | v0.7 migration: create `prompts` + `summaries` tables, seed 7 built-ins, migrate `transcriptions.summary` → `summaries` |
| `Sources/MacParakeetCore/Services/LLMService.swift` | `summarize()` + `summarizeStream()` accept optional `systemPrompt: String?`; update `LLMServiceProtocol` |
| `Sources/MacParakeetViewModels/TranscriptionViewModel.swift` | Remove inline summary state — delegate to SummaryViewModel |
| `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift` | Replace summary pane: dropdown + extra instructions + collapsible cards |
| `Sources/MacParakeet/App/AppEnvironment.swift` | Create `PromptRepository` + `SummaryRepository`, pass to ViewModels |

## Implementation Steps

### Step 1: Models

Create `Prompt.swift`:
- Struct with `id`, `name`, `content`, `category` (enum: `.summary`, `.transform`), `isBuiltIn`, `isVisible`, `sortOrder`, `createdAt`, `updatedAt`
- Conforms to `Codable, Identifiable, Sendable, FetchableRecord, PersistableRecord`
- `databaseTableName = "prompts"`
- `Columns` enum for GRDB filtering

Create `Summary.swift`:
- Struct with `id`, `transcriptionId`, `promptName`, `promptContent`, `extraInstructions`, `content`, `createdAt`
- Same GRDB conformances
- `databaseTableName = "summaries"`
- `Columns` enum for filtering

### Step 2: Repositories

Create `PromptRepository.swift`:
- `PromptRepositoryProtocol`: `save`, `fetch(id:)`, `fetchAll()`, `fetchVisible(category:)`, `delete(id:)`, `toggleVisibility(id:)`, `restoreDefaults()`
- Concrete `PromptRepository` wrapping `DatabaseQueue`
- `fetchAll` sorted by `sortOrder` then `name`
- `fetchVisible` filters `isVisible == true` + optional category filter
- `restoreDefaults` sets `isVisible = true` for all built-in prompts

Create `SummaryRepository.swift`:
- `SummaryRepositoryProtocol`: `save`, `fetchAll(transcriptionId:)`, `delete(id:)`, `deleteAll(transcriptionId:)`, `hasSummaries(transcriptionId:)`
- Concrete `SummaryRepository` wrapping `DatabaseQueue`
- `fetchAll` sorted by `createdAt` descending (newest first)
- Follows `ChatConversationRepository` pattern exactly

### Step 3: Migration

Add to `DatabaseManager.swift`:

```swift
// v0.7 — Prompt Library + Multi-Summary
migrator.registerMigration("v0.7-prompts-and-summaries") { db in
    // Create prompts table
    try db.create(table: "prompts") { t in
        t.column("id", .text).primaryKey()
        t.column("name", .text).notNull()
        t.column("content", .text).notNull()
        t.column("category", .text).notNull().defaults(to: "summary")
        t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
        t.column("isVisible", .boolean).notNull().defaults(to: true)
        t.column("sortOrder", .integer).notNull().defaults(to: 0)
        t.column("createdAt", .text).notNull()
        t.column("updatedAt", .text).notNull()
    }
    try db.execute(sql: """
        CREATE UNIQUE INDEX idx_prompts_name ON prompts(name COLLATE NOCASE)
    """)

    // Seed 7 built-in prompts
    let now = Date()
    let builtIns: [(String, String, Int)] = [
        ("General Summary", "You are a helpful assistant that summarizes transcripts. Provide a clear, concise summary that captures the key points, decisions, and action items. Use bullet points for clarity. Keep the summary under 500 words.", 0),
        ("Meeting Notes", "Summarize this transcript as structured meeting notes. Include: a one-line meeting purpose, attendees mentioned, key discussion points as bullet points, decisions made, and action items with owners if mentioned. Use clear headings.", 1),
        ("Action Items", "Extract all action items, tasks, and commitments from this transcript. For each item include: what needs to be done, who is responsible (if mentioned), and any deadline or timeline mentioned. Format as a numbered list. If no clear action items exist, say so.", 2),
        ("Key Quotes", "Extract the most important and notable quotes from this transcript. Include exact wording where possible, with enough surrounding context to understand the significance. Attribute quotes to speakers if identified. List 5–10 quotes, ordered by importance.", 3),
        ("Study Notes", "Summarize this transcript as study notes. Extract key concepts, definitions, and explanations. Organize by topic with clear headings. Include any examples or analogies that aid understanding. End with a brief list of key terms.", 4),
        ("Bullet Points", "Summarize this transcript as a concise bullet-point list. Each bullet should capture one distinct point, fact, or idea. Aim for 10–20 bullets. No sub-bullets. Order by importance, not chronology.", 5),
        ("Executive Brief", "Write a 2–3 paragraph executive brief of this transcript. First paragraph: the core topic and why it matters. Second paragraph: key findings, decisions, or conclusions. Third paragraph (if needed): next steps or open questions. Write for a busy reader who needs the essential takeaway in under 60 seconds.", 6),
    ]
    for (name, content, sortOrder) in builtIns {
        let id = UUID()
        try db.execute(sql: """
            INSERT INTO prompts (id, name, content, category, isBuiltIn, isVisible, sortOrder, createdAt, updatedAt)
            VALUES (?, ?, ?, 'summary', 1, 1, ?, ?, ?)
        """, arguments: [id, name, content, sortOrder, now, now])
    }

    // Create summaries table
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
    }
    try db.create(
        index: "idx_summaries_transcription_id",
        on: "summaries",
        columns: ["transcriptionId"]
    )

    // Migrate existing transcriptions.summary → summaries table
    let defaultPromptContent = "You are a helpful assistant that summarizes transcripts. Provide a clear, concise summary that captures the key points, decisions, and action items. Use bullet points for clarity. Keep the summary under 500 words."
    let rows = try Row.fetchAll(db, sql: """
        SELECT id, summary FROM transcriptions WHERE summary IS NOT NULL AND summary != ''
    """)
    for row in rows {
        guard let transcriptionId = UUID.fromDatabaseValue(row["id"] as DatabaseValue),
              let summaryText = String.fromDatabaseValue(row["summary"] as DatabaseValue) else { continue }
        let summaryId = UUID()
        try db.execute(sql: """
            INSERT INTO summaries (id, transcriptionId, promptName, promptContent, content, createdAt)
            VALUES (?, ?, ?, ?, ?, ?)
        """, arguments: [summaryId, transcriptionId, "General Summary", defaultPromptContent, summaryText, now])
    }

    // Null out migrated summaries (keep column for backward compat)
    try db.execute(sql: "UPDATE transcriptions SET summary = NULL WHERE summary IS NOT NULL")
}
```

### Step 4: Tests (data layer)

`PromptRepositoryTests.swift`:
- Test built-in prompts are seeded after migration (7 prompts, all visible, all built-in)
- Test CRUD: save custom, fetch by ID, fetchAll ordering, delete
- Test `fetchVisible` returns only visible prompts
- Test `toggleVisibility` flips isVisible
- Test `restoreDefaults` unhides all built-in
- Test name uniqueness constraint (case-insensitive)

`SummaryRepositoryTests.swift`:
- Test save + fetchAll (ordered by createdAt desc)
- Test multiple summaries per transcription
- Test delete single summary
- Test deleteAll for a transcription
- Test hasSummaries
- Test cascade delete (delete transcription → summaries deleted)

### Step 5: Service layer

Update `LLMServiceProtocol`:
```swift
func summarize(transcript: String, systemPrompt: String?) async throws -> String
func summarizeStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error>
```

Default parameter `systemPrompt: String? = nil` — when nil, uses existing `Prompts.summary` (backward compat for any callers not yet updated).

`LLMServicePromptTests.swift`:
- Verify custom systemPrompt is used in message array when provided
- Verify default Prompts.summary is used when systemPrompt is nil

### Step 6: ViewModels

`SummaryViewModel.swift` — follows `TranscriptChatViewModel` pattern:
- `@Observable @MainActor`
- State: `summaries`, `expandedSummaryIDs`, `isStreaming`, `streamingContent`, `streamingSummaryID`, `selectedPrompt`, `extraInstructions`, `errorMessage`, `visiblePrompts`
- `configure(llmService:, promptRepo:, summaryRepo:, configStore:, cliConfigStore:)`
- `loadSummaries(transcriptionId:)` — fetch from repo, auto-expand newest
- `loadVisiblePrompts()` — fetch visible summary prompts for dropdown
- `generateSummary(transcript:, transcriptionId:)` — assemble system prompt, stream, persist
- `deleteSummary(_:)` — delete with pending confirmation pattern
- `autoSummarize(transcript:, transcriptionId:)` — uses "General Summary", called post-transcription
- Model selection (same pattern as TranscriptChatViewModel)

`PromptsViewModel.swift` — follows `CustomWordsViewModel` pattern:
- `@Observable @MainActor`
- State: `prompts`, `newName`, `newContent`, `errorMessage`, `pendingDeletePrompt`, `editingPrompt`
- `configure(repo:)`
- `loadPrompts()`, `addPrompt()`, `updatePrompt(_:)`, `toggleVisibility(_:)`, `confirmDelete()`, `restoreDefaults()`
- Validation: non-empty, unique name (case-insensitive)

Update `TranscriptionViewModel.swift`:
- Remove: `summary`, `summaryState`, `summaryBadge`, `summaryTask`, `generateSummary()`, `autoSummarizeIfNeeded()`, `dismissSummary()`, `resetSummaryState()`, `loadPersistedContent()` summary logic
- Keep: `showTabs` — update to check `summaryRepo?.hasSummaries(transcriptionId:)` or delegate to SummaryViewModel
- Add: `summaryViewModel: SummaryViewModel` reference
- `completeSuccessfulTranscription` calls `summaryViewModel.autoSummarize(...)` instead of inline `autoSummarizeIfNeeded`

### Step 7: Views

`SummaryPromptsView.swift`:
- Card-based management sheet (follows CustomWordsView)
- Header card with title + Done button
- Built-in card: visibility checkboxes, "General Summary" always-on, Restore Defaults
- Custom card: prompt rows with Edit/Delete, empty state
- Add card: name TextField + content TextEditor + Add button
- Edit: sheet with name + TextEditor (for multi-line prompt content)
- Delete confirmation alert

Update `TranscriptResultView.swift` summary pane:
- Replace `summaryPane` computed property entirely
- Generation bar: prompt dropdown (SwiftUI `Menu`) + extra instructions `TextField` + Generate button + model selector
- Summary list: `ForEach(summaryVM.summaries)` as collapsible cards
- Card: prompt name header, relative timestamp, `MarkdownContentView`, Copy/Delete buttons
- Streaming card at top during generation
- Empty state placeholder
- Wire `SummaryViewModel` + `PromptsViewModel`
- `.sheet` for `SummaryPromptsView`

### Step 8: Wiring

Update `AppEnvironment.swift`:
- `let promptRepo = PromptRepository(dbQueue: databaseManager.dbQueue)`
- `let summaryRepo = SummaryRepository(dbQueue: databaseManager.dbQueue)`
- Pass to ViewModels during configuration

### Step 9: Docs

- Update `spec/README.md`: add spec/12 row, ADR-013 row, v0.7 roadmap entry
- Update `CLAUDE.md`: add spec/12 to Quick Navigation, ADR-013 to ADR table, v0.7 to Current Phase

## Verification

**Automated:** `swift test` — all existing 1126 tests pass + new tests pass

**Manual (via `scripts/dev/run_app.sh`):**
1. Summary tab shows prompt dropdown pre-selected to "General Summary"
2. Generate → creates a summary card with prompt name label
3. Pick different prompt → Generate → second card appears above first
4. Expand/collapse summary cards
5. Copy copies summary text to clipboard
6. Delete removes a summary (with confirmation)
7. Extra instructions append to prompt
8. Dropdown shows only visible prompts
9. "Manage Prompts..." opens management sheet
10. Can hide built-in prompts (disappear from dropdown)
11. Can create/edit/delete custom prompts
12. "Restore Defaults" unhides all built-in prompts
13. Auto-summary after transcription creates one summary using "General Summary"
14. Existing transcriptions with summaries show migrated data

**Edge cases:**
- No prompt selected + no extra instructions → "General Summary" default
- No prompt selected + extra instructions only → minimal framing + instructions
- All prompts hidden → dropdown still shows custom + "Manage Prompts..."
- Delete all summaries → returns to empty state
- Generate while streaming → button disabled
- Switch transcriptions mid-stream → stream detaches, persists in background
