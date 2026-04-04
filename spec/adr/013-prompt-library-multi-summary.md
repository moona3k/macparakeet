# ADR-013: Prompt Library + Multi-Summary Architecture

> Status: **Accepted**
> Date: 2026-04-03
> Related: ADR-011 (LLM providers), spec/12-processing-layer.md

## Context

MacParakeet's LLM summary feature (spec/11 §1) uses a single hardcoded system prompt and stores one summary per transcript (`transcriptions.summary` column). Users have requested control over how summaries are generated — different transcript types (meetings, lectures, podcasts) need different summarization approaches ([GitHub issue #51](https://github.com/moona3k/macparakeet/issues/51)).

The feature request also revealed a broader need: users want to run multiple different prompts against the same transcript and keep all the results. A meeting transcript might need both "Meeting Notes" and "Action Items" summaries simultaneously.

Additionally, this feature is the first building block for a future processing layer — configurable workflows that chain LLM prompts, CLI commands, exports, and webhooks (inspired by [VoiceInk PR #600](https://github.com/Beingpax/VoiceInk/pull/600) by @mitsuhiko and MacParakeet's own Local CLI transport in PR #47).

## Decision

### 1. Prompt Library stored in SQLite

Reusable prompt templates are stored in the `prompts` table (not UserDefaults). Each prompt has a name, content, category, and visibility flag. Built-in prompts ship with the app and can be hidden but not edited or deleted. Custom prompts support full CRUD.

The table is named `prompts` (not `summary_presets`) because the model is general-purpose — the same prompt can serve summaries today, transforms tomorrow, and workflow steps later. A `category` enum field (`.summary`, `.transform`) scopes prompts to their use case.

### 2. Multiple summaries per transcript

Each transcript can have multiple summaries, stored in a new `summaries` table with a one-to-many relationship to `transcriptions`. This follows the same pattern as multi-conversation chat (`chat_conversations` table, introduced in v0.5).

Generating a new summary adds a record — it does not overwrite the previous summary. Users navigate between summaries via collapsible cards on the summary tab.

### 3. Prompt snapshots on summaries

Each summary record stores a snapshot of the prompt name and content used to generate it (not a foreign key reference to the `prompts` table). This ensures summaries are self-contained — editing or deleting a prompt after generation doesn't break or change the summary's metadata.

### 4. Dropdown picker (not chips)

The prompt selector is a dropdown/menu (not inline chips) because:
- It takes one line instead of 3-4 rows, keeping the summary pane compact
- It scales to any number of prompts without layout overflow
- "Manage Prompts..." fits naturally as a menu item at the bottom
- Most users will use the default — the picker should be accessible but not dominant

### 5. Auto-summary uses default prompt

Auto-summary after transcription always uses the "General Summary" built-in prompt (identical to the current hardcoded prompt). No configuration for auto-summary behavior. Users who want a different perspective generate manually.

## Rationale

### Why SQLite for prompts (not UserDefaults)?

All other user-managed data in MacParakeet (dictations, transcriptions, custom words, text snippets, chat conversations) lives in SQLite via GRDB. Prompts follow the same pattern for consistency, testability (in-memory SQLite), and query capability. The established repository protocol pattern (e.g., `CustomWordRepository`) maps directly.

### Why multi-summary (not overwrite)?

The single-summary model forces users to choose: "Do I want Meeting Notes or Action Items?" With multi-summary, the answer is "both." This aligns with the broader vision of transcripts as raw material that can be processed through multiple lenses. The implementation cost is modest — the `chat_conversations` table already proves the one-to-many pattern.

### Why snapshots (not foreign keys)?

A prompt is a living document — users edit and refine their custom prompts over time. A summary should always accurately reflect what produced it. If the "Meeting Notes" prompt is edited next week, existing summaries generated with the old version should still show the original prompt. This is the same reason git stores snapshots, not diffs.

### Why not build the full workflow engine now?

The three-layer architecture (Prompts → Actions → Workflows) is the long-term vision, but building a workflow engine is a massive scope increase that requires: action type definitions, an execution engine, inter-step state passing, error handling per step, and a workflow builder UI. The Prompt Library is the foundation that makes all of this possible later, without any premature abstraction. See spec/12-processing-layer.md for the full layered design.

## Consequences

### Positive

- Users get control over summary generation without complexity for the default case
- Multiple summaries per transcript supports real workflows (meeting notes + action items)
- Prompt Library is general-purpose — serves transforms and workflows when those features ship
- Data model follows established patterns (GRDB, protocol-based repos, @Observable VMs)
- Prompt snapshots make summaries self-contained and reproducible
- Migration from existing single-summary data is clean (same pattern as chatMessages → chat_conversations)

### Negative

- **More storage:** Multiple summaries per transcript uses more database space than a single column. Minimal impact — summary text is small compared to transcript text.
- **UI complexity:** The summary tab gains a generation bar and card navigation. Mitigated by keeping the generation bar compact (dropdown, not chips) and collapsing older summaries.
- **Migration required:** Existing `transcriptions.summary` data must migrate to the new `summaries` table. One-time, follows the proven v0.5 migration pattern.
- **SummaryViewModel extraction:** Summary logic moves out of TranscriptionViewModel into a dedicated SummaryViewModel. More files, but cleaner separation (follows TranscriptChatViewModel precedent).

## Architecture

```
┌─────────────────────────────────────────────────┐
│  TranscriptResultView (summary pane)            │
│    ├─ Prompt dropdown (reads from PromptRepo)   │
│    ├─ Extra instructions field                  │
│    ├─ Generate button                           │
│    └─ Summary cards (reads from SummaryRepo)    │
│         │                                       │
│         ▼                                       │
│  SummaryViewModel                               │
│    ├─ Prompt selection + assembly               │
│    ├─ Streaming via LLMService                  │
│    └─ Persistence via SummaryRepository         │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│  SummaryPromptsView (management sheet)          │
│         │                                       │
│         ▼                                       │
│  PromptsViewModel                               │
│    └─ CRUD via PromptRepository                 │
└─────────────────────────────────────────────────┘

Database:
  prompts     ←  7 built-in + user custom
  summaries   ←  0-N per transcription (cascade delete)
```
