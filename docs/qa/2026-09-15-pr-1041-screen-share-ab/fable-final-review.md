# Claude Fable 5.1 final source review

This medium-effort review ran against source head `8e6ebb957dd9` after the
implementation and test fixes. The text below preserves the reviewer's final
assessment.

The source review finished before the runtime A/B. The companion
[benchmark report](README.md) closes its screen-sharing test gap; the review's
original scope statement remains below.

## Verdict

**LGTM.** No actionable, PR-introduced defects found. Confidence is high for the recording, warm-up, provenance, preference, and panel-copy paths, which I traced end to end in source. This was a source review only. I ran no builds or tests, and real hardware screen-sharing behavior remains unexercised, as noted in the task context.

## What I verified

- **Preference captured once per recording.** The service reads the closure inside `startRecording` at `Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift:658`, immediately after lease acquisition, and stores the result in the immutable session plan. Nothing else reads the closure, so a mid-recording toggle cannot affect the active session. The two-direction test in the service test file covers both flip orders.
- **Lease acquisition does not warm a model.** The scheduler's session begin at `STTScheduler.swift:490-514` reserves an ID, drains an in-flight switch, and reads selection plus capabilities. The runtime's capability read is a pure registry lookup at `STTRuntime.swift:2492-2494`. The new service test asserts one active lease with zero routed selections.
- **Off suppresses all live work.** Live transcriber session start is gated on the plan preview at `MeetingRecordingService.swift:718`. Chunk submission is gated on `supportsLiveChunkTranscription` at line 1708, which is derived from the same plan. Audio capture, writer, lock file, and finalization are unchanged and run regardless.
- **Coordinator warm-up guard.** Warm-up observation starts only when a preview selection exists at `MeetingRecordingFlowCoordinator.swift:757-763`. The readiness check short-circuits to true without touching the STT manager when preview is nil. The only other app pre-warm is the launch-time deferred warm-up in `AppDelegate.swift`, which is unrelated to meeting start and not in scope.
- **Provenance.** Lock files and metadata write the plan's final selection, and `previewSpeechEngine` is nil when preview is off. The contract doc now states nil preview provenance is valid when disabled. Final transcription in `TranscriptionService.swift` never references preview provenance or live text, so the no-preview path is the same one Cohere already exercised.
- **Panel status state machine.** The panel view model is created before start, so the off status is always applied. The post-start switch and the warm-up handler both treat the off status as terminal, and the only path that overrides it is a non-empty preview line update, which cannot happen without chunks. Route attribution collapses to nil when live equals final, and to a final-only sentence when they differ.
- **Settings.** The toggle persists to the shared key, reloads on view model init, emits telemetry, and is indexed for search under the meeting card anchor, so it inherits the meeting feature-flag gating automatically. The UI uses the existing toggle row component, so no button-style or tint concerns apply.
- **Docs.** STT README, ADR-014, the artifacts contract, UI patterns, and the features table are all updated. The `ADR-014 §9` link resolves to the existing "Speech engine captured at recording start" section.
- **Concurrency.** The new closure is `@Sendable`, captured from a `Sendable` protocol value, and invoked from within the actor. No new MainActor work or cross-isolation hazards were introduced.

## Optional, non-blocking observations

- The empty-state detail for the off status reads "Audio will be transcribed after you stop recording." The panel is hidden when stop begins, so the stale tense is not user-visible in practice.
- The CLI `config` command exposes other meeting preferences but not this one. The CLI does not record meetings, so exposing it would have no effect. Not needed for this PR.

## Files inspected

Full PR diff; `MeetingRecordingService.swift` (session struct, `startRecording`, `configureLiveChunkers`, chunk gating); `MeetingRecordingFlowCoordinator.swift` (pill/panel setup, start success path, stop path, warm-up observation and handler, initial status refresh); `MeetingRecordingPanelViewModel.swift` (status enum, routing attribution, empty-state and status copy, preview update); `MeetingRecordingPanelView.swift` empty-state rendering; `STTScheduler.swift` lease begin; `STTRuntime.swift` capability lookup; `TranscriptionService.swift` prepare and finalize; `SettingsView.swift` toggle placement; `SettingsSearchIndex.swift` gating; `AppRuntimePreferences.swift`; `AppEnvironment.swift` wiring; `ConfigCommand.swift` key list; ADR-014 section headings; all changed test files as shown in the diff.

## Gaps

I did not read the `MeetingRecordingServiceSpy`, `LeasingMeetingSTTClient`, or `MockSTTClient` test doubles, so I am relying on the passing CI runs for the correctness of the test harnesses themselves. I did not inspect the pause and resume path in detail; it does not reference the preview plan, and it already handled Cohere's no-preview sessions before this PR.
