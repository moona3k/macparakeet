# 12 - Processing Layer: Prompt Library + Multi-Summary

> Status: **ACTIVE** — Authoritative, current
> Related: [spec/11-llm-integration.md](11-llm-integration.md) (LLM providers), [spec/13-agent-workflows.md](13-agent-workflows.md) (future workflows, agents, voice control), [ADR-011](adr/011-llm-cloud-and-local-providers.md) (cloud + local providers), [ADR-013](adr/013-prompt-library-multi-summary.md) (prompt library + multi-summary)
> Triggered by: [GitHub issue #51](https://github.com/moona3k/macparakeet/issues/51), [VoiceInk PR #600](https://github.com/Beingpax/VoiceInk/pull/600) by @mitsuhiko

This spec defines MacParakeet's current processing layer for v0.7: the Prompt Library and multi-summary system. It is intentionally limited to the data model, UX, and service/view-model behavior needed for prompt-driven summary generation today.

---

## Goals

1. Give users control over how AI processes their transcripts — starting with summaries.
2. Support **multiple summaries per transcript** — different prompts produce different outputs, all navigable.
3. Establish a reusable **Prompt Library** that serves summaries today and can serve transforms, chat system prompts, and workflow steps tomorrow.
4. Leave a clean extension point for future actions, workflows, and agent features without over-designing them now.
5. Avoid premature abstraction — build only what's needed now, but don't foreclose future capabilities.

## Non-Goals (for now)

1. Building a workflow engine or step chaining.
2. CLI action execution from the summary tab.
3. Post-dictation automation triggers.
4. Running multiple prompts in parallel against one transcript.
5. Defining agent profiles, desktop-control context, or voice-control automation. Those are explored in [spec/13-agent-workflows.md](13-agent-workflows.md), not locked here.

---

## Architecture

### Current Scope

The processing layer currently consists of a reusable Prompt Library and immutable Summary records.

```
┌────────────────────────────────────────────────────────────┐
│  Prompt Library ← BUILD NOW (v0.7)                        │
│  Prompt { id, name, content, category, visibility, ... }  │
└──────────────────────────────┬─────────────────────────────┘
                               │ snapshot
                               ▼
┌────────────────────────────────────────────────────────────┐
│  Summaries                                                │
│  Summary { id, transcriptionId, promptName,               │
│            promptContent, extraInstructions, content, ... }│
└────────────────────────────────────────────────────────────┘
```

Prompts are reusable templates. Summaries are historical outputs that snapshot the prompt content used at generation time.

### Data Model Relationships

```
prompts
  │
  └──snapshot──→ summaries.promptContent
```

The Prompt Library is intentionally general-purpose, but this spec only locks the behavior needed for summary generation. Future actions, workflows, and agent-driven automation are tracked separately in [spec/13-agent-workflows.md](13-agent-workflows.md).

### Prompt Categories

`Prompt.Category` currently supports:

- `.summary` — used by the summary pane today
- `.transform` — reserved for future transform UI

Additional categories are future schema decisions and are not part of this spec.

---

## Prompt Library + Multi-Summary (v0.7)

### Concept

A **Prompt** is a named, reusable instruction template that tells an LLM how to process a transcript. Called "Prompt" (not "Summary Preset") because the data model is general-purpose — the same prompt can serve summaries today, transforms tomorrow, and workflow steps later.

A **Summary** is a generated output tied to a specific transcript. Each transcript can have multiple summaries, including multiple runs of the same prompt with different per-run instructions. Summaries snapshot the prompt that created them — they're self-contained records, not live references.

### Data Model: Prompt

```swift
public struct Prompt: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String          // "Meeting Notes", "Action Items"
    public var content: String       // The actual instruction text
    public var category: Category    // .summary (extensible)
    public var isBuiltIn: Bool       // community prompt — hide only, no edit/delete
    public var isVisible: Bool       // false = hidden from picker
    public var isAutoRun: Bool       // true = auto-generate for new transcriptions
    public var sortOrder: Int        // display ordering
    public var createdAt: Date
    public var updatedAt: Date

    public enum Category: String, Codable, Sendable {
        case summary
        case transform   // future
    }
}
```

```sql
CREATE TABLE prompts (
    id        TEXT PRIMARY KEY,
    name      TEXT NOT NULL,
    content   TEXT NOT NULL,
    category  TEXT NOT NULL DEFAULT 'summary',
    isBuiltIn INTEGER NOT NULL DEFAULT 0,
    isVisible INTEGER NOT NULL DEFAULT 1,
    isAutoRun INTEGER NOT NULL DEFAULT 0,
    sortOrder INTEGER NOT NULL DEFAULT 0,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL
);

CREATE UNIQUE INDEX idx_prompts_name ON prompts(name COLLATE NOCASE);
```

### Data Model: Summary

```swift
public struct Summary: Codable, Identifiable, Sendable {
    public var id: UUID
    public var transcriptionId: UUID
    public var promptName: String         // snapshot: "Meeting Notes"
    public var promptContent: String      // snapshot: the full prompt used
    public var extraInstructions: String?  // user's extra instructions (if any)
    public var content: String            // the generated summary text
    public var createdAt: Date
    public var updatedAt: Date
}
```

```sql
CREATE TABLE summaries (
    id                TEXT PRIMARY KEY,
    transcriptionId   TEXT NOT NULL REFERENCES transcriptions(id) ON DELETE CASCADE,
    promptName        TEXT NOT NULL,
    promptContent     TEXT NOT NULL,
    extraInstructions TEXT,
    content           TEXT NOT NULL,
    createdAt         TEXT NOT NULL,
    updatedAt         TEXT NOT NULL
);

CREATE INDEX idx_summaries_transcription_id ON summaries(transcriptionId);
```

**Why snapshot instead of reference:** Prompts can be edited or deleted after a summary is generated. The summary should always know exactly what instructions produced it. `promptName` is for display; `promptContent` is for reproducibility.

**Migration from existing data:** Existing `transcriptions.summary` values migrate into the `summaries` table with `promptName = "General Summary"` and `promptContent` set to the current default summary prompt text. The legacy `transcriptions.summary` column is preserved and mirrors the newest completed summary for backward compatibility.

### Community Prompts

The current branch seeds seven built-in/community prompts from `Prompt.builtInPrompts()` in Swift. `Sources/MacParakeetCore/Resources/community-prompts.json` exists as a contribution/reference file, but it is not yet the runtime source of truth for prompt seeding.

`General Summary` is seeded as the initial built-in auto-run prompt and remains the default fallback when prompt data is unavailable. The shipped built-in list is: `General Summary`, `Meeting Notes`, `Action Items`, `Key Quotes`, `Study Notes`, `Bullet Points`, and `Executive Brief`.

### System Prompt Assembly

When generating a summary, the system prompt is assembled from the selected prompt + optional extra instructions:

```
{prompt.content}

{extraInstructions}       ← only if user provided extra instructions
```

Edge cases:

| Prompt | Extra Instructions | Result |
|--------|--------------------|--------|
| Selected | None | Prompt content only (most common case) |
| Selected | Provided | Prompt content + blank line + extra instructions |
| None | Provided | Minimal framing + extra instructions (see below) |
| None | None | Default community prompt (backward compatible) |

Minimal framing when only extra instructions are provided:
```
You are a helpful assistant that processes transcripts. Follow the user's instructions below.

{extraInstructions}
```

### Auto-Run Behavior

Prompt cards may be marked `isAutoRun = true` in the prompt library.

- When a new transcription finishes and `llmAvailable && transcript.count > 500`, the app auto-generates summaries for every prompt card with `isAutoRun = true`.
- Multiple auto-run prompt cards are allowed.
- Zero auto-run prompt cards is a valid configuration. In that state, transcription and chat still work, and users generate prompt tabs manually from the summary UI.
- Auto-run prompt cards are forced visible while auto-run is enabled.
- If prompt data cannot be loaded at all, the runtime falls back to `General Summary`.

---

## UI

### Summary Pane

The summary experience is tab-based rather than card-based.

- `Transcript` remains the first tab.
- Each completed summary gets its own tab.
- Each pending generation gets its own tab immediately.
- `Chat` remains the final tab.
- A dedicated `Summarize` affordance opens the generation popover.

If no prompt cards are marked auto-run, this summary affordance is how users add prompt tabs manually after transcription.

#### Generation Popover

The generation popover contains:

- prompt chips for visible summary prompts
- a manage button that opens the prompt-library sheet
- model selector
- extra instructions field
- queue status text when generations are pending
- generate button

#### Queued Summary Pipeline

Summary generation uses a **single-worker queue**:

- one summary may actively stream at a time
- additional user-triggered generations are accepted immediately and appended to the queue
- queued generations appear as their own tabs right away
- when the active generation finishes, the next queued generation starts automatically
- the app does **not** run multiple summary streams in parallel

#### Pending Generation Tabs

Pending generation tabs render in one of two states:

- `Streaming`: live markdown fill with cancel support
- `Queued`: waiting state with remove support

When a generation completes:

- if the user is currently viewing that generation tab, it transitions into the completed summary tab
- otherwise the current tab stays put and the completed summary receives a badge

#### Completed Summary Tabs

- completed summaries render as markdown
- generate appends a new completed summary tab every time
- regenerate replaces only the specific summary the user chose, and only after the new result is durably saved
- copy is available from both the pane and tab context menu
- delete requires confirmation

### Management Sheet

Opened via the management control in the summary generation popover. Follows the card-based management pattern from CustomWordsView.

```
┌─ Summary Prompts ────────────────────────────────┐
│                                                   │
│  ┌─ Community ────────────────────────────────┐   │
│  │                                            │   │
│  │  ☑ (default prompt)       (always visible) │   │
│  │  ☑ ...                                     │   │
│  │                                            │   │
│  │  [Suggest a prompt]  [Restore Defaults]    │   │
│  └────────────────────────────────────────────┘   │
│                                                   │
│  ┌─ My Prompts ──────────────────────────────┐   │
│  │                                            │   │
│  │  ● My Standup Format     [Edit] [Delete]   │   │
│  │  ● Client Debrief        [Edit] [Delete]   │   │
│  │                                            │   │
│  └────────────────────────────────────────────┘   │
│                                                   │
│  ┌─ Add Prompt ───────────────────────────────┐   │
│  │  Name:   [_____________________________]   │   │
│  │  Prompt: [_____________________________]   │   │
│  │          [_____________________________]   │   │
│  │          [_____________________________]   │   │
│  │                               [Add]        │   │
│  └────────────────────────────────────────────┘   │
│                                                   │
│                                      [Done]       │
└───────────────────────────────────────────────────┘
```

- **Community prompts:** Toggle visibility via checkbox. Auto-run prompts stay visible while auto-run is enabled. Turning auto-run off makes the card manually-only and eligible to be hidden. "Restore Defaults" unhides all community prompts. "Suggest a prompt" links to the JSON file on GitHub for contributors.
- **My Prompts:** Full CRUD. Edit opens a sheet with name + multi-line TextEditor (prompt text is too long for inline editing). Delete with confirmation alert.
- **Add Prompt:** Name field + multi-line prompt content + Add button. Name must be unique (case-insensitive, across both community and custom).

---

## Relationship to Existing Specs

### spec/11-llm-integration.md

spec/11 §1 (Transcript Summary) describes a single-summary model with a hardcoded prompt. **This spec supersedes that section** — summaries now use the Prompt Library and support multiple outputs per transcript.

spec/11 §3 (Custom Transforms) describes transforms stored in UserDefaults. **The Prompt Library supersedes this concept** — transforms become prompts with `category: .transform`. Custom Transforms haven't been built in the GUI, so no migration needed. When transforms ship, they'll use the Prompt Library.

spec/11 §2 (Chat with Transcript) and all provider/protocol/CLI sections remain unchanged.

### ADR-011

Provider architecture is unchanged. The Prompt Library changes what goes into the system prompt, not how the LLM is called.

---

## Boundaries & Sequencing

| Build Now (v0.7) | Explore Later |
|------------------|---------------|
| `prompts` table + community prompt seeds | Action types beyond prompt-driven summarization |
| `summaries` table (one-to-many) | Workflow engine / step chaining |
| Prompt model + repository | Triggered automation |
| Summary model + repository | Agent profiles / agent handoff |
| Prompt chips + generation popover | Desktop-context collection |
| Extra instructions field | Apple Shortcuts / App Intents integration |
| Multi-summary tab navigation + queued pipeline | |
| Management sheet (hide community, CRUD custom) | |
| SummaryViewModel (extracted from TranscriptionVM) | |
| LLMService accepts custom system prompt | |
| Migration from `transcriptions.summary` → `summaries` | |

The future design space for actions, workflows, agents, and voice control is documented in [spec/13-agent-workflows.md](13-agent-workflows.md). That document is exploratory and does not override the implementation contract defined here.

---

## Testing

### Unit Tests

1. **PromptRepository:** CRUD operations, community prompt seeding verification, visibility toggle, name uniqueness constraint, `restoreDefaults`, `fetchVisible` filtering by category.
2. **SummaryRepository:** CRUD operations, `fetchAll` ordering (newest first), cascade delete when transcription deleted, `hasSummaries` check.
3. **LLMService:** Custom system prompt flows through to message array; default prompt used when nil.
4. **PromptsViewModel:** CRUD operations, visibility toggle, validation (empty fields, duplicate names), restore defaults.
5. **SummaryViewModel:** Generation flow (prompt assembly → stream → persist), multi-summary state, delete, auto-run with selected prompt cards, and zero-auto-run behavior.

### What We Skip

- Visual layout of summary tabs and queued states (test ViewModels instead).
- Actual LLM output quality (depends on external model).
- Prompt effectiveness (subjective, depends on transcript content).

---

## Acceptance Criteria

1. User can select a prompt from chips in the generation popover on the summary tab.
2. Generating a summary creates a new summary record (does not overwrite previous summaries).
3. Multiple summaries per transcript are displayed as tabs, with pending generations appearing immediately.
4. User can add extra instructions that layer on top of the selected prompt.
5. Community prompts are available on first launch from the bundled JSON seed.
6. Community prompts can be hidden but not edited or deleted.
7. Custom prompts can be created, edited, and deleted via the management sheet.
8. Prompt management is accessible from the generation popover.
9. Auto-run after transcription uses every prompt card marked `isAutoRun`, and zero auto-run cards is a supported state.
10. Existing transcriptions with summaries display migrated data correctly.
11. `swift test` passes with all new tests.
