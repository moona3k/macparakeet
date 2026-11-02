# Independent capture and finalization review

Reviewed candidate `93e7b3944` against stable `394e630b4` (`v0.8.10`). This is a fresh source review, not a confirmation of the earlier audit receipts. No builds, tests, native recording, user-data inspection, or external actions were performed.

**Verdict: no confirmed introduced P1/P2 finding in the assigned capture/finalization scope.** This is not native capture, recovery, or audio-quality acceptance evidence.

## Scope and method

Deep review: the assigned production diff exceeds 200 changed lines and changes durable-data and concurrency boundaries. Applied assumption violation, cross-component composition, failure cascades, and concurrent/repeated-use scenarios.

Read the worktree's AGENTS.md, Audio/STT/Database subsystem guidance, meeting artifact and recovery/retention contracts, and relevant crash-recovery and echo-cancellation ADRs. Inspected the current implementations and stable comparison, including the capture changes in `ee3f9b87e`. `d66cfae0f` changes player/probe code outside the assigned capture implementation; its presence was verified, and this receipt makes no independent verdict about its video-provider behavior.

Covered:

- `MeetingRecordingService`: capture stop, event drain, writer settlement, source exclusion, durable metadata/lock writes, cleanup, session-scoped notes/type updates, and compatibility `stopRecording()`.
- `MeetingRecordingCapture`: reconstruction, source viability and timeline preservation, processing-row construction, playback preparation, and deferred cleaned-mic preparation.
- `MeetingRecordingFlowCoordinator` and `MeetingTranscriptionQueue`: early stop, durable row creation, queue admission, ownership handoff, FIFO, errors/cancellation, retries, replacement capture, and completion presentation generations.
- Lock-store claim/release/relinquishment and recovery-service admission, retained sources, reconstruction, completion, and discard.
- Cleaned-mic readiness/scheduler and renderer reference lookahead; playback builder cancellation and fallback; output reconstruction and audio-state presentation.
- Detail retry state and its production callback bridge, library/meeting retry callers, editing and speaker actions, navigation, deletion/audio detach, and database metadata merge on completion.
- Relevant regression-test source, including source-only corrupt-lock reconstruction, FIFO preparation, playback failure/cancellation, pending detail retries, navigation/edit protection, and the optional real-LocalVQE fixture. Tests were inspected, not executed.

## Constructed scenarios and disposition

1. **Stop A, block its playback preparation, then start B.** The production stop returns the immutable capture after source settlement and clears only A's service state. The queue holds A's folder lease during derived work; it has no capture-service cleanup handle. Completion presentation also checks the recording generation. No path from A's playback task to B's microphone/session cleanup was found.
2. **A source writer misses its deadline.** A timeout with captured frames fails stop and preserves artifacts. An empty pending source is excluded from source alignment; reconstruction checks the writer registry, and the preparation reader requires a retained alignment track before opening its URL. Recovery/discard refuse pending writers. The unchanged completion/retention boundaries were traced rather than assuming that “capture stopped” meant every writer had returned.
3. **Playback preparation throws or is cancelled.** Queue failure updates the existing row, restores its ownership lease, and advances to the next item. Raw sources are not deleted by playback preparation. The original lock remains a destructive-sweep barrier. Retry reconstructs a capture when duration is missing or playback is not viable.
4. **Stop succeeds but row creation or admission fails.** The new unqueued-capture relinquishment checks the exact session, original PID, awaiting state, absence of another lease, and absence of pending writers. Its row transition precedes publishing PID 0 under the ownership mutex; it does not revoke a later queue/recovery owner.
5. **Two retry/recovery callers target one folder.** The ownership mutex and live lease reject the second claimant. The retry constructor's read-only reconstruction does not itself create a writer. Corrupt/empty supported locks use the existing claim policy; a missing lock and live future-schema owner remain rejected.
6. **Detail retry is admitted behind another meeting; navigate away, edit, or retry rapidly.** Per-row attempt state lasts until terminal queue callbacks, blocks conflicting detail edits, and does not select a different row on completion. Admission errors are kept with their original row. Raw-folder deletion was traced through the existing on-disk lock barrier, rather than relying solely on the view's status snapshot.
7. **Notes, title, classification, or audio pointers change during finalization.** Existing finalization uses the persisted row and completion merges current user metadata transactionally. The new capture metadata sidecar remains provenance. Deletion cannot silently recreate a missing completed row through the normal completion merge.
8. **Cleaned-mic preparation is rejected before entitlement preflight.** Deferred readiness does not start or remove derived artifacts at capture/queue admission; the STT consumer resolves it after preflight. Copies share one resolution, and cancellation propagates to that resolution. Raw microphone audio remains the durable source.

