# Meeting Health, Artifacts, and Speaker Rename Plan

> **Status:** IMPLEMENTED 2026-07-04 — shipped as PR #707 (source health
> model + UI), PR #708 (meeting.md artifact + shared renderer + CLI/contract
> promotion), and PR #710 (speaker rename UX + rollback guard). Remaining:
> health UI hidden behind default-off flag per product decision 2026-07-04
> (chips read as warnings during normal quiet capture); model/plumbing
> retained. PRs #857/#860 later supplied the invisible-until-actionable
> recovery surface; that continuing lifecycle contract belongs to ADR-025 and
> the still-active meeting mic-reliability plan.
> **Date:** 2026-07-04
> **Priority:** P1 for visible source health, P2 for artifact/CLI promotion and
> speaker rename polish
> **Category:** meetings / trust / artifacts / transcript UX
> **Source of truth:** ADR-014, ADR-010, `spec/contracts/meeting-artifacts-v1.md`,
> `spec/contracts/cli-json-v1.md`, and
> `docs/research/2026-07-04-open-source-meeting-recorder-review.md`.
> **Explicit owner boundary:** AEC/source-trust closure is handled separately.
> This plan consumes `microphone-cleaned.m4a` when present, but does not close
> AEC, retune echo suppression, or run no-headset QA.
> **Explicit product boundary:** no live diarization, no returning-speaker
> profiles, no voice enrollment, and no biometric identity claims.

## Executor Instructions

Start by checking drift against the files named below. The active worktree may
contain unrelated meeting-AEC edits, so do not revert or rely on dirty local
changes unless the implementation branch owns them.

Recommended drift check:

```bash
git status --short
git diff --stat -- Sources/MacParakeetCore/Services/MeetingRecording Sources/MacParakeetCore/Audio Sources/MacParakeetViewModels Sources/MacParakeet/Views/MeetingRecording Sources/MacParakeet/Views/Transcription Sources/CLI Tests spec/contracts integrations plans/active
```

If this plan conflicts with a newer accepted ADR/spec, update the plan before
coding. If it overlaps with `plans/active/2026-06-14-meeting-mic-reliability.md`,
treat this plan as the productized Phase B/C surface for user-visible health and
reflect progress back into that older plan as slices land.

## Goal

Make meeting recording feel trustworthy at the user and automation boundary by:

1. Showing visible microphone and system-audio health while recording.
2. Promoting meeting artifacts into stable, scriptable, user-visible outputs:
   Markdown export, cleaned-mic manifest entries, and agent-friendly CLI
   commands/specs.
3. Finishing confirmed per-meeting speaker rename UX for completed transcripts,
   while keeping diarization anonymous and post-meeting only.

This is not a "more AI" plan. It is a trust and product-contract plan over the
meeting system MacParakeet already has.

## Minimal Product Slice

Keep the implementation boring and obvious:

- Health: derive a small source-health snapshot from facts the recorder already
  has. Do not add stream restarts, recovery automation, or new capture behavior.
- Artifacts: add the missing paths and one shared Markdown renderer. Do not add
  a new artifact database or folder-as-truth model.
- CLI: prefer docs/spec clarity over aliases. Add no new command names unless
  agent usage proves the existing names are confusing.
- Speaker rename: keep the existing per-meeting label mapping. Add one
  discoverable edit affordance and make renamed labels refresh
  artifacts/Markdown/CLI exports consistently. Do not add profiles, merges,
  enrollment, attendee matching, or live diarization.

## Current State

- ADR-014 defines meeting recording as source-separated capture. Final STT uses
  the retained source files; `meeting-playback.m4a` is playback/export, not the
  authoritative STT input.
- `MeetingRecordingServiceProtocol` exposes `micLevel`, `systemLevel`,
  `captureMode`, `isMicrophoneMuted`, and `transcriptUpdates`. It does not yet
  expose a stable user-visible source health object.
