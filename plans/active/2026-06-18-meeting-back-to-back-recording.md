# Back-to-Back Meeting Recording (Decoupled Post-Stop Transcription)

**Status:** ACTIVE PLAN — not started
**Date:** 2026-06-18
**ADRs:** ADR-014 (meeting recording), ADR-015 (concurrent dictation+meeting), ADR-016 (STT scheduler / two-slot), ADR-019 (crash-resilient recording)
**Requirement:** REQ-MEET-020 (proposed)
**Issues:** #535
**Decision (owner, 2026-06-18):** **Sequential** scope. Stop meeting A → its
transcription is handed to a background queue → the recorder returns to idle
immediately so meeting B can start. **Not** fully-concurrent simultaneous
recordings (that is a much larger, separate effort).

## What this plan closes out

Today, after you stop a meeting, the app is "busy transcribing" and you **cannot
start the next recording** until it finishes. #535: *"When it's transcribing, I
can't start the next session… being able to transcribe and start a new recording
session would be awesome (transcribe may be postponed in that situation)."* The
parenthetical is the design: the user is fine with transcription happening later —
they just need the **recorder free again immediately**.

The investigation is decisive: **this is not a resource conflict.** Recording
(audio capture) and transcription (STT) are different subsystems:
- `SharedMicrophoneStream` already supports multiple subscribers.
- The STT scheduler already serializes background transcription jobs.
- The lock-file model already represents multiple sessions by PID.

The block is purely a **single-instance state machine**: a meeting that has
stopped sits in `.transcribing` until finalize completes, and
`startRecording` is guarded by `state == .idle`. So the fix is to **decouple
post-stop transcription from the recorder's lifecycle**: when a recording stops
and its audio is finalized to disk, hand the file to a background transcription
queue and return the recorder state machine to `.idle` — the transcription
finishes on its own and lands in the Library when ready.

## Scope boundaries

### In scope
- Detach post-stop **transcription** from the recorder state machine so the
  recorder reaches `.idle` once audio is **finalized to disk** (not once
  transcription completes).
- A small **background meeting-transcription queue** that owns in-flight
  finalize jobs (one or more queued), driving each through the existing
  `transcribeMeeting` path on the ADR-016 background slot.
- The stopped meeting appears in the Library/Meetings **immediately** as a row in
  a "Transcribing…" state, transitioning to done in place (Granola-style trust:
  the meeting is visibly safe the moment you stop).
- A lightweight indicator that a *previous* meeting is still transcribing while a
  *new* recording is active (so the now-recording pill isn't the only signal).
- Correct interaction with crash recovery when one session is mid-transcribe and
  another is recording.

### Out of scope
- **Fully concurrent recordings** (two live captures at once: multiple pills,
  multiple capture sessions, VPIO arbitration for two meeting mics). Starting a
  new recording still requires the *active* one to be stopped first.
- Concurrent **dictation** during a meeting — already supported (ADR-015),
  untouched.
- Changing the transcription algorithm, engine routing, or live-preview chunking
  logic — only *when* finalize runs relative to recorder idle changes.
- Reworking the STT scheduler's slot topology (we use the existing background slot
  and its existing priority ranking).

### Invariants
- **Never lose a recording — strict ordering.** The recorder returns to `.idle`
  only after, and in this exact order: (1) audio is flushed/durably finalized on
  disk, (2) the recovery lock is written as `awaitingTranscription`, (3) the
  state machine transitions to `.idle`. If (3) preceded (2), a crash in the gap
  would leave a stale `.recording` lock over finished audio and recovery could
  misdiagnose or lose the session. Today's single-session path has the same
  window; rapid back-to-back stops make it likelier to bite, so this ordering is
  a hard invariant — not an open question. [Greptile P2]
- **One live capture at a time** (sequential scope) — the new "start" still
  refuses while a recording is actively capturing.
- **Finalize ordering is deterministic.** Queued transcriptions run in stop order
  on the background slot; a new recording's live-preview chunks
  (`.meetingLiveChunk`, p1) yield to a prior meeting's `.meetingFinalize` (p0)
  per ADR-016 — accepted, since live preview is display-only.
