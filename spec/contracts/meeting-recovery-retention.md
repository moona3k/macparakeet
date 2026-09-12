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
- `MeetingFinalizationReconciler`: uses queue ownership, the row's artifact
  lock, and an atomic status transition to identify interrupted processing
  rows without clobbering work in another live app process.
- `MeetingAudioRetentionSweeper`: detaches completed meeting audio after the
  configured retention window.
- `history clear-meeting-audio`: refuses clear-all when any readable lock
  session is still present.

## Consumers

- Launch/settings recovery UI.
- Background meeting finalization.
- Startup processing-row reconciliation.
- CLI clear-audio safeguards.
- Meeting audio retention sweeps.
- Support diagnostics and future smoke tests.

## Stable Lock File

The lock filename is stable:

- `recording.lock`

Stable lock fields:

- `schemaVersion`
- `sessionId`
- `startedAt`
- `pid`
- `displayName`
- `state`
- `finalizationLeaseId`
- `speechEngine`
- `notes`

Stable states:

- `recording`: capture may still be writing source audio.
- `awaitingTranscription`: source/mixed audio has been finalized, but final
  transcription or recovery cleanup has not completed.

`notes` is a backward-compatible additive field. Missing values decode to safe
defaults, and malformed `notes` does not block recovery of the structural lock
metadata.