- `MeetingAudioCaptureService` emits microphone/system buffers and
  `.sourceInterrupted(source:error)`. `MeetingMicHealthMonitor` detects
  `mic_missing`, `mic_silent`, and `mic_gap` for telemetry, but the monitor's
  state is not surfaced in the UI.
- `MeetingRecordingPanelView` shows a compact dual-audio orb from the two
  source levels. That gives activity, but not a readable "Mic OK / System OK /
  Missing / Muted / Interrupted" contract.
- `meeting-artifacts-v1.md` already lists `microphone-cleaned.m4a` as a stable
  optional file. As of PR #671 (merged 2026-07-03), `MeetingArtifactStore`
  already resolves the cleaned mic file via
  `MeetingCleanedMicRenderer.cleanedMicrophoneFileName`, gates it on
  `MeetingRecordingOutput.isViableCleanedMicrophoneFile` (exists and
  non-empty), and writes `manifest.files.cleanedMicrophoneAudioPath`.
  `MeetingArtifactStoreTests` pins present/absent/empty-file behavior, the
  contract doc lists the field, and `TranscriptionAssetCleanup` already treats
  cleaned mic as managed audio. The remaining artifact gap is the Markdown
  surface, not cleaned-mic plumbing.
- `MeetingArtifactStore` materializes `manifest.json`, `transcript.json`,
  `notes.md`, `prompt-results.json`, and per-result Markdown. It does not
  materialize a top-level deterministic `meeting.md` view.
- `macparakeet-cli meetings` already exposes `list`, `show`, `transcript`,
  `notes get|set|append|clear`, `results list|add`, `artifact`, and `export`.
  `SpecCommand` documents these. The gap is productizing the agent vocabulary,
  frontmatter-rich Markdown, and the cleaned-mic/artifact fields through the
  CLI contract.
- `Transcription` stores `speakers: [SpeakerInfo]?` where labels are separate
  from word-level `speakerId`. This is the right data shape for per-meeting
  rename.
- `TranscriptionViewModel.renameSpeaker(id:to:)` persists label changes through
  `TranscriptionRepository.updateSpeakers`. `TranscriptResultView` has an
  inline editable speaker overview, but the rename affordance and export/artifact
  refresh path need to be made explicit and reliable.

## Scope

### In Scope

- Per-source health model for microphone and system audio.
- Visible live recording health UI in the meeting panel, and a compact mirrored
  signal in the floating pill/tile where space allows.
