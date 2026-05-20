# Nab Feedback: ASAP Bugs and Blocker Issues

> Status: **ACTIVE PLAN**
> Date: 2026-05-14
> Source: live user feedback from Nab using meeting recording in daily meetings.
> Scope: defects and near-term blocker issues only. Product polish and wishlist items are intentionally excluded.

## Priority Order

### P0: Meeting recording degrades the user's live microphone audio in Zoom

**Verification status:** high-confidence defect. Live user report + local
diagnostic logs line up. Raw-mode mitigation is implemented in the current
working tree and covered by focused/full Swift tests. The remaining acceptance
check is a real two-party Zoom/Meet call after launching this build.

When MacParakeet meeting recording starts, the user's voice heard by the other
Zoom participant becomes much quieter/muffled. Pausing or stopping the
recording restores the voice. This was observed in both directions during the
call: Daniel's voice dropped when Daniel started recording, and Nab's voice
dropped when Nab started recording.

This is the first fix because it harms meeting participants, not just the
local recording quality. Users may not notice the regression themselves while
everyone else hears it.

Pre-fix likely suspect: meeting mic capture defaulted to
`MeetingMicProcessingMode.vpioPreferred` in `AppEnvironment`, and the production
engine enables `AVAudioInputNode.setVoiceProcessingEnabled(true)` when VPIO is
engaged. `MicrophoneEnginePlatform` already suppresses VPIO "other audio"
ducking, but this report suggests VPIO/voice processing may still affect the
active conferencing app's mic path on real Zoom calls.

Why VPIO exists:

- It was introduced for a valid transcript-quality problem: when users play a
  meeting over speakers, remote speech leaks into the mic and appears as
  phantom/garbled "Me" segments.
- The original raw + software-AEC path was replaced because it did not cleanly
  separate mic/system audio. VPIO gave stronger macOS-native AEC, NS, and AGC.
- Core Audio process taps did not coexist with VPIO, so system audio capture was
  later moved to ScreenCaptureKit to let the meeting mic keep VPIO.
- The shared mic engine was then added because VPIO is process-scoped: once it
  engages, sibling mic engines see the VPAU multi-channel layout. Shared capture
  plus channel-0 extraction fixed dictation-during-meeting and other in-process
  regressions.

What was tested:

- Existing tests cover VPIO plumbing, fallback, `vpioRequired`, shared-stream
  arbitration, channel-0 extraction, and real-platform buffer delivery when a
  late non-VPIO subscriber joins an active VPIO stream.
- The completed shared-mic plan records a one-day meeting smoke and a real
  concurrent-flow soak where dictation during meeting produced non-empty
  transcripts.
- These tests do **not** cover the external multi-app interaction where Zoom
  and MacParakeet use the same physical mic and Zoom participants judge the
  outgoing voice quality.

External reference check:

- Current Char/Anarlog source (`fastrepl/anarlog` commit
  `3ead9bd78a97ea1e2c555ee60f243d97716332d4`) does not show VPIO,
  `setVoiceProcessingEnabled`, `VoiceProcessingIO`, `AVAudioEngine`, or
  `AVAudioInputNode` usage.
- Their live dual-source path opens raw mic capture through CPAL, opens speaker
  capture through a Core Audio process tap, joins mic/speaker chunks, and runs a
  software `hypr-aec` ONNX echo canceller by default (`NO_AEC=1` disables it).
- Downstream transcript audio prefers `aec_mic` when present and falls back to
  raw mic otherwise. That is the design we should prefer after the hotfix:
  call-safe raw capture first, then software/post-capture AEC for transcript
  quality.

Implemented fix:

- Changed the shipped app default from `.vpioPreferred` to `.raw` as the ASAP
  mitigation. The lower-level `MeetingAudioCaptureService`,
  `MeetingRecordingService`, and `MicrophoneCapture` defaults already default to
  `.raw`; the production override was in `AppEnvironment`.
- Keep the VPIO/shared-mic implementation in place as explicit opt-in plumbing
  and for future experiments; do not delete it as part of the hotfix.
- Updated the specs/ADR text that said VPIO was the shipped default.
- Keep transcript-layer system-dominance suppression as the raw-mode safety net.
- Revisit AEC later with a call-safe strategy: post-processing, software
  suppression/AEC, or an opt-in advanced "mic cleanup" mode after real Zoom
  validation.