- **Engine lease integrity, without over-locking** (ADR-021). The engine/language
  captured at *record start* drives that meeting's finalize regardless of what the
  next meeting selects. The lease is **per in-flight job** — a queued finalize must
  *not* globally block the user from selecting a different engine for the *next*
  recording; only a switch that would disrupt an active job is guarded. [Gemini]
- **Crash recovery handles N sessions.** Recovering must enumerate every session
  folder (one recording-in-progress at crash time + any awaiting-transcription),
  not assume a single active session.
- **One Library row per stopped meeting.** The stop path creates the visible
  `.processing` / "Transcribing..." row once, and the queued finalize updates
  that same row to completed/error. It must not call a path that creates a second
  `Transcription` row for the same audio.

## Verified current state (file:line)

- State machine: `Sources/MacParakeetCore/MeetingRecordingFlow/MeetingRecordingFlowStateMachine.swift`
  — states `idle → checkingPermissions → starting → recording → stopping →
  transcribing → finishing → idle`; `.recording + .stopRequested → .transcribing`
  (~130). The recorder is pinned in `.transcribing` for the whole finalize.
- The block: `Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift`
  — `startRecording` `guard stateMachine.state == .idle else { return nil }` (~191);
  `toggleRecording` treats `.transcribing`/`.finishing` as a silent no-op (~199-208).
  Single long-lived `pillViewModel` (~64) + single `stateMachine` (~59) per app.
- Single-session service: `Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingService.swift`
  — `Session` represents one active recording (~120); the service holds a single
  `currentSession?`, not a session map.
- UI gate: `Sources/MacParakeet/Views/Transcription/MeetingRecordingTile.swift`
  — start button only in `.idle`; `.completing/.transcribing` show a spinner,
  no start affordance (~122-134).
- Pill VM: `Sources/MacParakeetViewModels/MeetingRecordingPillViewModel.swift`
  — single `PillState` enum (not an array of sessions).
- Scheduler (not the blocker): `Sources/MacParakeetCore/STT/STTScheduler.swift`
  — `SchedulerSlot { interactive, background }` (~790-801); `.meetingFinalize`
  (p0) and `.meetingLiveChunk` (p1) share `background`. Sequential/queued finalize
  is exactly what it's built for.
- Capture (not the blocker): `Sources/MacParakeetCore/Audio/SharedMicrophoneStream.swift`
  — multi-subscriber engine (~187 subscribe; ~54-92 arbitration). Finalize reads a
  saved file, not the live mic.
- Crash resilience: `Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingLockFileStore.swift`
  — `MeetingRecordingLockFile { sessionId, state(.recording/.awaitingTranscription),
  pid }`; `discoverActiveSessions` already returns **multiple** live sessions by PID
  (~232). The model supports N sessions; the recovery *flow* must consume that.

## Design

### The decoupling
1. On stop, the recorder finalizes audio to its session folder and writes the
   lock as `awaitingTranscription` (already a modeled state). **This is the point
   the recorder returns to `.idle`** — capture resources released, start button
   live again.
2. Finalize (the STT pass) is handed to a new
   **`MeetingTranscriptionQueue`** (app-layer, `@MainActor` shell over the
   background-slot scheduler) that owns `[QueuedFinalize]` and drives each via the
   existing meeting transcription pipeline. Completion updates the pre-created
   Library row / summary exactly as today, and clears the lock.
3. The Library row is created in a **`.transcribing` presentation state at stop
   time** (not at completion), so the meeting is visibly safe immediately. The
   queue item carries that row id; current `TranscriptionService.transcribeMeeting`
   creates and saves its own processing row, so implementation must either
   refactor it to accept an existing row id or add a sibling finalize method that
   fills the existing stub instead of inserting a duplicate.

### State-machine change (minimal)
Split the current monolithic `.transcribing` recorder phase: the **recorder**
flow becomes `recording → stopping → idle` (it no longer waits on STT). The STT
work moves to the queue. The pill's `.transcribing` presentation is driven by the
*queue*, not by the recorder state machine — so the pill can show "idle, ready to
record" while a queue badge shows "1 transcribing". (Exact enum surgery decided in
Phase 1; goal is the smallest change that frees `startRecording`.)

