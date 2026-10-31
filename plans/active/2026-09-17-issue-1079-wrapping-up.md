# Fix issue 1079 — Transcribe tile stuck on Wrapping up

**Status:** IMPLEMENTED ON MAIN — reconciled 2026-10-31; #1082 merged as
`fb186349e`, present in reviewed main `79cf1ca92`. Coordinator fallback and
hidden-stop regressions remain implemented. The original audit and execution
notes below are historical; later saved-capture finalization/recovery is tracked
in [the #1291 plan](2026-10-30-1291-capture-finalization.md).
**Issue:** [#1079](https://github.com/moona3k/macparakeet/issues/1079)
**Audit:** [`docs/audits/2026-09-17-issue-1079-wrapping-up.md`](../../docs/audits/2026-09-17-issue-1079-wrapping-up.md)
**Base:** `origin/main`

## Context zone

- **In scope:** Unstick `MeetingRecordingPillViewModel` from `.completing` when
  the floating pill is hidden or its collapse callback never fires. Keep the
  visible-pill flourish. Add a coordinator regression test.
- **Must not change:** Capture/mix/queue/finalize; back-to-back idle-on-queue;
  error/cancel teardown; Start/Stop tile actions.
- **Out of scope:** Speeding mix for long meetings; changing “Wrapping up…” /
  “Transcribing…” copy; making the tile play the flower collapse itself.

## Implementation

In `MeetingRecordingFlowCoordinator.showTranscribingState`:

- Visible pill: `.completing` + existing animation callback + 1.2 s fallback.
- Hidden / absent pill: skip `.completing`, enter `.transcribing` and start the
  Metatron minimum-display timer so `.showSavedCompletion` can resolve.

Cancel the fallback from `cancelSavedCompletion` / teardown.

## Verify

```bash
swift test --filter MeetingRecordingFlowCoordinatorTests
swift test --filter MeetingRecordingFlowStateMachineTests
swift test --filter MeetingRecordingTileTests
swift test --filter MeetingRecordingPillViewModelTests
```

Expect: stop with `shouldShowFloatingMeetingPill == false` leaves
`.completing` and later returns the shared pill VM to `.idle`.