## Investigated but unconfirmed lead

`MeetingRecordingCapture.makeProcessingTranscription()` and `preparePlayback()` do not propagate lock `titleOverride`, `startedAt`, or `audioRetentionStartedAt`. This alone is not a demonstrated release regression. Stable `MeetingRecordingService.stopRecording()` also omitted all three when constructing normal capture output; normal recording lock construction does not set title override or the import retention clock. Existing-row Retry preserves those DB fields, while import/recovery use their own output/stub construction. No reachable normal caller was identified that newly loses an existing explicit override or retention timestamp through the capture helper. Do not report this as a confirmed defect without such a caller.

## Residual risks and evidence limits

- The 20 ms reference lookahead reduces the estimator's effective positive-lag reach from 100 ms to 80 ms, as documented in ADR-028. Higher-latency speaker routes remain an audio-quality acceptance risk, not a newly discovered undocumented failure. This review did not exercise Bluetooth output or a real room/meeting.
- The real LocalVQE lookahead test requires opted-in model/library assets and is skipped without them. Its double-talk waveform error is printed but is not an assertion; passing ordinary unit tests would not establish double-talk fidelity.
- Native ScreenCaptureKit/AVFoundation late callbacks, microphone stalls, OS permission transitions, process termination, and filesystem failures were traced in source but were not induced.
- No claim is made that existing tests passed at this head. No production source or unrelated workspace file was modified by this review.

## Follow-up: calendar-title guard

The following notes describe the pre-commit review and correction. The final corrected production/test snapshot is preserved in commit `0146098b013e02d9e684d84163a08f541298e5d3`; references below to the working diff describe that historical review stage.

Reviewed the later uncommitted `TranscriptionService` calendar-title guard and `testTranscribeMeetingProtectsCalendarTitlesThatResembleFallbacks`, including the optional calendar-snapshot fixture parameter. This follow-up does not change the verdict about committed `93e7b3944`.

**Initial P2, now resolved in the corrected working diff:** a manual or hotkey recording overlapping a calendar event lost automatic topic-title generation in the first uncommitted guard. `MeetingRecordingFlowCoordinator.swift:388-394` supplies a probable calendar snapshot while retaining a nil requested title; existing tests at lines 1426 and 1466 explicitly verify this behavior. The initial condition at `TranscriptionService.swift:2313` suppressed generation whenever the snapshot had any nonempty title, even when `fileName` was still the generated date/time fallback and never adopted that calendar name. With automatic titles enabled and sufficient transcript context, the recording kept its fallback instead of the generated topic title.

Protect a calendar name only when it is actually the current title (for example, compare normalized snapshot title and normalized `fileName`), or use equally precise title provenance. Add a regression using a `.probable` snapshot titled `Hotkey Calendar Overlap` and a default `Meeting Jun 17, 2026 at 09:59` filename; require one generation call and the generated title in the returned and persisted rows. Keep the existing three deliberate calendar-name cases and whitespace-only snapshot case.

The new test covers fresh `transcribeMeeting` and verifies that whitespace-only calendar titles still permit generation. The guard is in shared final text processing, so it also affects queued finalization/retries after their existing persisted-row snapshot is loaded. It does not write calendar snapshots, notes, title overrides, or retention fields; their existing persistence merge remains intact. No tests or builds were run in this follow-up.

### Corrected-diff re-review

Independently re-read the updated production/test diff. The final condition compares the normalized snapshot title with the normalized actual filename. It protects adopted calendar names while allowing a distinct probable event title or whitespace-only snapshot title to proceed through the existing fallback-title policy. Existing explicit title overrides remain protected by the preceding condition; the change does not alter persisted metadata or retry admission/completion.

The test table now checks three adopted calendar names, a distinct `.probable` `Unrelated Planning` snapshot paired with the generated filename, and a whitespace-only snapshot. Each checks returned/persisted title, preserved snapshot title, and LLM call count. The parent reported reproducing the initial counterexample with three failing assertions before the correction; that runtime result was not independently rerun here.

**Final follow-up verdict: the reported P2 is addressed in the current working diff; no additional concrete gap found.** This remains source-review evidence, with execution owned by the parent.
