# Meeting Recovery And Retention Safety

> Status: ACTIVE - crash recovery and destructive-sweep safety contract.

## Purpose

Meeting recording folders contain user data while capture, mixing,
transcription, and crash recovery are in flight. This contract separates the
predicates that discover recoverable sessions, refuse active-session CLI
actions, and protect folders from automatic destructive sweeps.

## Producers

- `MeetingRecordingService`: writes and rewrites `recording.lock` during
  capture, stop, and notes updates.
- `MeetingRecordingSettlement`: the only completion-path owner allowed to
  delete `recording.lock` after final transcription.
- `MeetingRecordingRecoveryService`: reads orphaned locks, recovers audio, and
  routes completed-session lock cleanup through settlement.
- `MeetingAudioRetentionSweeper`: detaches completed meeting audio after the
  configured retention window.
- `history clear-meeting-audio`: refuses clear-all when any readable lock
  session is still present.

## Consumers

- Launch/settings recovery UI.
- Background meeting finalization.
- CLI clear-audio safeguards.
- Meeting audio retention sweeps.
- Support diagnostics and future smoke tests.

## Stable Lock File

The lock filename is stable:

- `recording.lock`

Stable v1 fields:

- `schemaVersion`
- `sessionId`
- `startedAt`
- `pid`
- `displayName`
- `state`
- `speechEngine`
- `notes`

Stable states:

- `recording`: capture may still be writing source audio.
- `awaitingTranscription`: source/mixed audio has been finalized, but final
  transcription or recovery cleanup has not completed.

`notes` and `speechEngine` are backward-compatible additive fields. Missing
values decode to safe defaults. Malformed `notes` does not block recovery of
the structural lock metadata.

## Safety Predicates

Use the narrow predicate that matches the operation:

- Recovery orphan discovery: valid/readable lock plus dead owner PID.
- Active-session CLI refusal: valid/readable lock plus live owner PID, or
  stricter readable-session checks for clear-all operations.
- Automatic destructive sweep safety: any file named `recording.lock` in the
  session folder, whether it is parseable or not.

`discoverActiveSessions(...)` is PID-live only. It is not a generic "safe to
mutate" predicate. A dead-owner `awaitingTranscription` lock can still point at
valid audio that has not been finalized into a completed transcript.

## Retention Rule

Automatic retention-like deletion must skip a meeting folder whenever
`recording.lock` exists. That includes:

- valid locks
- live-PID locks
- dead-PID locks
- `recording` locks
- `awaitingTranscription` locks
- zero-byte locks
- corrupt or truncated locks
- future-schema locks
- otherwise unreadable locks

A malformed lock is a recovery or diagnostic problem, not permission to delete
audio. Deletion is allowed only through explicit user discard/cleanup flows or
after recovery/finalization removes the lock.

## Lock Deletion Authority

Completion-path lock deletion is centralized in
`MeetingRecordingSettlement`. Callers must pass the session folder,
transcription id, and session id; settlement re-fetches the `Transcription`
row and refuses to delete `recording.lock` unless the row exists, is a meeting
transcription for that artifact folder, and has `status == .completed`.
Lock-delete I/O failures are log-only: the lock remains protective and recovery
can re-settle the completed row on the next launch. On the transcription-queue
path a settlement error after a successful finalize is likewise log-only: the
completed transcript is already durably saved, so the queue still reports
success and leaves the lock for recovery to re-settle.

The non-settlement deletion paths are intentionally limited to flows that are
not final-transcription completion:

- `MeetingRecordingService.cancelRecording()`: user cancel deletes the lock
  and session folder because the user explicitly discarded the active capture.
- Failed-start / failed-capture cleanup in `MeetingRecordingService`: startup
  or no-audio failures delete the lock while also removing the unusable session
  folder before any stopped recording is offered for transcription.
- `MeetingRecordingRecoveryService.discard(_:)`: user discard of an incomplete
  recovery removes the session folder. If a completed transcription already
  exists, discard preserves the folder/audio and uses settlement to delete only
  the lock.

## Non-Stable Fields

- PID liveness is process-local and time-sensitive.
- `startedAt` and folder paths vary by session.
- Future lock schema versions are opaque to older readers; the file presence
  remains protective for destructive sweeps.

## Versioning And Compatibility

Lock schema v1 accepts older/equal versions and rejects newer versions as
opaque. Additive optional fields can stay v1 when older readers either ignore
them or decode with defaults. Required structural changes need a schema bump and
must preserve the file-presence retention barrier.

## Tests that enforce this

- `MeetingRecordingLockFileStoreTests`
- `MeetingRecordingSettlementTests`
- `MeetingRecordingRecoveryServiceTests`
- `MeetingTranscriptionQueueTests`
- `MeetingAudioRetentionPolicyTests`
- `MeetingAudioRetentionSweeperTests`
- `MeetingRecordingServiceTests`

Focused coverage pins dead-PID `awaitingTranscription` reads, the distinction
between active-session discovery and retention safety, completed recovery lock
cleanup, and retention sweeps skipping valid, zero-byte, corrupt, and
future-schema lock files. Settlement coverage pins refusal for missing or
non-completed rows, log-only delete I/O failure, queue success/failure lock
behavior, and crash-point convergence for awaiting locks with no row,
processing rows, and completed rows whose lock is still present.

## When this changes

Update this file, ADR-019, `spec/05-audio-pipeline.md`, CLI changelog notes for
clear-audio behavior, and the focused lock/recovery/retention tests in the same
PR.
