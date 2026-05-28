# Meeting Prompts Workspace Plan

Date: 2026-05-27
Status: Active; Slice 1 implemented in `feat/meeting-prompts-workspace`

## Decision

Expose meeting prompt configuration from the dedicated Meetings workspace while
keeping detailed editing in the existing prompt sheets.

The Meetings page should become the control surface for meeting intelligence,
not a second settings page and not a duplicate prompt library. The first slice
should bridge to the existing live Ask quick prompts. Later slices can add
meeting-scoped post-recording recipes that run against saved meeting artifacts.

User-facing naming:

- `Meeting Prompts` for the Meetings-page section.
- `Live Ask` for the current `QuickPrompt` pills used in the live meeting Ask
  tab.
- `After Recording` or `Meeting Recipes` for saved-meeting prompt outputs backed
  by `Prompt` and `PromptResult`.

## Goals

- Make prompt configuration discoverable before a meeting starts.
- Keep the Meetings page workflow-oriented: upcoming, live, saved, attention,
  intelligence readiness, and prompt controls.
- Reuse the existing `AskPromptsSheet` for detailed live Ask prompt management.
- Preserve the distinction between live Ask quick prompts and saved-meeting
  prompt results.
- Keep provider configuration in Settings > AI.
- Preserve the privacy boundary: audio and transcription remain local-first;
  transcript and notes are sent only when the user invokes provider-backed
  intelligence.

## Non-Goals

- Do not build a full prompt admin page inside Meetings.
- Do not replace `AskPromptsSheet`.
- Do not merge `QuickPrompt` and `Prompt` into one model.
- Do not introduce a new `meetings` table.
- Do not add provider/model setup controls inside Meetings beyond readiness and
  links to Settings > AI.
- Do not auto-run meeting recipes on file, YouTube, or dictation artifacts.

## Product Shape

### Slice 1: Live Ask Prompt Bridge

Add a compact `Meeting Prompts` section to the Meetings workspace right column.

The section should show:

- `Live Ask` title and short explanation.
- Pinned prompt count.
- Top pinned prompt labels, capped visually to keep the card scannable.
- A `Manage` action that opens the existing `AskPromptsSheet`.
- A `New` action that opens the same sheet in create mode.
- An empty state if the quick-prompt repository is not configured yet or all
  prompts are hidden.

This slice should not add schema, prompt-result generation, or auto-run
behavior. It is a discoverability bridge.

### Slice 2: Meeting Recipe Defaults

Add saved-meeting recipes backed by the existing prompt-result architecture:

- Summary
- Action Items
- Decisions
- Risks / Blockers
- Follow-up Email

Recipes should run against `Transcription.sourceType == .meeting` artifacts and
persist as `PromptResult`. They should be source-scoped so meeting-specific
prompts never show up as generic file/YouTube actions by accident.

If the current `Prompt` metadata cannot express source scoping and display
order, add the smallest durable metadata surface needed. Prefer extending prompt
metadata over creating a new table unless the prompt model cannot carry the
contract cleanly.

### Slice 3: Saved Meeting Detail Integration

Surface the same recipes on saved meeting detail:

- Run
- Regenerate
- View Result
- Copy/export result where existing prompt-result surfaces already support it

The detail view should stay artifact-centered: transcript, notes, chat, prompt
results, and retained audio belong together. The full editor still opens in a
sheet.

### Slice 4: Auto-Run Preferences

After meeting-scoped recipes exist, add opt-in auto-run behavior:

- Per-recipe enable/disable.
- Optional "run after transcription completes" toggle.
- Clear provider disclosure for external providers.
- No auto-run for non-meeting sources.

Default should be conservative until product usage says otherwise. A safe first
default is all auto-run off, with one-click manual run.

## Architecture Boundary

Live Ask:

- Model: `QuickPrompt`
- View model: `QuickPromptsViewModel`
- UI: `AskPromptsSheet`, `LiveAskPaneView`
- Storage: `quick_prompts`
- Use case: in-flight meeting chat starter and follow-up pills

Saved meeting recipes:

- Model: `Prompt`
- Result model: `PromptResult`
- View model: `PromptResultsViewModel`
- UI: `TranscriptResultView` and future compact Meetings-page rows
- Storage: existing prompt and prompt-result tables
- Use case: post-meeting structured outputs

The plan intentionally keeps these models separate because their lifecycles and
UX contracts are different.

## Implementation Notes

Slice 1 implementation:

- `MeetingsWorkspaceViewModel`
  - Owns or receives a `QuickPromptsViewModel`.
  - Exposes a small preview projection so the view avoids prompt filtering
    logic.
  - Refresh quick prompts when the Meetings page appears and when the sheet
    closes.
- `AppEnvironmentConfigurer`
  - Configure that quick-prompt view model with `env.quickPromptRepo`.
- `MeetingsView`
  - Add a `Meeting Prompts` section to the right column, below intelligence or
    near it.
  - Present `AskPromptsSheet`.
  - Start create mode before presenting the sheet when the user taps `New`.

Slice 2 and later likely need source-scoped prompt metadata and tests. Do not
start auto-run until source scoping is explicit.

## Acceptance Criteria

- Meetings page exposes `Meeting Prompts`.
- Users can manage live Ask quick prompts from Meetings without opening a live
  meeting panel first.
- Users can create a new live Ask quick prompt from Meetings.
- The existing Ask tab prompt manager remains the detailed editing surface.
- The first slice adds no database migration.
- The UI stays compact on the right column and stacks cleanly in the narrow
  layout.
- External-provider copy remains in the existing Intelligence section; the
  prompt card does not imply local-only LLM processing.
- No telemetry includes prompt text, transcript text, notes, or audio.

## Review Risks

- Avoid presenting pinned prompts as post-meeting recipes; they are live Ask
  controls only.
- Avoid a settings-page feel by limiting the card to summary state and two
  actions.
- Ensure the Meetings page refreshes after sheet dismissal.
- Ensure `New` starts the create flow inside the sheet without skipping the
  existing validation and save logic.
- Ensure the view model can exist before environment configuration without
  crashing; show a quiet empty state until the repository is available.

## Open Questions

- Should the first `New` prompt from Meetings default to pinned or remain
  unpinned like the existing sheet? Current implementation should preserve the
  existing unpinned default unless the product explicitly changes that contract.
- Should meeting recipes auto-run by default after transcription, or should all
  be manual first? Recommendation: manual first.
- Should recipe preferences live on `Prompt` metadata or in a separate
  preference store? Decide during Slice 2 after inspecting current prompt model
  constraints.
- Should `Summary` remain global or become source-scoped once meeting recipes
  exist? Decide before auto-run.