`finalizationLeaseId` is a backward-compatible optional ownership token.
Normal stop-and-queue locks and older locks omit it. Retry and crash-recovery
flows write a fresh token together with the claiming process PID before they
touch the transcript row or start STT. A missing token decodes as `nil`. A
malformed token or zero-byte file makes `read` return `nil` (the same as
today's corrupt-JSON path). Reconciliation then treats that row as unowned
and marks it retryable; claim treats a *present but unreadable* lock as dead
evidence and writes a fresh ownership lock so Retry is not bricked. A future
schema is also unreadable to this build, but a peeked live PID still counts
as a live owner so an older process cannot fail the newer build's in-flight
work. A future-schema lock whose peeked PID is dead remains claimable.

A second file, `.finalization-ownership.lock`, is an advisory mutex created
inside the session folder. It is not user data, is hidden from folder
enumeration, and is not a retention barrier.

Speech-engine provenance is versioned because schema v1 writers always encoded
the former shared engine route. A v1 `speechEngine` therefore does not prove
that an independent meeting route was captured. Schema v2 introduces that
meaning: when its `speechEngine` is present, recovery uses the captured meeting
final-transcription selection; v1 locks and v2 locks without the field use the
current resolved Final Transcription route. The 2026-07-15 live/final split does
not introduce schema v3: preview is nonessential to recovery, and older stable
readers deliberately reject future schemas. Keeping v2 avoids making an active
recording invisible to older recovery, CLI, or retention readers. Readers
accept supported older versions and reject newer, unknown versions.

## Safety Predicates

Use the narrow predicate that matches the operation:

- Recovery orphan discovery: valid/readable lock plus dead owner PID, or an
  exact same-process lease token recorded as relinquished after restoration
  failed.
- Processing-row reconciliation protection: a current-process queue entry or
  a valid/readable lock at the row's artifact folder plus live owner PID.
- Active-session CLI refusal: valid/readable lock plus live owner PID, or
  stricter readable-session checks for clear-all operations.
- Automatic destructive sweep safety: any file named `recording.lock` in the
  session folder, whether it is parseable or not.

`discoverActiveSessions(...)` is PID-live except that the process which
recorded an exact lease token as relinquished excludes that token from its
active results and exposes it through orphan discovery instead. The registry
is process-local, so out-of-process callers such as the CLI conservatively
remain PID-live only. Active discovery is not a generic "safe to mutate"
predicate. A dead-owner `awaitingTranscription` lock can still point at valid
audio that has not been finalized into a completed transcript.

## Processing Row Reconciliation

At startup, a processing meeting row is stale only when no current-process
queue item owns its transcription id and no readable lock at its
`meetingArtifactFolderPath` has a live owner PID. The per-folder check is
intentional: it supports custom artifact roots and avoids treating the new
process's empty in-memory queue as global truth.

After those ownership checks, reconciliation changes the row from `processing`
to a retryable `error` with an audio-saved explanation. That write is a
compare-and-set on the persisted status. If another process completed or
otherwise settled the row after the startup read, reconciliation leaves the
newer state intact and does not report the row as reconciled.

Ownership inspection and transition failures are isolated per row. The affected
row remains unchanged and the failure is logged, while reconciliation continues
with unrelated processing meetings; one unreadable lock cannot wedge recovery
for every other meeting at startup.

The live-owner check and compare-and-set run while holding a per-session
advisory mutex. Retry and crash recovery claim ownership under that same mutex
by atomically rewriting the lock with their PID and a unique
`finalizationLeaseId`. This closes the check-to-write race: startup
reconciliation and finalization admission cannot both win. A failed or
duplicate admission restores the exact prior lock only when its lease token
still matches; successful settlement deletes the lock instead. If restoring
the prior lock hits an I/O error, that exact relinquished token may be replaced
by a later claim in the same process; unrelated and still-active lease tokens
remain protected. The replacement inherits the relinquished lease's original
pre-claim lock, so repeated fail/retry cycles cannot restore an abandoned lease
or wedge the next retry. A relinquished token is not a live owner and remains
visible to recovery discovery even while its former process PID is alive.

## Source Writer Finalization Ownership

The release-readiness candidate gives source-writer finalization one aggregate
five-second deadline and completes the caller exactly once. A writer that
accepted real frames but misses that deadline fails settlement; this is not
successful stop or permission to discard the source files. Never call
`AVAssetWriter.cancelWriting()` to handle the timeout: it can block and remove
recoverable output.

The finalization report retains **every** timed-out source identity separately
from failed captured sources. Stop must not inspect a pending source, including
an inactive zero-frame writer; a healthy completed source can still produce
playback and an awaiting-transcription result. Cancellation, empty Stop, and
failed-start cleanup retain the folder and lock whenever any source timed out.
This deliberately defers discard rather than deleting files AVFoundation still
owns. The bounded result does not transfer ownership; late callbacks alone clear
the process-local registry.

The process-local `MeetingAudioWriterFinalizationRegistry` retains the folder
until **all** writer callbacks return, even after the caller has timed out.
Same-process recovery discovery, recovery, and discard must skip/refuse that
folder while AVFoundation can still write it. A late callback cannot complete
the stop a second time. If callbacks never return, restarting the process
releases file ownership before normal recovery can proceed. `recording.lock`
continues to protect the files across that boundary.

When recovery reconciles a persisted capture report against surviving media,
it preserves known silence as diagnostic information when coverage is sufficient,
as well as elapsed/interruption history. Silence alone is valid capture and does
not make recovered self-notes partial. Older silence-only partial reports are
normalized on decode without modifying audio. Recovery still recomputes coverage
and unavailable-source status; interruption, capture failure, missing coverage,
and playback fallback remain partial. Decodable repaired files alone do not
prove healthy capture; see the
[capture-report contract](meeting-artifacts-v1.md#stable-json-fields).

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
Lock-delete I/O failures are logged and rethrown so callers can surface the
failed cleanup (for example, discard must not report success while
`recording.lock` is still on disk); the lock remains protective and recovery
can re-settle the completed row on a later scan. On the transcription-queue
path a settlement error after a successful finalize is caught by the queue:
the completed transcript is already durably saved, so the queue still reports
success and restores any retry ownership lease to the prior protective lock so
recovery can re-settle it later.

The non-settlement deletion paths are intentionally limited to flows that are
not final-transcription completion:

- `MeetingRecordingService.cancelRecording()`: user cancel deletes the lock
  and session folder after writer ownership has ended. A timed-out source
  defers discard and preserves both.
- Failed-start / no-audio cleanup in `MeetingRecordingService`: remove the
  unusable session folder and lock only when no source finalization timed out.
  Pending writers retain both for safe later recovery or discard.
- `MeetingRecordingRecoveryService.discard(_:)`: user discard of an incomplete
  recovery removes the session folder. If a completed transcription already
  exists, discard preserves the folder/audio and uses settlement to delete only
  the lock. Discard first claims finalization ownership using the current
  on-disk lock, so a stale recovery dialog cannot delete audio now owned by
  another live process or an active same-process finalization lease. A missing
  folder remains a successful no-op. Failed deletion or settlement attempts to
  restore the prior lock while the folder remains, preserving retryability.
  Recursive folder removal can delete `recording.lock` before another child
  fails; discard restores that missing recovery marker under the ownership
  mutex without replacing any lock now present. Ordinary lease release still
  leaves missing locks alone because successful settlement must stay settled.
  Restoration I/O failures are logged, and the original discard error is
  surfaced to the caller. Ownership release is attempted independently even
  when missing-lock restoration fails, so a failed release still relinquishes
  the exact lease for a later same-process retry.

## Meeting Media Mutation Lease

`MeetingMediaMutationLease` is a second, independent advisory lock from
`recording.lock`. It protects a different race: saved-meeting audio
deletion/bulk cleanup running concurrently with a future split's media
export/materialize/publish over the same recordings root. It is not a
capture/finalization ownership mechanism and must not be confused with, or
substituted for, `recording.lock`.

- One hidden, regular file per recordings root: `.meeting-media-mutation.lock`,
  written directly in the root (never inside a per-meeting session folder), so
  the lock's identity is stable even after a meeting's session folder is
  deleted, and deleting that folder can never take the lock file with it.
- Acquisition is `flock(LOCK_EX | LOCK_NB)`: nonblocking. A caller is never
  blocked; it either acquires immediately or observes a clear busy error
  (`MeetingMediaMutationLease.AcquisitionError.busy`) to surface and retry.
- The lock file is opened with `O_NOFOLLOW` and then `fstat`-checked as a
  regular file; a symlink or non-regular file (FIFO, device) planted at the
  lock path is refused (`ioFailure`/`unexpectedLockFileType`) rather than
  followed or trusted, so the lease's root identity cannot be redirected.
- Roots passed to `acquire(roots:)` are canonicalized (symlinks resolved),
  deduped, and sorted before locking, so multi-root acquisitions (a future
  split's source and destination roots) always lock in the same order and
  cannot deadlock each other. A failure partway through releases every
  descriptor already acquired by that call before the error is thrown.
- There is deliberately no PID-staleness logic, no reuse of `recording.lock`,
  and no generic reusable lock framework: `flock` is released by the kernel
  the instant the holding process exits (including a forced, uncooperative
  death) or closes the descriptor, so a crashed holder can never leave a root
  permanently locked, and this lease's scope (media mutation ordering) is
  narrower than `recording.lock`'s (capture/finalization ownership).
- Each `acquire()` call opens its own file descriptor. `flock` locks are
  scoped to the open file description, not the owning process, so two
  independent acquisitions of the same root conflict even from the same
  process -- this is intentional: two callers in one process (for example a
  bulk clear and a per-meeting delete racing on the same root) must still be
  serialized.
- `TranscriptionAssetCleanup.deleteTranscription(_:repository:)` and
  `.clearManagedMeetingAudio(under:repository:)` hold the lease across BOTH
  the file-removal phase and the repository/DB phase (delete row; detach
  stored audio paths) so the two phases cannot be observed torn apart by a
  concurrent split. `detachOwnedMeetingAudio` already held both of its phases
  together and now acquires this lease around its whole body. The lower-level
  `removeOwnedAssets` / `removeOwnedMeetingAudio` / `removeManagedMeetingAudioFiles`
  remain individually safe to call alone (each acquires its own lease
  internally via private unlocked helpers, not a public bypass flag) for
  callers that only need the file-removal half.
- Per-meeting operations acquire the meeting's session folder's *parent*
  (stable even if that specific session folder is deleted mid-operation);
  bulk operations acquire the exact recordings-root directory passed in.
  Non-meeting sources and meeting rows with no resolvable folder have no
  shared root to protect and run unlocked, matching their existing
  non-racing removal paths.
- `recording.lock` barriers are unchanged: `assertMeetingFolderUnlocked` still
  refuses a locked session folder regardless of this lease's state, and this
  lease never substitutes for that check.
- GUI (`SettingsViewModel`, `TranscriptionViewModel`, `TranscriptionLibraryViewModel`,
  `TranscriptionDeletionCleanup`) and the CLI `HistoryCommand` still call the
  pre-existing unlocked entry points as of this change; migrating those call
  sites to `deleteTranscription`/`clearManagedMeetingAudio` so every caller
  inherits the combined-phase protection is follow-up work for whoever wires
  the split feature's shared completion/CLI integration, not this foundation.
- Older MacParakeet builds that predate this lease do not create or respect
  `.meeting-media-mutation.lock`. A split running only on a build with this
  lease is protected against *this build's* mutators; it offers no
  protection against an older, unpatched binary mutating the same root
  concurrently. This is an accepted limitation, not a bug to route around
  here.

## Non-Stable Fields

- PID liveness is process-local and time-sensitive. `kill(pid, 0)` cannot
  distinguish MacParakeet from a later process that reused the same PID. A
  long-lived reused PID can leave a `.processing` row looking owned, which
  suppresses reconciliation, recovery, and Retry until that PID exits. This
  remaining hole is accepted; do not add a schema bump or process-birth
  discriminator in this change.
- `startedAt` and folder paths vary by session.
- Preview-engine provenance is intentionally not part of the lock. It is
  additive archived metadata only; recovery needs the authoritative final route.
- Future lock schema versions are opaque to older readers; the file presence
  remains protective for destructive sweeps.

## Versioning And Compatibility

Lock schema v2 accepts supported older/equal versions and rejects newer
versions as opaque. Additive optional fields can stay at the current schema
version when older readers either ignore them or decode with defaults. Required
structural changes need a schema bump and must preserve the file-presence
retention barrier.

## Tests that enforce this

- `MeetingRecordingLockFileStoreTests`
- `MeetingFinalizationReconcilerTests`
- `TranscriptionRepositoryTests`
- `MeetingRecordingSettlementTests`
- `MeetingRecordingRecoveryServiceTests`
- `MeetingTranscriptionQueueTests`
- `MeetingAudioRetentionPolicyTests`
- `MeetingAudioRetentionSweeperTests`
- `MeetingRecordingServiceTests`
- `MeetingMediaMutationLeaseTests`
- `TranscriptionAssetCleanupMutationLeaseTests`

Focused coverage pins dead-PID `awaitingTranscription` reads, serialized
single-owner retry/recovery admission, live-owner processing-row protection
across app processes, atomic refusal to regress a
completed row, the distinction between active-session discovery and retention
safety, completed recovery lock cleanup, and retention sweeps skipping valid,
zero-byte, corrupt, and future-schema lock files. Settlement coverage pins
refusal for missing or non-completed rows, rethrown delete I/O failure
(including discard surfacing a retained lock and staying retryable), queue
success/failure lock behavior, and crash-point convergence for awaiting locks
with no row, processing rows, and completed rows whose lock is still present.

`MeetingMediaMutationLeaseTests` pins nonblocking same-process acquisition
conflicts (including two independent acquisitions of the same root from one
process), a real second-process conflicting acquisition over `flock` (a
Python helper process), release and forced (`SIGKILL`) process-death both
permitting reacquisition, independent roots never conflicting, alias/symlink
roots sharing one lock key, a deterministic partial multi-root acquire fully
unwinding on conflict, and a symlinked or non-regular (FIFO) lock path being
refused rather than followed or trusted. `TranscriptionAssetCleanupMutationLeaseTests`
pins that an externally held lease blocks `deleteTranscription`,
`detachOwnedMeetingAudio`, and `clearManagedMeetingAudio` from starting either
phase (and that all three succeed once released), that `clearManagedMeetingAudio`
actually runs both its file and row phases together, that the pre-existing
`recording.lock` barrier still refuses a locked folder independent of this
lease, and that a non-meeting delete never needs or touches an unrelated
meeting root's lease.

## When this changes

Update this file, ADR-019, `spec/05-audio-pipeline.md`, CLI changelog notes for
clear-audio behavior, and the focused lock/recovery/retention tests in the same
PR. Changes to `MeetingMediaMutationLease`'s root-key resolution, lock file
name, or acquisition semantics must also update this file's Meeting Media
Mutation Lease section and `MeetingMediaMutationLeaseTests`. Migrating a GUI
or CLI call site to `deleteTranscription`/`clearManagedMeetingAudio` should
update the call-site bullet above rather than leave it stale.
