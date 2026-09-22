# Bounded Capture Lifecycle

**Status:** SHIPPED AS #814 — archived 2026-07-16
**Priority:** P1 reliability
**Branch:** `fix/bounded-capture-lifecycle`
**Baseline:** `origin/main` at `d97720362575f155e17e826d39fc161dfe0fa33a`

## 1. Decision

Ship a narrow meeting-capture lifecycle-hardening change for startup and
teardown.

The change is worthwhile independently of issue #808. That report establishes
the user-visible symptom (a meeting continued after Stop), but it does not prove
which await stalled. The live code nevertheless has two concrete defects:

1. `SystemAudioStream` bridges `SCStream.startCapture` and
   `SCStream.stopCapture` with checked continuations that have no deadline. A
   missing framework callback can suspend the caller forever.
2. Meeting Stop can arrive while capture startup is suspended, but the current
   transition waits for startup to report success before teardown can begin.
   Meeting capture also tracks only `isCapturing`, so `stop()` is a no-op while
   a microphone or system-audio source is partially started.

We should continue to `await` ordered teardown. The fix is to make that await
bounded and interruption-aware, not to replace it with a fire-and-forget Task.

## 2. Must-not-change invariants

- Stop never starts capture.
- Meeting Stop means **save/finalize**, including when requested during startup;
  Cancel remains the only user action that intentionally discards artifacts.
- A failed meeting start may delete its unusable session folder, as allowed by
  `spec/contracts/meeting-recovery-retention.md`; a durable Stop owns the
  session once it begins and the stale start task must not delete or overwrite
  that outcome.
- Late ScreenCaptureKit callbacks cannot resume a continuation twice or revive
  a stopped stream.
- Dictation and meeting state machines stay separate (ADR-015). This is shared
  lifecycle policy, not a combined mega-state-machine.
- No new telemetry event or reporter fingerprinting. Add sanitized local
  diagnostics and reuse existing typed failure telemetry.
- Long meeting finalization (writer drain, mixing, STT queueing) is not given an
  arbitrary wall-clock cutoff. Only platform capture lifecycle waits and
  startup intent are bounded here.
- Dictation behavior is unchanged in this PR. Its pending-Stop state is
  structurally similar, but it does not use ScreenCaptureKit, already has a
  first-buffer watchdog and late-subscription rejection, and has no matching
  field report. A dictation startup deadline needs its own evidence and PR.

## 3. Verified current behavior

- `SystemAudioStream.startCapture(_:)` and `stopCapture(_:)` await completion
  handlers with no timeout or late-callback gate.
- `SystemAudioStream.beginStop()` clears local state before awaiting
  `SCStream.stopCapture`, so a bounded stop can safely leave the app-side stream
  idle even if ScreenCaptureKit reports completion late.
- `MeetingAudioCaptureService.start` starts microphone then system audio, but
  stores `systemAudioCapture` and sets `isCapturing` only after both complete.
  Its `stop()` returns immediately while startup is in flight.
- `MeetingRecordingFlowStateMachine` moves `.starting -> .stopping` on Stop but
  emits no effect until `.recordingStarted` arrives.
- `MeetingRecordingService` creates the writer and lock before capture starts,
  then unconditionally runs failed-start cleanup from the start task's catch.
  A durable stop racing that stale catch therefore needs explicit ownership.
- `DictationFlowStateMachine` moves `.startingService -> .pendingStop` and waits
  for `.recordingStarted`. `AudioRecorder` already bounds first-buffer delivery
  at two seconds and rejects a late subscription after stop/cancel. The shared
  microphone subscription await itself has no deadline, but changing that flow
  is explicitly deferred from this meeting-focused PR.
- Quit waits for the meeting flow to settle. Fixing the capture stop boundary
  removes the known unbounded ScreenCaptureKit leg; a separate user-facing
  “Quit now / keep waiting” policy is intentionally not bundled into this PR.

## 4. Implementation plan

### Slice A — callback boundary (test first)

1. Add a small internal, lock-protected one-shot callback waiter with an
   injectable timeout. It must support success, framework error, timeout,
   explicit cancellation, and exactly-once caller completion.
2. Put ScreenCaptureKit start/stop behind a minimal lifecycle-session protocol
   so fake callback behavior is testable without a real screen recording.
3. Bound the whole `SystemAudioStream.start` attempt, including
   `SCShareableContent.current`, rather than only the `startCapture` callback.
   The underlying operation may outlive caller timeout if the framework ignores
   cancellation, so every post-await step must re-check attempt ownership.
4. Use the waiter for `SCStream.startCapture` and `SCStream.stopCapture`.
   Store/cancel the pending start waiter as part of `SystemAudioStream` state.
   A late start success after timeout/cancellation must issue another
   non-blocking stop request after output removal; it must not merely be
   ignored.
5. While stopping, reject replacement starts until old outputs are removed and
   the bounded stop settles. Then publish local idle, release ownership, emit a
   sanitized `system_audio_stream_stop_timeout` diagnostic on timeout, and
   return.
   On start timeout/cancellation, run the same bounded teardown path and throw.

Default policy to validate in review: 10 seconds for start completion and
5 seconds for stop completion. Both values are injectable in tests. They are
deadlock guards, not expected-path latency targets.

