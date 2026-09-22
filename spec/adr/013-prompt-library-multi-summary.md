# ADR-013: Prompt Library + Multi-Summary Architecture

> Status: **Accepted**
> Date: 2026-04-03
> Related: ADR-011 (LLM providers), spec/12-processing-layer.md, ADR-022 (Transforms)
> Implementation Note (2026-04-04): The current implementation seeds built-in/community prompts from `Prompt.builtInPrompts()` in Swift. `community-prompts.json` exists as a contribution/reference artifact, but runtime JSON loading has not shipped.
> Naming Note (2026-04-28): The database table remains `summaries`, but the Swift model/repository/view-model names are now `PromptResult`, `PromptResultRepository`, and `PromptResultsViewModel`.
> Transform Note (2026-05-13): ADR-022 now uses `Prompt.Category.transform` for productized Transforms. The Prompt Library serves summaries and Transforms today; workflow steps remain future work.
> Inference Settings Amendment (2026-09-03): Custom result prompts may carry typed, optional inference settings. They are snapshotted when work is queued, filtered by the selected provider/model, and the effective settings actually sent are stored with the resulting `PromptResult`. See spec/14.
> Versioning And Classification Amendment (2026-09-05): Prompt content,
> inference settings, and an optional model override now live in immutable
> prompt versions. Built-in provenance no longer restricts edit/delete rights.
> Every transcription can carry multiple labels. Result prompts can target
> labels to control availability; auto-run remains the prompt's source-aware
> setting and only runs when the prompt is available. See the amendment below.

## Context

MacParakeet's LLM summary feature (spec/11 §1) uses a single hardcoded system prompt and stores one summary per transcript (`transcriptions.summary` column). Users have requested control over how summaries are generated — different transcript types (meetings, lectures, podcasts) need different summarization approaches ([GitHub issue #51](https://github.com/moona3k/macparakeet/issues/51)).

The feature request also revealed a broader need: users want to run multiple different prompts against the same transcript and keep all the results. A meeting transcript might need both "Meeting Notes" and "Action Items" summaries simultaneously.