- Clear "not selected" states for microphone-only and system-only source modes.
- Gentle warnings for source interruption and confirmed mic stall/silence.
- Verification that the existing cleaned-mic manifest/retention behavior
  (landed in PR #671) still matches the contract; no re-implementation.
- A stable top-level Markdown export for meetings with frontmatter.
- CLI command/spec polish for agent workflows over saved meetings.
- Speaker rename UX polish for completed transcripts with existing speaker
  labels.
- Artifact/export refresh after speaker labels or notes change.
- Focused tests and docs/contract updates for every public surface.

### Out Of Scope

- Closing AEC/source trust, LocalVQE packaging, or no-headset QA.
- Changing echo suppression or final STT routing beyond surfacing existing
  cleaned-mic artifacts.
- Live diarization or any in-meeting speaker identity UI.
- Cross-meeting speaker memory, speaker enrollment, embeddings, or biometric
  speaker recognition.
- Calendar-attendee-to-speaker matching.
- Moving canonical meeting data from SQLite into the artifact folder.
- Cloud sync, MCP, or cross-meeting Ask.

### Invariants

- The `transcriptions` row remains canonical. Artifacts are refreshed views and
  automation inputs.
- Source-separated files remain the truth: `microphone-raw.m4a`, `system-raw.m4a`, and
  optional `microphone-cleaned.m4a`; `meeting-playback.m4a` remains playback/export.
- A missing or failed health signal must never stop recording by itself.
  Recording continues unless the existing capture pipeline already fails.
- A source health warning must not imply the transcript is unrecoverable.
- Speaker rename changes display labels only. It must not rewrite raw
  `WordTimestamp.speakerId`, `diarizationSegments`, or source attribution.
- Markdown/JSON/CLI output must stay local-first and deterministic.
- JSON stdout modes must not print human status text to stdout.

## Product Requirements

### Visible Source Health

- R1. During an active meeting, the panel shows microphone and system-audio
  health as separate readable states when the selected source mode includes
  both.
- R2. In microphone-only and system-only modes, the unselected source is shown
  as "Not recorded" or omitted with no warning semantics.
- R3. Health states distinguish at least:
  - `notSelected`
  - `starting`
  - `live`
  - `muted` for user-muted microphone
  - `silent` for selected source present but currently quiet
  - `stalled` for confirmed mic-health monitor events
  - `interrupted` for source interruptions
  - `unavailable` for permission/start failures
- R4. The UI gives exact recovery guidance when there is a user action:
  microphone permission, Screen & System Audio Recording permission, source
  mode mismatch, or a source interruption.
- R5. The health surface is non-modal and must not cover live notes, transcript,
  Ask, pause, mute, or stop controls.
- R6. The existing dual-audio orb can remain as the activity visualization, but
  it must be supplemented by text/icon state so users do not have to infer
  health from motion.
- R7. Health state is derived from capture facts already available in the
  pipeline: selected source mode, source start reports, latest levels, mute
  state, source interruptions, and mic-health monitor events.
- R8. Health warnings are content-free. They do not include audio samples,
  transcript text, app names, or private meeting data in telemetry.

### Artifact Promotion

> R9–R11 are ALREADY IMPLEMENTED on main (PR #671, merged 2026-07-03) and
> pinned by `MeetingArtifactStoreTests`,
> `TranscriptionAssetCleanupCleanedMicTests`, and
> `MeetingAudioRetentionSweeperTests`. Treat them as invariants to keep
> passing, not work to do.

- R9. `manifest.files.cleanedMicrophoneAudioPath` is included when
  `microphone-cleaned.m4a` exists and is non-empty. It is `null` or omitted when
  absent.
- R10. `manifest.files` keeps raw mic/system paths when present. Cleaned mic is
  additive and never replaces the raw mic path.
- R11. Audio retention and audio-only deletion remove managed audio, including
  cleaned mic, while preserving non-audio artifact files and the artifact folder
  path.
- R12. A deterministic top-level Markdown view, `meeting.md`, is generated by
  artifact materialization and by `meetings export --format md`.
- R13. Markdown export uses YAML frontmatter for metadata and stable sections
  for notes, transcript, prompt result index, and artifact paths.
- R14. Markdown frontmatter includes only local metadata: meeting ID, title,
  created/updated timestamps, duration, status, source type, engine, artifact
  folder, manifest path, transcript path, optional notes path, optional audio
  paths, and prompt-result count.
- R15. Markdown transcript rendering includes speaker labels when the
  transcript has speaker-labeled words and the transcript text has not been
  edited in a way that makes word alignment invalid.
- R16. Artifact materialization refreshes after note writes, prompt result
  writes, meeting title edits, and speaker rename.
- R17. The artifact contract remains v1 if these fields/files are additive and
  older consumers can ignore them. Any rename/removal requires schema and CLI
  changelog treatment.

### CLI Meeting Commands

- R18. Existing CLI commands remain backward compatible.
- R19. Agent-facing spec output documents the stable saved-meeting workflow:
  list, get/show, transcript, notes update, results write-back, artifact,
  export, and spec discovery.
- R20. Do not add CLI aliases by default. First make the existing command names
  easy to discover through `spec --json`, `integrations/README.md`, and
  `Sources/CLI/CHANGELOG.md`. Reconsider aliases only after real agent usage
  shows repeated confusion.
- R21. `meetings export --format md --stdout` emits the same deterministic
  Markdown shape as `meeting.md` without writing unrelated files.
- R22. `meetings artifact --json` and envelope output include any additive
  snapshot fields needed to locate `meeting.md` and cleaned mic.
- R23. JSON failure envelopes remain machine-readable. Warnings about
  best-effort artifact refresh go to stderr.
- R24. `integrations/README.md`, `Sources/CLI/CHANGELOG.md`, and
  `SpecCommand` stay synchronized with the actual command surface.

### Speaker Rename UX

- R25. Speaker rename is available only when a transcript already has speaker
  labels. It does not start or imply live diarization.
- R26. Users can discover rename without guessing that label text is editable.
  Add one visible edit affordance next to speaker names in the speaker overview.
  Do not add turn-header controls in v1 unless the overview-only affordance
  fails real use.
- R27. Rename editing supports mouse, keyboard submit, Escape cancel, focus loss
  commit, and accessibility labels.
- R28. Empty labels are rejected without erasing the existing label.
- R29. Duplicate labels are allowed in v1. Rename is display-only, not a merge.
  Do not add duplicate prevention or merge semantics unless a concrete user
  confusion case appears.
- R30. Rename updates the current detail view, any in-memory library rows, saved
  `speakers` JSON, exports, `transcript.json`, and `meeting.md`.
- R31. Rename is per meeting only. It must not create global speaker profiles or
  link to calendar attendees.

## Proposed Data And State Shapes

### Source Health

Add a small core type rather than spreading UI string logic across the panel,
pill, and tests. Note the dictation stack already ships an analogous type,
`AudioCaptureHealth` (consumed by `DictationService`); mirror its naming and
semantics where they fit rather than inventing divergent vocabulary:

```swift
public struct MeetingSourceHealth: Sendable, Equatable {
    public enum Source: String, Sendable, Codable {
        case microphone
        case system
    }

    public enum Status: String, Sendable, Codable {
        case notSelected
        case starting
        case live
        case muted
        case silent
        case stalled
        case interrupted
        case unavailable
    }

    public var source: Source
    public var status: Status
    public var level: Float
    public var lastBufferAt: Date?
    public var detail: String?
    public var recoveryAction: RecoveryAction?
}

public struct MeetingCaptureHealthSummary: Sendable, Equatable {
    public var sourceMode: MeetingAudioSourceMode
    public var microphone: MeetingSourceHealth
    public var system: MeetingSourceHealth
    public var isDegraded: Bool
    public var primaryMessage: String?
}
```

`RecoveryAction` should be an enum with product actions the app can actually
perform, such as opening Capture settings or explaining that the selected source
mode does not record a channel. Do not store free-form recovery text as the only
contract.

### Artifact Fields

Additive fields:

- `MeetingArtifactStore.markdownFileName = "meeting.md"`
- `MeetingArtifactSnapshot.markdownPath: String?`
- `manifest.files.markdownPath`
- `manifest.files.cleanedMicrophoneAudioPath` — already exists on main (PR
  #671); listed here only so the frontmatter example below is complete.

Markdown frontmatter example:

```yaml
---
schema: com.macparakeet.meeting-markdown
schemaVersion: 1
meetingID: "11111111-2222-3333-4444-555555555555"
title: "Design Review"
createdAt: "2026-07-04T17:05:00Z"
updatedAt: "2026-07-04T18:02:00Z"
durationMs: 3421000
status: "completed"
sourceType: "meeting"
engine: "parakeet"
engineVariant: "v3"
artifactFolderPath: "/..."
manifestPath: "/.../manifest.json"
transcriptPath: "/.../transcript.json"
notesPath: "/.../notes.md"
playbackAudioPath: "/.../meeting-playback.m4a"
rawMicrophoneAudioPath: "/.../microphone-raw.m4a"
rawSystemAudioPath: "/.../system-raw.m4a"
cleanedMicrophoneAudioPath: "/.../microphone-cleaned.m4a"
promptResultCount: 2
---
```

Sections:

1. `# <title>`
2. `## Notes` when non-empty
3. `## Transcript`
4. `## Prompt Results` with local filenames/paths when present
5. `## Artifacts` with local paths when useful for support/automation

The Markdown renderer should be shared between artifact materialization and
CLI export to avoid two subtly different meeting Markdown formats.

## Implementation Units

### U0. Drift, Dependency, And Contract Check

**Goal:** Start implementation from current repo truth and avoid conflicting
with ongoing AEC/source-trust work.

**Files to read first:**

- `spec/adr/014-meeting-recording.md`
- `spec/adr/010-speaker-diarization.md`
- `spec/contracts/meeting-artifacts-v1.md`
- `spec/contracts/cli-json-v1.md`
- `plans/active/2026-06-14-meeting-mic-reliability.md`
- `plans/active/2026-05-speaker-diarization-quality.md`
- `docs/research/2026-07-04-open-source-meeting-recorder-review.md`

**Done when:**

- Implementation branch is based on a clean current base or a clearly owned
  worktree.
- Any overlap with mic-reliability Phase B is noted in the PR description.
- The PR states that AEC/source-trust and live diarization are out of scope.

### U1. Core Source-Health Model

**Goal:** Expose stable source health from the recording stack without making
the UI infer health from levels.

**Likely files:**

- `Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift`
- `Sources/MacParakeetCore/Audio/MeetingAudioCaptureService.swift`
- `Sources/MacParakeetCore/Audio/MeetingMicHealthMonitor.swift`
- new focused type near meeting recording core, for example
  `Sources/MacParakeetCore/Services/MeetingRecording/MeetingCaptureHealth.swift`

**Approach:**

- Track selected `MeetingAudioSourceMode` at start.
- Track start status for microphone and system capture from
  `MeetingAudioCaptureStartReport`.
- Update per-source `lastBufferAt` and level on buffer events.
- Convert mic-health monitor `.stallSuspected` and `.recovered` into source
  health state, not just telemetry.
- Convert `.sourceInterrupted(.system, error)` into visible `interrupted`
  state. Microphone interruption can still use the existing capture-failure
  path, but should surface a final health reason while the UI is showing error.
- Add `var captureHealth: MeetingCaptureHealthSummary { get async }` or an
  async stream if polling proves insufficient.
- Keep the health model content-free and deterministic enough for unit tests.

**Tests:**

- Add pure tests for status reduction if the reducer is separate.
- Extend `MeetingRecordingServiceTests` for:
  - microphone + system happy path
  - microphone-only not-selected system state
  - system-only not-selected microphone state
  - user-muted microphone
  - system interruption
  - confirmed mic stall and recovery

### U2. Visible Health UI

**Goal:** Make source health readable in the live meeting surfaces.

**Likely files:**

- `Sources/MacParakeetViewModels/MeetingRecordingPanelViewModel.swift`
- `Sources/MacParakeetViewModels/MeetingRecordingPillViewModel.swift`
- `Sources/MacParakeet/Views/MeetingRecording/MeetingRecordingPanelView.swift`
- `Sources/MacParakeet/Views/MeetingRecording/MeetingRecordingPillView.swift`
- `Sources/MacParakeet/Views/Transcription/MeetingRecordingTile.swift`
- new view component such as
  `Sources/MacParakeet/Views/MeetingRecording/MeetingSourceHealthChips.swift`

**Approach:**

- Add `captureHealth` to the panel view model with a sensible initial state.
- Poll or subscribe from `MeetingRecordingFlowCoordinator` alongside existing
  level/capture-mode polling.
- Render two compact health chips in the panel header for dual-source meetings:
  microphone and system.
- Keep the orb as activity, but use chips for semantics.
- On narrow widths, degrade to icons with tooltips/accessibility labels rather
  than wrapping header controls.
- Mirror a single degraded state on the floating pill, likely as a small warning
  glyph/tooltip while preserving stop/pause interactions.
- The tile can show the same degraded summary when recording is active.

**Copy guidance:**

- Good: "Mic live", "System live", "Mic muted", "System not recorded",
  "Mic may be silent", "System audio interrupted".
- Avoid: "bad", "broken", "failed to record you" unless the source is known
  to be lost.

**Tests:**

- `MeetingRecordingPanelViewModelTests` for status mapping, reset behavior, and
  non-interference with pause/mute/stop.
- `MeetingRecordingPillViewModelTests` for degraded-state mirroring.
- Add view-level tests only if existing patterns support them; otherwise rely on
  view model tests plus manual QA.

### U3. Top-Level Markdown Artifact (`meeting.md`)

**Goal:** Make the artifact folder the user/agent product surface. The
cleaned-mic manifest and retention work originally scoped here landed in PR
#671; this unit is now Markdown-only plus verification of the existing
cleaned-mic pins.

**Likely files:**

- `Sources/MacParakeetCore/Services/MeetingRecording/MeetingArtifactStore.swift`
- `Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingOutput.swift`
- `Sources/MacParakeetCore/Utilities/TranscriptionAssetCleanup.swift`
- `Sources/MacParakeetCore/Services/MeetingRecording/MeetingAudioRetentionSweeper.swift`
- `spec/contracts/meeting-artifacts-v1.md`
- `Tests/MacParakeetTests/Services/MeetingRecording/MeetingArtifactStoreTests.swift`
- `Tests/MacParakeetTests/Services/MeetingRecording/TranscriptionAssetCleanupCleanedMicTests.swift`
- `Tests/MacParakeetTests/Services/MeetingRecording/MeetingAudioRetentionSweeperTests.swift`

**Approach:**

- Do NOT touch cleaned-mic path resolution, viability gating, or
  retention/cleanup handling — all already on main and pinned by tests.
- Add shared Markdown rendering inside Core, not the CLI command file, so
  `MeetingArtifactStore` and `MeetingsCommand.ExportSubcommand` use the same
  output.
- Materialize `meeting.md` on every artifact refresh.
- Add snapshot/manifest fields for `markdownPath`.
- Update retention/cleanup tests to assert cleaned mic remains managed audio and
  non-audio Markdown/JSON remains preserved.

**Tests:**

- `MeetingArtifactStoreTests` pins:
  - `meeting.md` exists
  - snapshot `markdownPath`
  - manifest `files.markdownPath`
  - Markdown frontmatter and sections
  - existing cleaned-mic present/absent/empty pins keep passing unchanged
- Contract docs updated in the same PR.

### U4. CLI Meeting Command And Spec Promotion

**Goal:** Make saved meetings easy and deterministic for agents.

**Likely files:**

- `Sources/CLI/Commands/MeetingsCommand.swift`
- `Sources/CLI/Commands/SpecCommand.swift`
- `Tests/CLITests/MeetingsCommandTests.swift`
- `Tests/CLITests/SpecCommandTests.swift`
- `Sources/CLI/CHANGELOG.md`
- `integrations/README.md`
- `spec/contracts/cli-json-v1.md`

**Approach:**

- Replace the command-local Markdown builder with the shared Core renderer from
  U3.
- Ensure `meetings export --format md --stdout` returns the same content as
  `meeting.md`.
- Ensure `meetings export --format json --stdout` includes new additive fields
  if `MeetingRecord` grows artifact paths.
- Do not add aliases in the first implementation. Keep `meetings show`,
  `meetings notes set|append|clear`, and top-level `spec --json` as the
  canonical surface, and document them well.
- Update `SpecCommand` only for real output/field changes and documentation
  clarity.
- Keep JSON stdout clean. Any warning from artifact refresh remains stderr.

**Tests:**

- `MeetingsCommandTests`:
  - Markdown export includes frontmatter.
  - Markdown export includes notes and speaker labels when available.
  - Artifact JSON exposes `markdownPath` and cleaned mic path.
  - Alias parsing, if added.
  - Failure envelope remains valid.
- `SpecCommandTests`:
  - command paths and JSON modes are documented.
  - command read/write flags are correct.

### U5. Speaker Rename UX Polish

**Goal:** Make per-meeting speaker rename discoverable, accessible, and
consistent without adding identity features.

**Likely files:**

- `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift`
- `Sources/MacParakeet/Views/Transcription/TranscriptTimestampedContentView.swift`
- `Sources/MacParakeetViewModels/TranscriptionViewModel.swift`
- `Sources/MacParakeetCore/Database/TranscriptionRepository.swift`
- `Tests/MacParakeetTests/ViewModels/TranscriptionViewModelTests.swift`
- `Tests/MacParakeetTests/Views/SpeakerTurnIdentityTests.swift`

**Approach:**

- Add an explicit edit button next to each speaker in the speaker overview.
- Do not add turn-header rename controls in v1.
- Preserve current inline edit behavior if users already rely on it.
- Ensure Escape cancels back to the old label and focus loss commits only valid
  non-empty labels.
- Update `TranscriptionViewModel.renameSpeaker` to:
  - update `currentTranscription`
  - update the matching item in `transcriptions` if present
  - persist with `updateSpeakers`
  - trigger best-effort artifact refresh for meeting rows if repositories are
    available in that view model path, or document why refresh is handled at the
    next artifact action
- Do not add global speaker profiles or merge semantics.

**Tests:**

- Existing `TranscriptionViewModelTests` should continue to pass.
- Add cases for transcriptions array update and artifact refresh hook if wired.
- Add a focused view identity test only if renaming can change list identity or
  scroll targets.

### U6. Export/Artifact Consistency For Speaker Labels

**Goal:** A speaker rename is reflected everywhere the user or an agent reads
the meeting.

**Likely files:**

- `Sources/MacParakeetCore/TextProcessing/TranscriptSegmenter.swift`
- `Sources/MacParakeetCore/Services/MeetingRecording/MeetingArtifactStore.swift`
- `Sources/CLI/Commands/MeetingsCommand.swift`
- `Tests/MacParakeetTests/Services/TranscriptExportOptionsTests.swift`
- `Tests/CLITests/MeetingsCommandTests.swift`

**Approach:**

- Use `Transcription.hasSpeakerLabeledWords` and the `speakers` mapping to
  render speaker labels in Markdown when alignment is valid.
- If `cleanTranscript` has been edited and alignment is no longer valid, render
  the plain transcript and include a clear metadata/frontmatter flag such as
  `speakerLabelsIncluded: false`.
- Keep `transcript.json` as the richer machine-readable output with raw word
  timestamps and speaker IDs.
- Ensure CLI and artifact Markdown agree on this behavior.

**Tests:**

- Markdown before rename uses `Speaker 1`.
- Markdown after rename uses the confirmed label.
- Edited transcript does not show stale speaker labels from old word alignment.
- JSON still includes raw `speakers` mapping.

### U7. Docs, Contracts, And Release Notes

**Goal:** Keep public contracts accurate.

**Files:**

- `spec/contracts/meeting-artifacts-v1.md`
- `spec/contracts/cli-json-v1.md`
- `integrations/README.md`
- `Sources/CLI/CHANGELOG.md`
- `plans/README.md`
- `plans/active/2026-06-14-meeting-mic-reliability.md` if this work lands its
  remaining warning UI
- `plans/active/2026-05-speaker-diarization-quality.md` if speaker-label
  provenance decisions are updated

**Done when:**

- Contract docs include every additive artifact/CLI field.
- Integration docs show the canonical agent workflow.
- Active plan statuses are updated after implementation lands.

## Suggested Sequence

1. **Health core + UI first.** It directly improves trust during the meeting and
   closes the visible gap from the research review.
2. **Artifact/CLI promotion second.** Manifest and Markdown changes are
   contained and give agents a better saved-meeting contract.
3. **Speaker rename polish third.** Keep this tiny: one visible edit affordance
   plus artifact/Markdown/CLI export consistency.

These can ship as separate PRs. Do not batch them if the health state model
starts touching capture control flow.

## Verification Plan

Focused tests by slice:

```bash
swift test --filter MeetingMicHealthMonitorTests
swift test --filter MeetingRecordingServiceTests
swift test --filter MeetingRecordingPanelViewModelTests
swift test --filter MeetingRecordingPillViewModelTests
swift test --filter MeetingArtifactStoreTests
swift test --filter MeetingAudioRetentionSweeperTests
swift test --filter MeetingsCommandTests
swift test --filter SpecCommandTests
swift test --filter TranscriptionViewModelTests
swift test --filter TranscriptExportOptionsTests
```

Hygiene:

```bash
git diff --check
scripts/dev/check.sh MeetingsCommandTests
```

Manual QA:

- Start a microphone + system meeting. Confirm both source chips show live
  states and levels.
- Start microphone-only. Confirm system is not warned as missing.
- Start system-only. Confirm microphone is not warned as missing and mute
  controls are unavailable.
- Mute/unmute the microphone during a dual-source meeting. Confirm health says
  muted and recording continues.
- Simulate or force a system interruption if practical. Confirm the warning is
  non-modal and stop/finalize still works.
- Stop a meeting with notes. Confirm `manifest.json`, `transcript.json`,
  `notes.md`, `meeting.md`, and prompt-result artifacts exist.
- Add a non-empty `microphone-cleaned.m4a` fixture and materialize artifacts.
  Confirm manifest includes `cleanedMicrophoneAudioPath`.
- Run `macparakeet-cli meetings export <id> --format md --stdout` and compare
  its shape to `meeting.md`.
- Rename a speaker in a completed speaker-labeled transcript. Confirm the turn
  cards, speaker overview, Markdown export, and `transcript.json` reflect the
  label mapping.

Full `swift test` should run at most once as a final gate for the branch.

## Risk Register

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Health UI false-alarms during normal quiet listening | Users lose trust in warnings | Use source mode, system-activity confirmation, mute state, and non-modal copy. Treat silence as "quiet" before "stalled" unless the monitor confirms. |
| Health state adds capture complexity | Recording regressions | Keep health as derived state. Do not restart streams or change stop behavior in this plan. |
| Markdown export duplicates CLI logic | Drift between artifacts and CLI | Put renderer in Core and call it from both `MeetingArtifactStore` and CLI. |
| Additive artifact fields surprise consumers | Automation fragility | Keep v1-compatible additive fields only; update contract docs and tests. |
| Speaker rename is mistaken for speaker identity | Privacy/trust regression | Use per-meeting copy and avoid profiles, enrollment, attendee matching, and cross-meeting names. |
| Artifact refresh on every rename blocks UI | Jank | Use best-effort async refresh or refresh on the next artifact/export action; never block label edit commit on disk materialization. |

## Done Criteria

- [x] Live meeting UI shows separate readable mic/system health for selected
  sources.
- [x] Source health warnings are non-modal and do not stop recording.
- [x] `manifest.files.cleanedMicrophoneAudioPath` behavior (already on main via
  PR #671) is verified unchanged by this work.
- [x] `meeting.md` is materialized as a stable top-level artifact.
- [x] CLI Markdown export and artifact Markdown share the same renderer.
- [x] CLI spec/docs describe the saved-meeting workflow accurately.
- [x] Speaker rename has a visible affordance and keyboard/accessibility support.
- [x] Speaker rename updates persisted labels and exported/artifact views.
- [x] No live diarization, speaker profiles, or AEC/source-trust changes are
  introduced by this plan.
- [x] Focused tests for touched areas pass.
- [x] Contract docs and changelog entries are updated with the implementation.

## Open Questions

- Should aliases ever be added? Defer. Use the existing command names until
  agent usage shows a real discoverability problem.
- Should `meeting.md` include artifact paths by default, or keep paths only in
  frontmatter/manifest? Lean frontmatter plus a short `Artifacts` section for
  local automation.
- Should duplicate speaker display names be prevented? Defer. Allow duplicates
  because rename is not merge.
