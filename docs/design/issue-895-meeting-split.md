# Native Split and transcribe (issue #895)

Governing contract: `spec/contracts/meeting-splitting.md`. This note is a
short index of the implementation in progress and its design; it does not restate the
contract's normative rules.

## What exists

- **Core/CLI** (prior work): `MeetingSplitService`, `MeetingSplitRepository`,
  the audio exporter/geometry/leases, and `meetings split
  preview|create|status|resume|discard`.
- **Native ViewModel**: `MeetingSplitViewModel`
  (`Sources/MacParakeetViewModels/MeetingSplitViewModel.swift`). One shared,
  app-owned instance (created in `AppDelegate`, `configure(service:)`d in
  `setupEnvironment`) so a running batch survives the sheet closing and is
  visible from every entry point.
- **Native sheet**: `MeetingSplitSheetView`
  (`Sources/MacParakeet/Views/Meetings/MeetingSplitSheetView.swift`).
  Uses standard playback controls, editable minute/second or hour/minute/second
  cut times, and titles for each part. Incomplete time input stays visible and
  disables creation. Two parts are the default; adding a split divides the
  longest current part without moving existing boundaries.
  Published parts appear before transcription finishes, with an Open action.
  Closing the sheet leaves the app-owned task running; Stop processing preserves
  saved recordings. Continue processing uses the same receipt and child IDs.
- **Entry points**: `TranscriptResultView`'s action bar, and row menus in
  `TranscriptionLibraryView` and `MeetingsView`, each gated by
  `MeetingSplitEligibility.isEligible(_:)`
  (`Sources/MacParakeetCore/Services/MeetingSplit/MeetingSplitEligibility.swift`).
- **Startup reconciliation**: `MeetingFinalizationReconciler` branches on
  `Transcription.splitProvenance` to
  `MeetingSplitOperationLeaseReconciliationCoordinator`
  (`Sources/MacParakeet/App/MeetingSplitFinalizationReconciliationCoordinator.swift`)
  instead of the capture-lock-only path.
- **Combined deletion migration**: `TranscriptionLibraryViewModel.deleteTranscription`/
  `deleteTargets`, `TranscriptionViewModel.deleteTranscription`, and
  `SettingsViewModel.clearMeetingAudio` now call
  `TranscriptionAssetCleanup.deleteTranscription`/`clearManagedMeetingAudio`
  (one media lease covering both the file removal and the row mutation)
  instead of two separately-locked steps.
- **Truthful progress**: `MeetingSplitService.processAll` reports every real
  stage transition per child, not one stale snapshot at loop entry.

## Deliberately not built

- A waveform editor, autodetection, transcript partitioner, or a four-part
  limit — the contract rules these out explicitly.
- An elaborate split operation-history UI.
- A second queue or processing framework. A child's "View split progress…"
  action opens its existing batch; "Split and Transcribe…" means a new split
  of that recording. These actions must remain distinct.

## Verification status

The lifecycle/recovery milestone is committed as `93efade8`: 729 focused tests,
one skipped, zero failures. Native sheet/navigation is committed as `9a6ff3d4`.
Retry receipt visibility and switching to an unavailable source have explicit
red-to-green regressions; the latest ViewModel gate passed 18 tests and compiled
the app. These are historical milestones. The signed Xcode dev bundle built
and launched against the isolated fixture; the initial macOS Accessibility
denial was resolved, and interactive sheet and cancellation/retry QA completed
as described below. Subsequent focused Core/CLI gates and a real saved-audio
pipeline run are recorded in the [implementation plan](../plans/2026-09-11-issue-895-meeting-split-plan.md).
This evidence does not establish speech-model accuracy, merge, or release status.

A three-lens simplification pass found no reusable equivalent for the precise
time parser or the small entry-point wiring. It removed a redundant operation-ID
field. Authoritative receipt refreshes remain deliberately simple; optimizing
them into a separate progress cache is not justified for two or three parts.

### Native fixture observations

With Accessibility enabled, the signed app at `74719dbf` opened the split sheet
from the fixture's transcript detail. Manual invalid `0:` input remained visible,
disabled creation, and showed a validation error. Add split produced three parts
without moving the existing boundary. Visual inspection caught a wrapping label
and duplicate untouched default titles; the label now reads "Split at", and
default title numbers follow their positions while custom titles stay unchanged.
The default-title regression failed before the fix; 19 ViewModel tests then passed.

The actual native action saved three independent audio paths with 30-, 15-, and
45-second ranges. The original audio and metadata SHA-256 hashes remained
unchanged. The sheet showed "Recordings saved" while part 1 was transcribing;
closing and reopening retained the same operation and active task.

Stop initially remained in "Stopping" with part 1 active and later parts pending.
A process sample showed CoreML waiting in an Apple Neural Engine model-load call.
After several minutes, all three parts became cancelled and ready to continue.
An ordinary relaunch and Continue reused the same operation and child identities;
all three parts reached Done, and CLI status agreed with four recordings still
present. The existing STT scheduler waits for active runtime work to drain: retain
audio ownership until it returns and do not promise instantaneous cancellation.
This verifies cancellation/retry through the real pipeline, not recognition
accuracy on the synthetic audio. No new processing framework masks the wait.

The earlier HTML is a reference only. Native layout follows the existing app's
type, spacing, colors, and action styles; no custom waveform editor is needed.

## Host QA fixture

`Tests/MacParakeetTests/QA/SplitAndTranscribeFixtureSeedTests.swift` is an
opt-in, DEBUG-only XCTest that seeds a synthetic (silent-tone) meeting
recording with a real transcript into a **fresh temporary** app-state root —
it refuses to run against an existing directory or one outside the system
temp root. To inspect the native flow in the real app without personal data:

```sh
FIXTURE_DIR="$(mktemp -d)/macparakeet-895-fixture"
MACPARAKEET_DEBUG_APP_STATE_DIR="$FIXTURE_DIR" swift test --filter SplitAndTranscribeFixtureSeedTests
MACPARAKEET_DEBUG_APP_STATE_DIR="$FIXTURE_DIR" scripts/dev/run_app.sh
```

Then open Library, select the seeded "Weekly sync — Split QA fixture"
meeting, and use "Split and Transcribe…" from the action bar or row menu.