- Removing VPIO can reintroduce speaker-bleed / phantom "Me" transcript risk,
  so the raw-mode hotfix should be followed by a software-AEC replacement rather
  than treated as the final audio-quality architecture.

Evidence from the call-time log:

- At 2026-05-14 15:19:25 PDT, meeting recording started with
  `requested_mic_mode=vpioPreferred effective_mic_mode=vpio`.
- The active mic format was `sr=48000 ch=9`, which is the expected VPIO duplex
  layout, not the raw one-channel dictation layout.
- The same VPIO pattern appears for the adjacent demo recordings at
  15:00-15:18 PDT and 15:24-15:25 PDT.

Immediate acceptance criteria:

- Starting and stopping MacParakeet meeting recording must not audibly change
  how the user's voice sounds to another Zoom participant.
- The fix must be validated with a real two-party call, not only unit tests.
- Diagnostics should make the effective mic mode visible:
  requested mode, effective mode, and whether VPIO was engaged.

Implementation notes:

- The app-level default is currently a single production override in
  `Sources/MacParakeet/App/AppEnvironment.swift`.
- A focused verification run passed while investigating:
  `swift test --filter 'MicrophoneCaptureTests|SharedMicrophoneStreamTests|MeetingAudioCaptureServiceTests'`
  (55 tests, 0 failures).
- Add or update tests so explicit VPIO behavior remains covered while shipped
  app wiring requests raw mic by default.

Likely first mitigation:

- Ship a kill-switch patch that defaults meeting mic capture to `.raw`.
- Keep system-audio capture and recording functional.
- Revisit AEC as a follow-up only once it can be enabled without degrading the
  live call.

Useful code pointers:

- `Sources/MacParakeet/App/AppEnvironment.swift`
- `Sources/MacParakeetCore/Audio/MicrophoneEnginePlatform.swift`
- `Sources/MacParakeetCore/Audio/SharedMicrophoneStream.swift`
- `Sources/MacParakeetCore/Audio/MicrophoneCapture.swift`
- `Sources/MacParakeetCore/Audio/MeetingAudioCaptureService.swift`

### P1: AI setup is too hidden for meeting summaries/action items

**Verification status:** confirmed UX blocker. Not a backend defect.

Nab did not realize that Settings -> AI enabled meeting summaries, chat, and
custom prompt results. This blocks users from discovering the workflow that
already solves their stated need.

Code evidence:

- `TranscriptResultView` only shows the `+` generate tab when
  `promptResultsViewModel.hasPromptResultGenerationCapability` is true. With
  no saved AI config, the result-generation affordance disappears rather than
  explaining setup.
- The Chat tab has a `Turn on AI for summaries and chat` banner, but it has no
  action button and does not deep-link to Settings -> AI.
- This overlaps directly with `plans/active/2026-05-ai-setup-ux.md`; fix there
  instead of starting a parallel design track.

Acceptance criteria:

- When a user opens a transcript/meeting result without AI configured, the
  summary/result/chat surfaces show a compact "Set up AI" empty state.
- The empty state explains that transcription still works locally without AI.
- The action opens Settings directly to the AI section.

Existing plan:

- `plans/active/2026-05-ai-setup-ux.md`

2026-05-16 refinement:

- Chat and Live Ask already had `Set up AI` CTAs that route to Settings -> AI.
- Prompt-result generation was the remaining hidden surface: the `+` tab only
  rendered when an LLM service existed, so users without AI configured could not
  discover summaries, action items, or custom prompt results from the result
  screen.
- The result screen now always shows the `+` affordance. With AI configured it
  opens the existing generation popover. Without AI configured it opens a
  compact setup popover with a `Set up AI` action. Transcription remains
  available without AI.

### P1: Short meeting/demo auto-run silently skips below 500 chars

**Verification status:** confirmed as threshold/UX behavior. The current working
tree removes the arbitrary length gate and keeps only an empty/whitespace
transcript guard.

During the demo, a custom prompt was configured for auto-run, but ending a very
short meeting recording did not automatically generate the result. Manual
generation still worked.

Investigation result:

- `TranscriptionViewModel.presentCompletedTranscription(... runAutoPrompts:
  true)` is called from meeting completion and routes to
  `PromptResultsViewModel.autoGeneratePromptResults`.
