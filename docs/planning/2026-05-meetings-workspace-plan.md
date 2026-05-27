# Meetings Workspace Plan

Date: 2026-05-27
Status: Planned

## Decision

Build a dedicated top-level Meetings workspace while keeping meeting recordings
visible in Library.

The first foundation slice should be thin. MacParakeet already has the core
meeting data model, capture stack, transcript artifact, chat, prompts, retained
audio, calendar coordination, and CLI surface. The Meetings workspace should
compose those existing capabilities into a workflow surface rather than create a
second meeting domain model.

Product framing:

> Recording and transcription are local-first. Meeting intelligence is
> provider-flexible and always user-chosen.

## Goals

- Make meetings a top-level product area, not only a Library filter.
- Preserve Library as the universal archive for all transcript artifacts.
- Keep `Transcription` as the stored meeting artifact.
- Surface upcoming calendar meetings, current recording state, recent meetings,
  templates/prompts, provider readiness, and attention states in one place.
- Make it obvious when intelligence leaves the device and which provider handles
  it.

## Non-Goals

- Do not introduce accounts as a requirement for recording or transcription.
- Do not replace `Transcription` with a separate persisted meeting object.
- Do not move all meeting logic into the app target; Core and ViewModels
  boundaries stay intact.
- Do not add cloud calendar OAuth in the first slice.
- Do not make any cloud LLM provider the default.

## Existing Assets

Capture and transcription:

- `MeetingRecordingService`
- `MeetingRecordingFlowCoordinator`
- `MeetingRecordingPillViewModel`
- `MeetingRecordingPanelViewModel`
- `MeetingRecordingPanelView`
- live `Notes / Transcript / Ask` panel
- dual-source meeting audio capture and retained meeting audio

Saved meeting artifacts:

- `Transcription.sourceType == .meeting`
- `TranscriptionLibraryViewModel(scope: .meetings)`
- `MeetingRowCard`
- `MeetingDateGroupHeader`
- `TranscriptResultView`
- `MeetingAudioActions`
- chat conversations through `TranscriptChatViewModel`
- prompt outputs through `PromptResultsViewModel`

Calendar:

- EventKit calendar service and monitor path from ADR-017
- `SettingsViewModel` calendar settings
- `MeetingAutoStartCoordinator`
- `MeetingCountdownToastController`
- CLI `calendar upcoming`

Intelligence and prompts:

- `LLMSettingsViewModel`
- `LLMService`
- `LLMConfigStore`
- `Prompt`, `PromptResult`, `PromptResultsViewModel`
- `QuickPrompt`, `QuickPromptsViewModel`, `AskPromptsSheet`
- CLI meeting and prompt commands

## Build Order

### Slice 1: Meetings Route Foundation

Add a `Meetings` sidebar item and a dedicated `MeetingsView`, backed by a new
`MeetingsWorkspaceViewModel`.

The view model should aggregate existing sources:

- current recording state from `MeetingRecordingPillViewModel`
- recent meeting rows from `TranscriptionLibraryViewModel(scope: .meetings)`
- calendar settings and permission state from `SettingsViewModel`
- upcoming calendar events from the existing calendar service path
- AI/provider readiness from `LLMSettingsViewModel` or a small read-only
  provider-status adapter
- attention states from recoverable meeting locks, failed transcriptions,
  missing provider setup, and unavailable retained audio

Expected files:

- `Sources/MacParakeet/Views/Meetings/MeetingsView.swift`
- `Sources/MacParakeetViewModels/MeetingsWorkspaceViewModel.swift`
- `Sources/MacParakeet/Views/MainWindowView.swift`
- `Sources/MacParakeet/Views/MainWindowState.swift`
- `Sources/MacParakeet/App/AppWindowCoordinator.swift`
- `Sources/MacParakeet/App/AppEnvironmentConfigurer.swift`

Tests:

- `MeetingsWorkspaceViewModelTests`
- sidebar routing smoke if existing view tests support it
- no full database migration tests expected for this slice

### Slice 2: Meetings Home UI

Build the first useful Meetings screen:

- header with current meeting status and primary record action
- `Upcoming` section with calendar events and record affordance
- `Recording Now` section when a meeting is active
- `Recent Meetings` section using existing meeting rows
- `Needs Attention` section for recovery/failure states

Keep the first UI dense and workflow-oriented. Avoid a marketing-style hero.
The first viewport should show actual meeting workflow controls.

### Slice 3: Meeting Intelligence Readiness

Add a compact meeting intelligence setup strip:

- current provider name
- local/cloud badge
- readiness state
- direct action to Settings > AI
- explicit copy when a selected provider sends transcript/notes off-device

