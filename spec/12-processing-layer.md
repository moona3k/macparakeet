# 12 - Processing Layer: Prompts, Actions & Workflows

> Status: **ACTIVE** — Authoritative, current
> Related: [spec/11-llm-integration.md](11-llm-integration.md) (LLM providers), [ADR-011](adr/011-llm-cloud-and-local-providers.md) (cloud + local providers), [ADR-013](adr/013-prompt-library-multi-summary.md) (prompt library + multi-summary)
> Triggered by: [GitHub issue #51](https://github.com/moona3k/macparakeet/issues/51), [VoiceInk PR #600](https://github.com/Beingpax/VoiceInk/pull/600) by @mitsuhiko

This spec defines MacParakeet's configurable processing layer — the system that transforms raw transcripts into useful outputs. It starts with a Prompt Library and multi-summary support (v0.7) and extends to actions and workflows in future versions.

---

## Goals

1. Give users control over how AI processes their transcripts — starting with summaries.
2. Support **multiple summaries per transcript** — different prompts produce different outputs, all navigable.
3. Establish a reusable **Prompt Library** that serves summaries today and can serve transforms, chat system prompts, and workflow steps tomorrow.
4. Define a layered architecture (Prompts → Actions → Workflows) where each layer is independently useful.
5. Avoid premature abstraction — build only what's needed now, but don't foreclose future capabilities.

## Non-Goals (for now)

1. Building a workflow engine or step chaining.
2. CLI action execution from the summary tab.
3. Post-dictation automation triggers.
4. Running multiple prompts simultaneously against one transcript (each is user-initiated).

---

## Architecture: Three Layers

```
Layer 3: Workflows (future)
  Chain actions into named sequences with triggers
  e.g., "Podcast Publish" = Summarize → Format → Export → Webhook

  ┌─────────────────────────────────────────────────┐
  │  Workflow { name, trigger, steps: [Action] }    │
  └──────────────────────┬──────────────────────────┘
                         │ references
Layer 2: Actions (future)
  Typed processing steps: LLM prompt, CLI command, export, webhook

  ┌─────────────────────────────────────────────────┐
  │  Action { type, config }                        │
  │    .prompt(id) → references Prompt Library       │
  │    .cliCommand(cmd) → Armin's pattern (PR #47)  │
  │    .export(format) → TXT/MD/SRT/DOCX/PDF        │
  │    .webhook(url) → POST result to endpoint       │
  └──────────────────────┬──────────────────────────┘
                         │ references
Layer 1: Prompt Library + Multi-Summary ← BUILD NOW (v0.7)
  Named, reusable instruction templates + multiple outputs per transcript

  ┌─────────────────────────────────────────────────┐
  │  Prompt  { id, name, content, category, ... }   │
  │  Summary { id, transcriptionId, promptName,     │
  │            content, ... }                        │
  └─────────────────────────────────────────────────┘
```

Each layer is independently useful. Layer 1 (Prompt Library) ships as a standalone feature. Layer 2 (Actions) adds non-LLM processing types. Layer 3 (Workflows) chains them together.

---

## Layer 1: Prompt Library + Multi-Summary (v0.7)

### Concept

A **Prompt** is a named, reusable instruction template that tells an LLM how to process a transcript. Called "Prompt" (not "Summary Preset") because the data model is general-purpose — the same prompt can serve summaries today, transforms tomorrow, and workflow steps later.

A **Summary** is a generated output tied to a specific transcript. Each transcript can have multiple summaries, each produced by a different prompt. Summaries snapshot the prompt that created them — they're self-contained records, not live references.

### Data Model: Prompt

```swift
public struct Prompt: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String          // "Meeting Notes", "Action Items"
    public var content: String       // The actual instruction text
    public var category: Category    // .summary (extensible)
    public var isBuiltIn: Bool       // shipped with app — hide only, no edit/delete
    public var isVisible: Bool       // false = hidden from picker
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
    createdAt         TEXT NOT NULL
);

CREATE INDEX idx_summaries_transcription_id ON summaries(transcriptionId);
```

**Why snapshot instead of reference:** Prompts can be edited or deleted after a summary is generated. The summary should always know exactly what instructions produced it. `promptName` is for display; `promptContent` is for reproducibility.

**Migration from existing data:** Existing `transcriptions.summary` values migrate into the `summaries` table with `promptName = "General Summary"` and `promptContent` set to the old hardcoded prompt text. Then `transcriptions.summary` is nulled out (column kept for backward compat, same pattern as `chatMessages` in v0.5).

### Built-in Prompts

Seven built-in prompts ship with the app, seeded during migration:

| # | Name | Sort | Prompt Content |
|---|------|------|----------------|
| 1 | General Summary | 0 | You are a helpful assistant that summarizes transcripts. Provide a clear, concise summary that captures the key points, decisions, and action items. Use bullet points for clarity. Keep the summary under 500 words. |
| 2 | Meeting Notes | 1 | Summarize this transcript as structured meeting notes. Include: a one-line meeting purpose, attendees mentioned, key discussion points as bullet points, decisions made, and action items with owners if mentioned. Use clear headings. |
| 3 | Action Items | 2 | Extract all action items, tasks, and commitments from this transcript. For each item include: what needs to be done, who is responsible (if mentioned), and any deadline or timeline mentioned. Format as a numbered list. If no clear action items exist, say so. |
| 4 | Key Quotes | 3 | Extract the most important and notable quotes from this transcript. Include exact wording where possible, with enough surrounding context to understand the significance. Attribute quotes to speakers if identified. List 5–10 quotes, ordered by importance. |
| 5 | Study Notes | 4 | Summarize this transcript as study notes. Extract key concepts, definitions, and explanations. Organize by topic with clear headings. Include any examples or analogies that aid understanding. End with a brief list of key terms. |
| 6 | Bullet Points | 5 | Summarize this transcript as a concise bullet-point list. Each bullet should capture one distinct point, fact, or idea. Aim for 10–20 bullets. No sub-bullets. Order by importance, not chronology. |
| 7 | Executive Brief | 6 | Write a 2–3 paragraph executive brief of this transcript. First paragraph: the core topic and why it matters. Second paragraph: key findings, decisions, or conclusions. Third paragraph (if needed): next steps or open questions. Write for a busy reader who needs the essential takeaway in under 60 seconds. |

"General Summary" (sort order 0) is the default — used for auto-summary and pre-selected in the picker. It preserves backward compatibility with the existing hardcoded summary prompt.

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
| None | None | "General Summary" built-in (backward compatible) |

Minimal framing when only extra instructions are provided:
```
You are a helpful assistant that processes transcripts. Follow the user's instructions below.

{extraInstructions}
```

### Auto-Summary Behavior

Auto-summary after transcription always uses the "General Summary" built-in prompt. No preset selection for auto-summary — keeps it simple and predictable. Users who want a different perspective generate manually via the prompt picker.

Conditions unchanged: `llmAvailable && transcript.count > 500`.

---

## UI

### Summary Pane

The summary tab has two zones: a **generation bar** at top (always visible) and a **summaries list** below.

#### Empty State (no summaries yet)

```
┌─────────────────────────────────────────────────┐
│  Transcript │ Summary │ Chat                     │
├─────────────────────────────────────────────────┤
│                                                  │
│   📄 No summaries yet                           │
│                                                  │
│   Prompt: [General Summary ▾]                    │
│   [Extra instructions...                      ]  │
│                                                  │
│   [Generate Summary]           [model ▾]         │
│                                                  │
└─────────────────────────────────────────────────┘
```

#### One or More Summaries Exist

```
┌─────────────────────────────────────────────────┐
│  Transcript │ Summary │ Chat                     │
├─────────────────────────────────────────────────┤
│                                                  │
│  Prompt: [Action Items ▾]      [Generate] [m ▾]  │
│  [Extra instructions...                       ]  │
│                                                  │
│  ┌─ Meeting Notes ─────────── 3 min ago ──────┐  │
│  │                                            │  │
│  │ • Q1 results exceeded targets by 12%       │  │
│  │ • Decision to expand team by 3 headcount   │  │
│  │ • Action: Sarah to prepare hiring plan     │  │
│  │                                            │  │
│  │ [Copy]                            [Delete] │  │
│  └────────────────────────────────────────────┘  │
│                                                  │
│  ▸ Action Items                    1 min ago     │
│                                                  │
└─────────────────────────────────────────────────┘
```

#### Key UX Behaviors

- **Generation bar always visible** at top — prompt dropdown + extra instructions + Generate button. Always ready to create a new summary.
- **Summaries listed below** as collapsible cards, newest first.
- **Most recent summary expanded** by default; older summaries collapsed (show name + timestamp only). Click to expand/collapse.
- **Each card shows:** prompt name as title, relative timestamp, summary content (markdown rendered), Copy button, Delete button.
- **Streaming:** When generating, a new card appears at top in streaming state (skeleton → content filling in). Other summaries remain visible below.
- **Delete:** Confirmation alert ("Delete this summary? This cannot be undone.").
- **Prompt dropdown pre-selects** "General Summary" by default. Remembers last-used prompt within the session (not persisted).

#### Prompt Dropdown Menu

```
┌──────────────────────────────┐
│ ✓ General Summary            │
│   Meeting Notes              │
│   Action Items               │
│   Key Quotes                 │
│   Study Notes                │
│   Bullet Points              │
│   Executive Brief            │
│ ─────────────────────────── │
│   My Standup Format          │  ← custom prompts
│   Client Debrief             │
│ ─────────────────────────── │
│   Manage Prompts...          │  ← opens management sheet
└──────────────────────────────┘
```

Built-in prompts first (only visible ones), custom prompts in a second section, "Manage Prompts..." at bottom.

### Management Sheet

Opened via "Manage Prompts..." in the dropdown menu. Follows the card-based management pattern from CustomWordsView.

```
┌─ Summary Prompts ────────────────────────────────┐
│                                                   │
│  ┌─ Built-in ─────────────────────────────────┐   │
│  │                                            │   │
│  │  ☑ General Summary        (always visible) │   │
│  │  ☑ Meeting Notes                           │   │
│  │  ☑ Action Items                            │   │
│  │  ☐ Key Quotes              (hidden)        │   │
│  │  ☑ Study Notes                             │   │
│  │  ☑ Bullet Points                           │   │
│  │  ☑ Executive Brief                         │   │
│  │                                            │   │
│  │               [Restore Defaults]           │   │
│  └────────────────────────────────────────────┘   │
│                                                   │
│  ┌─ Custom ───────────────────────────────────┐   │
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

- **Built-in prompts:** Toggle visibility via checkbox. "General Summary" cannot be hidden (it's the auto-summary fallback and default). "Restore Defaults" unhides all built-in prompts.
- **Custom prompts:** Full CRUD. Edit opens a sheet with name + multi-line TextEditor (prompt text is too long for inline editing). Delete with confirmation alert.
- **Add Prompt:** Name field + multi-line prompt content + Add button. Name must be unique (case-insensitive, across both built-in and custom).

---

## Relationship to Existing Specs

### spec/11-llm-integration.md

spec/11 §1 (Transcript Summary) describes a single-summary model with a hardcoded prompt. **This spec supersedes that section** — summaries now use the Prompt Library and support multiple outputs per transcript.

spec/11 §3 (Custom Transforms) describes transforms stored in UserDefaults. **The Prompt Library supersedes this concept** — transforms become prompts with `category: .transform`. Custom Transforms haven't been built in the GUI, so no migration needed. When transforms ship, they'll use the Prompt Library.

spec/11 §2 (Chat with Transcript) and all provider/protocol/CLI sections remain unchanged.

### ADR-011

Provider architecture is unchanged. The Prompt Library changes what goes into the system prompt, not how the LLM is called.

---

## Layer 2: Actions (future — design only, do not build)

An Action is a typed processing step. The Prompt Library is one action type. Others include:

| Action Type | Input | Output | Provider |
|-------------|-------|--------|----------|
| `.prompt(id)` | Transcript text | LLM-generated text | Configured LLM provider |
| `.cliCommand(cmd)` | Env vars + stdin | stdout text | Any CLI tool (PR #47 pattern) |
| `.export(format)` | Transcript + metadata | File on disk | Built-in ExportService |
| `.webhook(url)` | JSON payload | HTTP response | URLSession |
| `.clipboard` | Text | Clipboard contents | ClipboardService |

### The Interface Contract

Every action receives a `ProcessingContext` — the standard input regardless of action type:

```
ProcessingContext
  - transcript: String (raw or clean)
  - metadata: { source, filename, duration, speakers, language, youtubeURL }
  - previousOutput: String? (for chaining — output of the prior step)
  - diarizationSegments: [DiarizationSegment]?
  - wordTimestamps: [WordTimestamp]?
```

For CLI actions, the context maps to `MACPARAKEET_*` environment variables (extending PR #47):

| Variable | Value |
|----------|-------|
| `MACPARAKEET_TRANSCRIPT` | Transcript text |
| `MACPARAKEET_SOURCE_TYPE` | `"file"` / `"youtube"` / `"dictation"` |
| `MACPARAKEET_FILENAME` | Original filename |
| `MACPARAKEET_DURATION` | Audio duration in seconds |
| `MACPARAKEET_SPEAKER_COUNT` | Number of identified speakers |
| `MACPARAKEET_LANGUAGE` | Detected language code |
| `MACPARAKEET_YOUTUBE_URL` | Source YouTube URL (if applicable) |
| `MACPARAKEET_PREVIOUS_OUTPUT` | Output of the prior step (if chaining) |

This extends the env var contract sketched in PR #47 and inspired by VoiceInk PR #600 (@mitsuhiko).

---

## Layer 3: Workflows (future — vision only, do not build)

A Workflow chains Actions into a named sequence with a trigger.

```
Workflow { name, trigger, steps: [Action] }

trigger: .manual | .postTranscription | .postDictation
```

### Example Workflows

- **Podcast Publish:** Summarize key topics → Format as blog post → Export markdown → Webhook to CMS
- **Meeting Debrief:** Meeting notes prompt → Extract action items → Copy to clipboard
- **Quick Clean:** Post-dictation → Clean pipeline → Format → Paste

### UX Direction

A step-list builder with add/remove/reorder. Each step shows its type icon + name + brief config summary. Preview/dry-run mode to see what would happen without executing. Error handling per step: stop on error vs. continue.

### What This Enables

- "Every time I transcribe a meeting, generate meeting notes and email them to my team"
- "When I dictate, clean the text, format as code comments, and paste"
- "Transcribe this podcast, extract key quotes, format for Twitter, copy to clipboard"

The Prompt Library is the first building block. Actions add the non-LLM processing types. Workflows chain them together.

---

## Boundaries

| Build Now (v0.7) | Build Later |
|-------------------|-------------|
| `prompts` table + 7 built-in seeds | Action types beyond LLM prompts |
| `summaries` table (one-to-many) | Workflow engine / step chaining |
| Prompt model + repository | Post-transcription/dictation triggers |
| Summary model + repository | Multi-prompt simultaneous generation |
| Prompt dropdown picker | Transform prompts UI (when transforms ship) |
| Extra instructions field | CLI action configuration |
| Multi-summary navigation (collapsible cards) | Webhook / export actions |
| Management sheet (hide built-ins, CRUD custom) | Workflow builder UI |
| SummaryViewModel (extracted from TranscriptionVM) | ProcessingContext interface |
| LLMService accepts custom system prompt | |
| Migration from `transcriptions.summary` → `summaries` | |

---

## Testing

### Unit Tests

1. **PromptRepository:** CRUD operations, built-in seeding verification, visibility toggle, name uniqueness constraint, `restoreDefaults`, `fetchVisible` filtering by category.
2. **SummaryRepository:** CRUD operations, `fetchAll` ordering (newest first), cascade delete when transcription deleted, `hasSummaries` check.
3. **LLMService:** Custom system prompt flows through to message array; default prompt used when nil.
4. **PromptsViewModel:** CRUD operations, visibility toggle, validation (empty fields, duplicate names), restore defaults.
5. **SummaryViewModel:** Generation flow (prompt assembly → stream → persist), multi-summary state, delete, auto-summary with default prompt.

### What We Skip

- Visual layout of summary cards (test ViewModels instead).
- Actual LLM output quality (depends on external model).
- Prompt effectiveness (subjective, depends on transcript content).

---

## Acceptance Criteria

1. User can select a prompt from a dropdown on the summary tab.
2. Generating a summary creates a new summary record (does not overwrite previous summaries).
3. Multiple summaries per transcript are displayed as collapsible cards, newest first.
4. User can add extra instructions that layer on top of the selected prompt.
5. Seven built-in prompts are available on first launch.
6. Built-in prompts can be hidden but not edited or deleted.
7. Custom prompts can be created, edited, and deleted via the management sheet.
8. "Manage Prompts..." is accessible from the prompt dropdown menu.
9. Auto-summary after transcription uses "General Summary" default.
10. Existing transcriptions with summaries display migrated data correctly.
11. `swift test` passes with all new tests.