Additionally, this feature is the first building block for a future processing layer — configurable workflows that chain LLM prompts, CLI commands, exports, and webhooks (inspired by [VoiceInk PR #600](https://github.com/Beingpax/VoiceInk/pull/600) by @mitsuhiko and MacParakeet's own Local CLI transport in PR #47).

## Decision

### 2026-09-05 amendment: immutable versions and label context

The `prompts` row owns a prompt's stable identity and mutable operational
metadata. Its active content is resolved through `activeVersionId` to one
immutable `prompt_versions` row. Prompt content, requested typed inference
settings, and an optional active-provider model override are versioned. Name,
technical category, organization collection, visibility, ordering, shortcut,
running label, and routing policies are not versioned.

Creating a prompt creates version 1. Saving a change to versioned values creates
and activates exactly one new version in the same transaction. A no-op save
creates no version. Restoring a historical version copies its values into a new,
monotonically numbered version; history is never rewritten and the active
pointer is never moved backwards. The new version's `createdAt` and the prompt's
`updatedAt` record the restoration time; historical timestamps remain unchanged.
Runtime consumers obtain the resolved active
prompt from `PromptRepository`; they do not join version tables themselves.
The old `prompts.content` and `prompts.inferenceSettings` columns may exist only
during a bounded migration window and are not maintained as permanent mirrors.

Built-in prompts and user-created prompts have the same rename, edit,
reconfigure, recategorize, hide, route, and delete rights. `isBuiltIn` is
provenance only. Delete is soft delete so history and generated-result
snapshots remain recoverable, and so launch reconciliation cannot resurrect a
deleted built-in. A canonical built-in update is applied automatically only
when persisted provenance proves that the prompt has never been customized or
deleted. Otherwise MacParakeet may present the bundled definition as a
comparison candidate, but it does not insert or activate that candidate without
an explicit user action.

Queued work captures `promptId`, `promptVersionId`, prompt text, requested
settings, and model selection. Retry and completed-result snapshots remain
stable after later edits or classification changes. Result rows retain their
self-contained name/content/settings snapshots even when the originating
prompt or version is deleted.

Model discovery supplies selection choices, not an exhaustive allowlist: valid
provider aliases need not appear in that list. Runtime rejects empty or locally
incompatible model identifiers and otherwise sends the requested identifier to
the generation endpoint. Provider rejection is surfaced without switching models.
Local CLI commands control their own model selection, so an override differing
from the configured model is rejected before launching the command. An unchanged
model snapshot and an inherited model continue to use that command.

Version comparison runs away from the main actor and publishes only the current
selection's result; rendering the history view does not recompute the diff.

User-defined classification is label-only and applies to every transcription
source. A result prompt may target zero or more labels. The common GUI choice is all transcriptions or any selected label (OR semantics).
With no stored policies, availability defaults to everywhere. Explicit matching
label policies take precedence (any available match wins); otherwise the all-label
fallback applies, or availability is denied. Auto-run remains source-aware prompt metadata and is
gated by the same availability result. The resolver drives both manual
selection and automatic generation. Changing labels after enqueue never
mutates queued work and never triggers generation retroactively.

`prompt_label_policies` stores the fallback and label-specific availability
rules. The Prompt Manager exposes the common subset as either “All
transcriptions” or a set of labels. The legacy `prompt_meeting_policies` and
meeting-type tables remain temporarily for downgrade compatibility; migration
v0.38 copies their rules to labels and runtime selection no longer consults
meeting types.

### 1. Prompt Library stored in SQLite

Reusable prompt templates are stored in the `prompts` table (not UserDefaults). Each prompt has a name, content, category, visibility flag, and auto-run flag; ADR-022 adds nullable `keyboardShortcut` and `runningLabel` columns for Transform prompts. Built-in/community prompts are currently seeded from Swift constants in `Prompt.builtInPrompts()`. The JSON file at `Sources/MacParakeetCore/Resources/community-prompts.json` is kept as a contribution/reference artifact, not the active runtime seed source. Built-in and custom result/Transform prompts share full editing, versioning, and recoverable soft-deletion rights.

The table is named `prompts` (not `summary_presets`) because the model is general-purpose — the same table serves summaries and Transforms today, and can serve workflow steps later. A `category` enum field (`.result`, `.transform`; result stores `"summary"`) scopes prompts to their use case.

### 2. Multiple summaries per transcript

Each transcript can have multiple summaries, stored in a new `summaries` table with a one-to-many relationship to `transcriptions`. This follows the same pattern as multi-conversation chat (`chat_conversations` table, introduced in v0.5).

Generating a summary appends a new record and preserves earlier results, even when the same prompt is used with different per-run instructions. Regenerate is the only replacement path: it replaces the specific summary the user chose, and only after the new result has been durably saved. Users navigate between summaries via tabs on the summary screen.

### 3. Prompt snapshots on summaries

Each summary record stores a snapshot of the prompt name and content used to generate it (not a foreign key reference to the `prompts` table). This ensures summaries are self-contained — editing or deleting a prompt after generation doesn't break or change the summary's metadata.

### 4. Compact prompt chips inside a popover

The prompt selector lives inside a dedicated summary-generation popover and uses compact chips rather than a dropdown because:
- it keeps the main transcript/summaries surface focused on content, not controls
- visible prompts are directly tappable without opening nested menus
- prompt management can live alongside the chips in the same popover
- a wrapped layout still scales to a modest prompt set without taking over the main pane

### 5. Summary generation is queued, not parallel

Users can queue multiple summary requests from the same transcript, but the app runs only one summary stream at a time. Additional requests appear immediately as queued tabs and start automatically when the active generation finishes.

This preserves the responsive UX of “let me ask for several summaries now” without the reliability and state complexity of parallel LLM streaming.

### 6. Auto-run uses selected prompt cards

Auto-run after transcription uses visible result prompt cards marked
`isAutoRun = true` whose `appliesToSources` scope includes that source (`nil`
means all sources). This is user-configurable in the prompt library rather than fixed to the first built-in prompt.

Zero auto-run prompt cards is a valid state. In that configuration, transcription still completes normally, chat remains available, and users add prompt tabs manually from the summary UI.

### 7. Per-prompt inference settings use typed snapshots

A custom result prompt may store optional `temperature`, `topP`, `topK`,
`maxTokens`, thinking mode, and reasoning effort values. Reasoning
effort is retained only while thinking is explicitly enabled. This is a typed domain model,
not an arbitrary request-body editor. Built-in prompts and Transform prompts
keep these settings unset in the initial contract.

The blank state means inherit MacParakeet's current prompt-result and adapter
defaults, including the existing `temperature = 0.7` operation baseline and
native Ollama thinking-off behavior. It does not force raw upstream-provider
defaults. When generation is queued, prompt text, per-run context, and requested
settings become one immutable work receipt. The adapter then allow-lists fields
for its provider/model and returns the effective settings actually serialized;
that normalized receipt is stored on the `PromptResult`. Unsupported fields
are omitted and surfaced in GUI compatibility information, not persisted as
per-result omission metadata. Invalid numeric values are rejected rather than
omitted, with neutral validation at decoding/repository/execution boundaries
and provider-compatible range checks before dispatch. Anthropic Top P takes
precedence over temperature; effective temperature must be in `0...1`.
Its inherited 4096 output-token limit is reserved equally on initial runs and
regeneration. Provider/model configuration is resolved at execution, not stored
in the queue receipt.

This preserves the original snapshot rationale while making it honest across
provider-specific request contracts. It also keeps inference settings scoped
to Prompt Library results: chat, Transforms, the AI formatter, knowledge cards,
and speech recognition retain their existing behavior.

## Rationale

### Why SQLite for prompts (not UserDefaults)?

All other user-managed data in MacParakeet (dictations, transcriptions, custom words, text snippets, chat conversations) lives in SQLite via GRDB. Prompts follow the same pattern for consistency, testability (in-memory SQLite), and query capability. The established repository protocol pattern (e.g., `CustomWordRepository`) maps directly.

### Why multi-summary (not overwrite)?

The single-summary model forces users to choose: "Do I want Meeting Notes or Action Items?" With multi-summary, the answer is "both." This aligns with the broader vision of transcripts as raw material that can be processed through multiple lenses. The implementation cost is modest — the `chat_conversations` table already proves the one-to-many pattern.

### Why a queue (not parallel generation)?

True parallel streaming would require multiple live LLM tasks, multiple temporary tab states, more cancellation and replacement edge cases, and more difficult testing. A queue preserves the important UX property — users can keep asking for more summaries immediately — while keeping execution deterministic and the implementation much safer.

### Why snapshots (not foreign keys)?

A prompt is a living document — users edit and refine their custom prompts over time. A summary should always accurately reflect what produced it. If a prompt is edited next week, existing summaries generated with the old version should still show the original prompt. This is the same reason git stores snapshots, not diffs.

### Why not build the full workflow engine now?

The three-layer architecture (Prompts → Actions → Workflows) is the long-term vision, but building a workflow engine is a massive scope increase that requires: action type definitions, an execution engine, inter-step state passing, error handling per step, and a workflow builder UI. The Prompt Library is the foundation that makes all of this possible later, without any premature abstraction. See spec/12-processing-layer.md for the full layered design.

## Consequences

### Positive

- Users get control over summary generation without complexity for the default case
- Multiple summaries per transcript supports real workflows (meeting notes + action items)
- Prompt Library is general-purpose — serves summaries and Transforms now, with workflow reuse left for later
- Data model follows established patterns (GRDB, protocol-based repos, @Observable VMs)
- Prompt snapshots make summaries self-contained and reproducible
- Migration from existing single-summary data is clean (same pattern as chatMessages → chat_conversations)

### Negative

- **More storage:** Multiple summaries per transcript uses more database space than a single column. Minimal impact — summary text is small compared to transcript text.
- **UI complexity:** The summary tab gains a generation popover, tab navigation, and queued states. Mitigated by keeping execution single-worker and the controls compact.
- **Migration required:** Existing `transcriptions.summary` data must migrate to the new `summaries` table. One-time, follows the proven v0.5 migration pattern.
- **PromptResultsViewModel extraction:** Summary logic moves out of TranscriptionViewModel into a dedicated PromptResultsViewModel. More files, but cleaner separation (follows TranscriptChatViewModel precedent).

## Architecture

```
┌─────────────────────────────────────────────────┐
│  TranscriptResultView (summary pane)            │
│    ├─ Summary popover (chips + model + extras)  │
│    ├─ Pending generation tabs                   │
│    └─ Summary tabs (reads from PromptResultRepo)│
│         │                                       │
│         ▼                                       │
│  PromptResultsViewModel                         │
│    ├─ Prompt selection + assembly               │
│    ├─ Single-worker generation queue            │
│    └─ Persistence via PromptResultRepository    │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│  SummaryPromptsView (management sheet)          │
│         │                                       │
│         ▼                                       │
│  PromptsViewModel                               │
│    └─ CRUD via PromptRepository                 │
└─────────────────────────────────────────────────┘

Database:
  prompts     ←  built-in/community Swift seeds + user custom
  summaries   ←  0-N per transcription (cascade delete)
```