Support posture:

- local/no-cloud providers remain valid
- OpenAI API and OpenRouter remain explicit provider choices
- local CLI/Ollama/LM Studio remain explicit provider choices
- ChatGPT subscription can be added as an opt-in provider later, labeled
  experimental if it depends on a non-API integration path

This slice should not block recording or transcription.

### Slice 4: Meeting Templates And Recipes

Make meeting-specific intelligence presets discoverable.

First pass should reuse prompt infrastructure:

- built-in meeting prompts for summary, action items, decisions, blockers,
  follow-ups, and risks
- meeting-only grouping in the prompt UI
- apply/re-run on a meeting artifact
- preserve outputs as `PromptResult`

Only add a new meeting-template table if prompt metadata cannot express the
required UX. Prefer tagging or scoping existing prompts first.

### Slice 5: Saved Meeting Detail Polish

Improve the saved meeting detail flow without creating a separate detail object:

- keep transcript, notes, chat, prompt results, and audio in one coherent
  artifact view
- make speaker information and source separation easier to scan
- make retained audio actions visible
- make re-run/regenerate actions clear
- keep post-meeting chat persistent

This can happen inside `TranscriptResultView` or via a meeting-specific wrapper
that still uses the same underlying view models.

### Slice 6: Optional Provider Expansion

Add ChatGPT subscription support only after the provider boundary is clean.

Requirements:

- opt-in
- Keychain storage for tokens
- clear "sends transcript/notes to ChatGPT" disclosure
- no dependency for core recording/transcription
- good failure states for expired auth, missing session, rate limits, and
  unsupported account state
- no audio/transcript/notes/prompt content in telemetry

## Backend And Foundation Scope

Likely needed:

- `MeetingsWorkspaceViewModel` aggregation layer
- read-only provider-readiness adapter if `LLMSettingsViewModel` is too
  UI-shaped
- calendar upcoming-event adapter suitable for view models
- attention-state helpers for failed/recoverable meetings
- prompt scoping/tagging if meeting-specific presets need first-class grouping

Likely not needed:

- new `meetings` table
- new calendar cache table
- new recording service
- new transcript storage format
- new chat storage format
- new prompt-result storage format

Possible later backend changes:

- richer meeting metadata if the workspace needs user-visible fields that do
  not belong on `Transcription`
- cross-meeting memory/indexing if meeting intelligence expands beyond a single
  artifact
- provider integration for ChatGPT subscription mode

## Initial Implementation Issue

Title:

- Add dedicated Meetings workspace shell backed by existing meeting artifacts

Acceptance criteria:

- Sidebar has a `Meetings` item.
- `Meetings` opens a dedicated workspace, not the generic Library screen.
- Recent meetings are loaded through
  `TranscriptionLibraryViewModel(scope: .meetings)`.
- Active recording state is visible and can open/stop the existing meeting
  recording flow.
- Calendar permission/auto-start status is visible if calendar support is
  enabled.
- Empty state explains how to record a meeting without implying account setup.
- Library still shows meetings under its existing filter.
- No database migration.
- No cloud provider required.

## Follow-Up Issues

### Add Meeting Intelligence Readiness And Provider Setup State

Acceptance criteria:

- Meetings workspace shows whether intelligence is configured.
- It distinguishes local/no-cloud providers from external providers.
- It links to Settings > AI.
- It does not block recording or local transcription.
- It contains no transcript/audio/notes content in telemetry.

### Add Meeting Prompt Presets And Meeting-Specific Prompt Grouping

Acceptance criteria:

- Built-in meeting prompts exist for summary, action items, decisions, risks,
  blockers, and follow-ups.
- Prompts run against saved meetings and persist as prompt results.
- Users can edit or hide meeting prompt presets through existing prompt
  management patterns.
- Live Ask quick prompts remain separate from saved-meeting prompt results
  unless deliberately unified.

## Open Questions

- Should the `Meetings` sidebar item sit between `Library` and `Dictations`, or
  directly after `Transcribe`?
- Should active recording controls in the Meetings workspace open the floating
  panel or embed a larger live workspace in the main window?
- Should meeting prompt presets be a scoped view over existing prompts, or a
  separate "meeting templates" concept?
- What is the minimum provider status API needed for Settings > AI and Meetings
  to share readiness without leaking UI concerns into Core?
- Should ChatGPT subscription support be implemented before or after meeting
  templates?

## Recommendation

Start with Slice 1 and Slice 2 together as the first implementation package.
That gives the app a first-class Meetings surface with almost no risky backend
change.

Do provider expansion after the workspace has a stable place to show readiness,
failure, and cloud/local disclosure.
