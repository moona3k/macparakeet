# Interaction and integration release review

Reviewed `v0.8.10..bb1ebcc37974bfb363f2bec46250bc0532009f17` in the isolated
release-review worktree, followed by the pending CLI 5.2.0 metadata promotion.
This review made no application changes and ran no builds or Swift tests. The
parent release review owns executable verification.

## Result

No confirmed behavioral regression found in the reviewed interaction changes.
Source review is not native hardware or packaged-release acceptance.

## Coverage

- **Keyboard output and hotkeys:** traced generated-event marking before
  swallowing/gesture bookkeeping, session-level output posting, separate HID
  and session key-state providers, copy/paste shortcut layout resolution,
  streaming interruption replay, failed flush handling, and cancellation.
- **Dictation URLs:** checked parser grammar, independent opt-in, consent at
  receipt and dispatch, bounded launch buffering, startup failure, protected
  busy states, coordinator dispatch, and onboarding/quit exclusion against
  `spec/contracts/dictation-url-control-v1.md`.
- **Dictation sounds:** checked prepared-player ownership, preview isolation,
  import/reset and restore races, generation guards, cancellation cleanup,
  selected/system playback fallback, mute and silence, preference migration,
  and resource resolution.
- **Vocabulary:** checked literal replacement boundaries, meeting token
  fast-path fallback for punctuation-bearing literals, failed-load mutation
  guards, selection/deletion state, export operation ownership, and management
  visibility in Raw/Clean modes.
- **Settings:** reviewed adaptive header/microphone layout, search catalog
  destinations and feature visibility, new URL/sound controls, and shared
  view-model ownership.

## Resource and release integration checks

The four committed Bloom/Gong WAV files each match the SHA-256, stereo 48 kHz
24-bit PCM format, and exact duration in
`docs/assets/dictation-sounds/manifest.json`. A Python standard-library
`hashlib`/`wave` check passed for all four. They are the only WAV files in the
app resource tree. The manifest identifies the original offline generator;
`docs/dictation-sound-design.md` explicitly contributes the sounds and generator
under the repository license. No Handy audio resources remain in that tree.
This is a source/provenance consistency check, not an independent legal opinion
or a rerun of numerical synthesis.

`Package.swift` processes the app Resources directory. The distribution script
builds the GUI in Xcode Release with macro validation skipped and copies the
generated resource bundles into the application. The controller first resolves
its assets through `Bundle.module`, with a main-bundle fallback. No missing
source asset or resource-name mismatch was found. A relocated, signed app still
needs its own playback check.

Ask, Voice Control, voice profiles, and encrypted share links remain disabled;
their developer launch overrides are DEBUG-only. In-process MLX remains disabled
and requires both explicit developer visibility and a separately built runtime.
Meeting reminders intentionally ship as an opt-in Beta surface in Release, with
an explicit Record action required. The pending spec describes that distinction.

The pending CLI 5.2.0 constant and changelog heading agree and preserve the
published/source distinction. An additive `activity_detection` trigger value
justifies a minor version promotion. The Homebrew scaffold correctly continues
to name the published 5.1.0 artifact. One documentation follow-up was sent to the
parent: `integrations/capabilities.md` still described the correction fix as
listed under Unreleased. The parent updated it to prepared CLI 5.2.0.

## Independent review of release-review fixes

This follow-up reviewed the pending fixes subsequently committed as `ee3f9b87e`, relative to `bb1ebcc37974bfb363f2bec46250bc0532009f17`. It does not cover the later no-mistakes follow-up in `d66cfae0f`; the parent audit and fresh-review reports record that later verification.

The final source pass reviewed the pending retained-YouTube-audio restoration,
post-persistence cancellation, and corrupt-lock capture reconstruction fixes.
No blocking finding remains in those changes.

- Hide Video now restores the selected transcription's playable retained audio
  after a direct video load, or uses the existing legacy-audio conversion path.
  Missing audio keeps the existing deferred-video behavior. Navigation calls
  `cleanup()` before loading a different transcription, so a previous row's
  player does not bypass restoration in the current UI path.
- A conversion cancelled during asynchronous persistence can no longer replace
  the current transcription's player after persistence returns. The new test
  explicitly suspends persistence, navigates, then releases the old operation.
- Corrupt/empty-lock capture reconstruction uses the same read-only fallback as
  finalization admission. Queue admission still claims ownership under the
  existing mutex before playback preparation or derived writes. Settlement
  verifies the completed row's artifact-folder ownership, so independent
  fallback session UUIDs do not block it.

This pass also found an adjacent pre-existing stale-duration race: a player
could pass its identity check, suspend on asset duration loading, and overwrite
the next player's duration after navigation. The parent fixed it by applying
the result through `applyLoadedDuration(_:for:)`, which rechecks player identity
at the commit point. The focused behavior test covers stale/current players,
indefinite duration, and late results after cleanup. The final implementation
and test were reviewed without further findings. The test validates result
application; it does not reproduce AVFoundation's asynchronous timing itself.

The parent reported that the original implementations failed the new main
regression tests before the fixes were restored. This reviewer did not run or
independently inspect those executions; the parent audit owns that evidence and
the focused/full-suite results.

## Remaining verification

Focused executable coverage includes `SyntheticPasteHotkeyTests`,
`AppGeneratedKeyboardEventsTests`, `StreamingCursorInserterTests`,
`DictationURLCommandTests`, `DictationFlowCoordinatorTests`, dictation sound
tests, `CustomWordReplacerTests`, `TextProcessingPipelineTests`,
`MeetingTranscriptVocabularyApplierTests`, `CustomWordsViewModelTests`,
`VocabularyBackupViewModelTests`, `SettingsSearchIndexTests`,
`SettingsCaptureLayoutTests`, and `CLIVersionTests`.

Native acceptance should cover physical Fn/custom shortcuts after repeated
pastes, typing/click interruption during streaming, Jump Desktop, background
URL delivery with target focus, imported-sound relaunch persistence, rapid cue
transitions on real audio devices, and Settings resizing while search retains
focus. None of those outcomes is established by this source review.