- `autoGeneratePromptResults` returns early unless transcript text is more than
  500 characters.
- Targeted tests pass:
  `swift test --filter 'PromptResultsViewModelTests|TranscriptionViewModelTests/testFreshTranscribeStillFiresAutoRunPrompts'`
- Local DB metadata from the call-time recordings matches the code path:
  a 358-character meeting has 0 prompt results, while 1,606-character and
  9,695-character meetings each have 4 prompt results.

So the pipeline works for normal-length meetings. The issue is that short
meetings/demos fail silently, which makes the feature look broken.

Implemented fix:

- Removed the arbitrary 500-character threshold rather than adding a tooltip.
- Keep a guard for empty / whitespace-only transcripts so silence does not
  generate low-value AI artifacts.
- Rationale: short meetings can be highly meaningful, especially abrupt
  meetings with one or two action items. Token usage is low for short
  transcripts, and silently skipping auto-run creates a worse user experience
  than generating a small summary/action-item result.

Acceptance criteria:

- Auto-run prompts run for any non-empty transcript, including very short
  meeting recordings and demos.
- Empty / whitespace-only transcripts still do not auto-run.
- Preserve duplicate-prevention behavior for retranscribe.
- Existing file/YouTube auto-run behavior does not regress, except that short
  non-empty files/URLs now follow the same auto-run rule.
- Update `spec/12-processing-layer.md` to remove the stale
  `transcript.count > 500` condition.
- Replace the existing short-transcript skip test with coverage for both
  "short non-empty transcript runs" and "blank transcript skips".

Useful code/test pointers:

- `Sources/MacParakeetViewModels/PromptResultsViewModel.swift`
- `Sources/MacParakeetViewModels/TranscriptionViewModel.swift`
- `Tests/MacParakeetTests/ViewModels/PromptResultsViewModelTests.swift`
- `Tests/MacParakeetTests/ViewModels/TranscriptionViewModelTests.swift`

### P2: Provider/model settings can appear changed before they are saved

**Verification status:** confirmed UX ambiguity.

During the demo, switching Gemini Pro to Gemini Flash did not take effect until
the setting was saved. That may be intended, but the UI made it easy to assume
the new model was active.

Code evidence:

- `LLMSettingsViewModel` edits a draft.
- `testConnection()` tests the draft, so a user can validate an unsaved model.
- Runtime AI services still use the saved config until `saveConfiguration()`
  calls `LLMConfigStore.saveConfig`.
- The result-screen model selector is different: `PromptResultsViewModel.selectModel`
  persists immediately via `updateModelName`.

Acceptance criteria:

- Either model changes autosave, or the UI clearly shows unsaved changes.
- Running an AI action should use the model visibly selected as active.
- The status/test affordance should confirm the currently saved provider and
  model.

### Watchlist: Whisper engine/model switching may hang or take too long

**Verification status:** not confirmed in code or tests. Keep as manual-repro
watch item, not an ASAP fix yet.

Switching to Whisper appeared slow or stuck during the demo. This needs a
repro before changing behavior.

Code/test evidence:

- `SettingsViewModel.applySpeechEngineChange` clears `speechEngineSwitching` in
  a `defer`, so the picker should not stay disabled indefinitely after the
  task exits.
- `STTScheduler.setSpeechEngine` rejects switching while jobs are queued/running
  or while an active meeting speech-engine lease exists.
- Targeted tests pass:
  `swift test --filter 'SettingsViewModelTests/testSpeechEngineChange|SettingsViewModelTests/testRefreshModelStatusMarksActiveWhisperReady|STTSchedulerTests.*SpeechEngine|STTSchedulerTests.*speechEngine|STTSchedulerTests.*Session'`

Acceptance criteria:

- Engine/model/language switching reports progress or a clear blocked state.
- If an active meeting recording holds an STT lease, the UI should say the
  switch is unavailable until recording ends.
- Switching should not leave the app in a "switching" state indefinitely.

## Explicitly Out of Scope

- Adding a meeting recording button to the dictation island. The app already
  has a menu-bar command and configurable meeting hotkey; this is
  discoverability/product polish, not an ASAP bug.
- Per-context cleanup prompts for meetings vs dictation.
- Prompt list click-to-run UI polish.
- Marketing/docs/videos.
