# Meeting Recovery And Retention Safety

> Status: ACTIVE - crash recovery and destructive-sweep safety contract.

## Purpose

Meeting recording folders contain user data while capture, mixing,
transcription, and crash recovery are in flight. This contract separates the
predicates that discover recoverable sessions, refuse active-session CLI
actions, and protect folders from automatic destructive sweeps.

## Producers

- `MeetingRecordingService`: writes and rewrites `recording.lock` during
  capture, stop, notes updates, and background finalization.
- `MeetingRecordingRecoveryService`: reads orphaned locks, recovers audio, and
  deletes locks only after successful completion or explicit cleanup.
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
- `MeetingRecordingRecoveryServiceTests`
- `MeetingAudioRetentionPolicyTests`
- `MeetingAudioRetentionSweeperTests`

Focused coverage pins dead-PID `awaitingTranscription` reads, the distinction
between active-session discovery and retention safety, completed recovery lock
cleanup, and retention sweeps skipping valid, zero-byte, corrupt, and
future-schema lock files.

## When this changes

Update this file, ADR-019, `spec/05-audio-pipeline.md`, CLI changelog notes for
clear-audio behavior, and the focused lock/recovery/retention tests in the same
PR.