### UI
- Stopping a meeting immediately resets the tile/pill to idle (start enabled).
- A small, non-blocking indicator — a badge on the Meeting tile and/or a Library
  row spinner — shows "Transcribing previous meeting…". Reuse existing
  transcribing visuals; do not introduce a second floating pill (that drifts
  toward the out-of-scope concurrent-recording UI).
- If the user starts B while A transcribes, B records normally; A's row flips to
  done in place when its queued finalize finishes.

### Crash recovery
Audit `MeetingRecordingRecoveryService` to enumerate **all** discovered sessions:
re-enqueue any `awaitingTranscription` sessions and offer recovery for a
`recording` session interrupted at crash — without assuming a single session.

## Phases
1. **Spec the state split** — design doc + the minimal state-machine change that
   lets `startRecording` succeed once audio is finalized; enumerate every call
   site that assumes `.transcribing` blocks start. Resolve the enum surgery.
2. **`MeetingTranscriptionQueue`** — app-layer queue over the background slot;
   ordered, supports ≥1 pending; unit-tested with a mock scheduler (ordering,
   completion materialization onto the original stub row, failure isolation).
3. **Wire stop → finalize-to-disk → idle + enqueue** — recorder returns to idle
   on durable finalize; lock = `awaitingTranscription`; Library row appears as
   transcribing at stop time; queued finalize updates that same row by id.
4. **UI** — idle-on-stop tile/pill + the "previous meeting transcribing" badge +
   Library row transcribing→done in place.
5. **Crash-recovery multi-session audit** — recovery enumerates all sessions;
   integration test with two planted session folders (one recording-interrupted,
   one awaiting-transcription).
6. **Docs** — ADR-016 note (finalize decoupled from recorder lifecycle),
   `spec/05-audio-pipeline.md`, register REQ-MEET-020.

## Testing
- Queue unit tests: FIFO by stop order, ≥2 pending, one failing finalize doesn't
  block the next, completion updates the original stub row without inserting a
  duplicate.
- State-machine tests: stop → idle transition happens at finalize-to-disk, not at
  STT completion; `startRecording` succeeds while a finalize is queued; start
  still refused while actively capturing.
- Recovery integration: two session folders recovered correctly.
- Manual dev-app: record → stop → immediately record again; confirm first
  transcript still lands; confirm a real call (live preview of B vs finalize of A
  ordering looks sane).
- `swift test` before merge.

## Open questions (resolve in Phase 1)
1. **Pill vs. queue ownership of `.transcribing`:** cleanest is the pill showing
   recorder-idle while a separate queue badge owns the transcribing indicator.
   Confirm we don't want the pill itself to keep showing transcribing (which
   would re-block the mental model of "free to record").
2. **Cross-engine model thrash:** if B records with live preview on a *different*
   engine than A's in-flight finalize, the `STTRuntime` may load/unload models on
   the ANE repeatedly. Confirm the runtime serializes/holds model leases sanely,
   or add a guard (e.g. let A's finalize finish its model lease before B's
   live-preview model loads — preview can degrade gracefully). Newly raised by
   this review; not flagged by the bots.
3. **Queue depth cap:** unbounded queue (serialized by the slot) vs. a soft cap
   with UI feedback if a user stops many meetings rapidly. Lean: unbounded; the
   slot serializes and each row shows its own state.
4. **Live-preview-of-B vs finalize-of-A:** accept p0-finalize preempting
   p1-live-chunks (B's preview pauses briefly) — confirm acceptable, or special-
   case ordering. Lean: accept (preview is display-only).

(Resolved during PR #556 review: the durability boundary is now a hard invariant —
audio flush → lock=`awaitingTranscription` → state→idle, in that order; and the
engine lease is per-job and must not globally block selecting a different engine
for the next recording.)

## Docs to update on completion
`spec/adr/016-centralized-stt-runtime-scheduler.md` (decoupling note),
`spec/05-audio-pipeline.md`, `spec/02-features.md`, `spec/README.md`,
`spec/kernel/requirements.yaml` (REQ-MEET-020), and an issue reply on #535.
Any new `TelemetryEventName` case added here must be mirrored in the website
`ALLOWED_EVENTS` allowlist in the same change, or the Worker drops the whole
batch (two-repo gotcha).