### Slice B — meeting Stop during startup (atomic, test first)

1. Replace `MeetingAudioCaptureService`'s boolean-only ownership with an
   attempt generation plus `idle/starting/running` state. Store the created
   system source before awaits; re-check ownership after each suspension.
2. Make `stop()` tear down any owned microphone/system source in both starting
   and running states. A late start completion must clean up and throw rather
   than set the service back to running.
3. In one atomic slice with step 4, mark the session as durably stopping in
   `MeetingRecordingService` before its first stop await. The stale start catch
   must consult that ownership and must not run failed-start deletion once Stop
   owns settlement.
4. Change `.starting + .stopRequested` to begin the existing durable
   stop-and-queue effect immediately (including processing UI/menu state).
   Because Stop does not bump generation, matching-generation
   `.recordingStarted` and `.startFailed` events received in `.stopping` must be
   ignored; they must not fire a second stop or cover a successful stop with a
   start error.
5. Make the coordinator's stale start task suppress start-failure telemetry/UI
   once the same generation is already durably stopping. Document that the
   stop task replaces `actionTask` ownership while the invalidated start task
   may finish later.
6. Preserve current Cancel semantics and recovery-lock rules.

### Slice C — documentation and diagnostics

1. Update `Sources/MacParakeetCore/Audio/README.md` with the bounded callback
   and partial-start ownership rule.
2. Amend ADR-014's meeting lifecycle/state-machine sections and ADR-015's
   concurrency invariants. Update the recovery contract only if implementation
   changes the stated deletion/preservation boundary (the intended design does
   not).
3. Add local stage diagnostics for start timeout/cancellation, stop timeout,
   stop-during-start, and ignored late completion where useful. Do not include
   raw errors, transcript content, or stable reporter identifiers.

## 5. Test matrix

- Callback waiter/controller:
  - completion before timeout;
  - framework error propagation;
  - timeout before completion;
  - explicit cancellation while start is pending;
  - completion after timeout/cancellation cannot resume the caller again;
  - late start success actively invokes best-effort bounded stop;
  - stop timeout returns exactly once.
- Whole start attempt:
  - a hung shareable-content provider still times out;
  - content arriving after timeout cannot install/start an owned stream;
  - any late-created/late-started stream is stopped and released.
- `MeetingAudioCaptureService`:
  - Stop during microphone startup prevents system startup and late revival;
  - Stop during system startup stops both partial sources;
  - normal start/stop and failure rollback remain intact;
  - second start is rejected while an attempt owns the service.
- `MeetingRecordingService`:
  - durable Stop racing an async start owns cleanup/finalization;
  - the stale start task cannot delete the stop result, queued artifacts, or a
    replacement session;
  - Cancel during async start still discards.
- Meeting flow state machine/coordinator:
  - Stop during `.starting` launches durable stop immediately;
  - matching-generation late `recordingStarted` emits no second stop;
  - matching-generation late `startFailed` cannot replace the stopping outcome;
  - quit settlement is released after the bounded stop path completes.

Focused iteration commands:

```bash
swift test --filter ScreenCaptureLifecycle
swift test --filter MeetingAudioCaptureServiceTests
swift test --filter MeetingRecordingServiceTests
swift test --filter MeetingRecordingFlowStateMachineTests
swift test --filter MeetingRecordingFlowCoordinatorTests
```

Final gates (once only for the full suite):

```bash
scripts/dev/format.sh
git diff --check
swift build
swift test
scripts/dev/greptile_review.sh origin/main
```

`no-mistakes` is not installed in this checkout, so use the documented review
workflow and record that fallback in the PR.

## 6. Review gates

1. **Completed 2026-07-15:** Claude Fable reviewed this plan and the governing
   source/tests/ADRs. The plan now incorporates all four blocking findings:
   atomic durable-stop ownership, both stale `.stopping` transitions,
   whole-start-attempt bounding, and active cleanup of late start success.
   Fable's scope recommendation to split dictation was accepted.
2. Implement red-green in the slices above with focused tests only.
3. **Completed 2026-07-15:** Claude Fable reviewed the completed implementation
   and returned `APPROVE WITH NON-BLOCKING NOTES`, with no merge blockers. Its
   privacy-relevant suggestion to repeat idempotent microphone teardown after a
   late interrupted start was incorporated with a regression assertion.
4. Commit, run local Greptile on the committed branch, address findings to a
   fixed point, run the single full-suite gate, then push and open a PR.
5. Re-fetch the PR head SHA, checks, and review-thread state before declaring
   merge readiness.

## 7. Acceptance criteria

- A missing `SCStream.stopCapture` callback cannot leave the app awaiting
  teardown forever.
- A stalled shareable-content/start operation cannot leave the meeting UI in
  startup forever, and a late success cannot create an orphan capture.
- Stop during meeting startup begins teardown immediately and cannot be undone
  by late startup completion.
- A durable meeting Stop is never converted into failed-start deletion by a
  racing task.
- Dictation behavior and explicit meeting Cancel behavior remain unchanged.
- Focused tests, build, formatting, `git diff --check`, the one final full test
  run, committed-branch review, and GitHub CI all pass on the exact PR head.
