# Capture and meeting finalization review

Reviewed `v0.8.10..bb1ebcc37974bfb363f2bec46250bc0532009f17` and the local fix described below.

## Confirmed finding: source-only Retry rejects recoverable unreadable locks

Priority: P2. Confidence: 100 from the control flow; runtime verification is owned by the parent release-review session.

An interrupted meeting can retain raw sources and metadata with an unknown row duration, while `recording.lock` is empty or malformed. Reconciliation marks this row retryable. The new source-only retry path calls `MeetingRecordingCapture.load` before queue admission, but that method originally used the strict lock reader, which returns nil for unreadable locks. Retry consequently throws `missingLock` before reaching the ownership claimer's existing corrupt-lock recovery.

The previous prepared retry path loads archive metadata, then claims ownership. The claimer already treats a present unreadable lock as dead evidence, while refusing live future-schema owners. This behavior is explicitly required by `spec/contracts/meeting-recovery-retention.md` under Stable Lock File.

The fix shares that existing read-only finalization candidate reader with capture reconstruction. Reconstruction still performs no mutation or ownership claim. The queue must acquire its existing lease before preparing playback or starting derived writers. Missing locks, recording-state locks, and pending writer finalization remain rejected; live future-schema ownership remains protected. No user audio is deleted.

When lock identity is unreadable, reconstruction and later claim can synthesize distinct session UUIDs. This affects diagnostic correlation only: ownership and release use the folder plus lease token; settlement checks the completed row and folder, with sessionID used only in error/diagnostic text. The existing prepared retry path also creates an output session UUID independently in `loadArchived`. This patch does not claim to recover the lost original session identity.

## Added verification

- `MeetingRecordingFlowCoordinatorTests.testSourceOnlyRetryRecoversCorruptAndEmptyLocks`: actual AAC playback rebuilding and real ownership admission, both absent and already-installed playback, malformed and empty locks; finalizes the same row and preserves the raw source.
- `MeetingRecordingCaptureTests`: reconstruction does not claim or mutate artifacts, missing lock rejection, active recording rejection, and live future-schema owner rejection without rewriting its bytes.
- Existing `MeetingRecordingFlowCoordinatorTests.testRetryMeetingFinalizationDoesNotQueueWithoutOwnership` and `MeetingRecordingLockFileStoreTests` continue to cover lease refusal and corruption normalization.

Recommended focused filter: `MeetingRecordingCaptureTests|MeetingRecordingFlowCoordinatorTests|MeetingRecordingLockFileStoreTests|MeetingTranscriptionQueueTests|TranscriptionMeetingFinalizationRetryTests`.

No builds or test execution were performed by this reviewer. `git diff --check` passed. Final compilation and test outcomes must be recorded by the parent session.

## Other reviewed paths

Traced capture stop and source settlement, new source-only handoff, FIFO queue admission and failure continuation, ownership restoration, fallback playback metadata, missing/truncated source reconciliation, session-scoped notes/type callbacks, deferred cleaned-microphone rendering and cancellation, AEC reference lookahead, saved-meeting detail retry admission/completion, and the editing/retranscription guards around detail retry.

No additional actionable regression was established in those paths. Existing tests cover next-capture isolation during playback, mix fallback/cancellation, source disappearance, delayed AEC ownership, admission failure, and retry completion after navigation.

## Remaining evidence limits

Static review and mocked coordination tests do not qualify physical microphone/system capture, Bluetooth transitions, real LocalVQE behavior across devices, long meeting resource use, production speech-model execution, native detail interactions, or signed-DMG install/update behavior. Those remain separate release qualification checks.
