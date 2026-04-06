# ADR-016: Centralized STT Runtime and Scheduler

> Status: ACCEPTED
> Date: 2026-04-05
> Related: ADR-001 (Parakeet STT), ADR-007 (FluidAudio CoreML migration), ADR-014 (meeting recording), ADR-015 (concurrent dictation and meeting recording)

## Context

MacParakeet has three co-equal transcription producers:

1. Dictation
2. Meeting recording (live chunk preview + finalization)
3. File / YouTube transcription

ADR-015 established that dictation and meeting recording must run concurrently at the audio and UI layers. That decision intentionally kept the audio pipelines independent, but it did not fully specify how STT ownership and scheduling should work as the app grows into a multi-producer system.

Parakeet via FluidAudio/CoreML is a scarce, process-wide resource in practice:

- The expensive part is ANE/CoreML inference, not microphone capture
- Interactive dictation latency matters far more than batch throughput
- Meeting live preview is useful but can tolerate bounded lag or dropped chunks under pressure
- File transcription is usually background/batch work and should never degrade dictation responsiveness

Per-flow STT ownership leads to duplicated runtime lifecycle, unclear shutdown/warm-up behavior, and no explicit admission control. Even if CoreML serializes inference internally, the app should not rely on implicit contention as its scheduling policy.

## Decision

### 1. One process-wide STT runtime owner

MacParakeet owns exactly one app-level STT runtime actor for Parakeet inference in the process.

That runtime is the sole owner of:

- lane-scoped `AsrManager` instances
- model download / initialization / readiness
- warm-up progress
- shutdown / cleanup
- model cache clearing

No feature service (`DictationService`, `MeetingRecordingService`, `TranscriptionService`) owns its own STT runtime.
The runtime may keep multiple internal managers so the scheduler can isolate dictation, meeting, and batch work without app-level head-of-line blocking, but that multiplicity stays hidden behind one shared runtime owner.

### 2. One explicit STT scheduler / broker

All transcription requests flow through a single scheduler in front of the runtime.

The scheduler is the sole owner of:

- job admission
- job priority
- fairness between modes
- backpressure
- cancellation
- job-scoped progress fan-out

Feature services submit jobs to the scheduler; they do not call the runtime directly.

### 3. Independent audio capture remains unchanged

This ADR does **not** change the audio architecture from ADR-014 / ADR-015:

- Dictation keeps its own `AVAudioEngine`
- Meeting microphone capture keeps its own `AVAudioEngine`
- Meeting system audio keeps its Core Audio Tap path

Concurrency at the audio layer remains independent. This ADR only centralizes ownership of the STT layer.

### 4. Scheduling policy is lane-driven

The scheduler partitions work into three explicit lanes:

1. **Dictation lane** — serial, interactive, reserved for `dictation`
2. **Meeting lane** — serial, reserved for `meetingFinalize` and `meetingLiveChunk`
3. **Batch lane** — serial, reserved for `fileTranscription`

Within the meeting lane:

1. **Meeting finalization** beats queued live preview work
2. **Meeting live chunks** remain best-effort

Batch work includes:

- file transcription
- YouTube transcription
- retranscription of already-saved meetings from the library

Only the immediate post-stop meeting path uses `meetingFinalize`.
Archived meeting retranscribes stay on the batch lane even when their telemetry/source metadata remains `.meeting`.

Rationale:

- Dictation is interactive and latency-sensitive
- Stopped meeting recordings should complete promptly once they enter the meeting lane
- Live meeting preview should degrade before stop/finalize work
- Saved-library retranscribes should never occupy the meeting lane used by active meetings

### 5. Backpressure is explicit

Meeting live chunk transcription is best-effort and droppable under backlog.

If the scheduler exceeds configured queue or latency thresholds, it may:

- drop pending live meeting chunks
- continue preserving the final mixed meeting artifact for post-stop transcription

This keeps the app responsive while preserving correctness of the final saved meeting.

### 6. Long-running jobs must be bounded

To support meaningful prioritization, long-running work must be divided into bounded units whenever practical.

- Meeting live preview already uses chunked work units
- Dictation is naturally short
- File / YouTube transcription should evolve toward chunked or segmented STT work if we want finer-grained fairness within the batch lane

Until batch transcription is segmented, each lane remains single-slot and non-preemptive: the scheduler may reorder queued work before admission to a lane, but it does not preempt a currently running decode within that lane.

### 7. Progress must be job-scoped

Progress reporting is owned by the scheduler and exposed per job/request, not by directly broadcasting raw runtime progress streams to multiple callers.

This avoids crosstalk between:

- dictation progress
- meeting live chunk progress
- file transcription progress
- onboarding warm-up progress

## Consequences

### Positive

- Clear ownership: one runtime, one scheduler, many producers
- Warm-up and shutdown become deterministic
- Dictation latency is protected explicitly instead of by luck
- Meeting live preview degrades gracefully under pressure
- Saved meeting retranscribes cannot block active meeting finalization
- The architecture naturally extends to future concurrency cases, including file transcription during meetings

### Negative

- Adds a real scheduling abstraction instead of relying on direct service calls
- Requires explicit queue, priority, and cancellation tests
- Chunked batch transcription is a larger follow-on change if full fairness is desired

## Implementation Direction

### Core types

- `STTRuntime` — owns lane-scoped `AsrManager` instances plus model lifecycle
- `STTScheduler` — owns lane admission, in-lane priority, progress fan-out, and job execution against the runtime

### Service boundaries

- `DictationService` submits interactive dictation jobs
- `MeetingRecordingService` submits live chunk and immediate post-stop meeting-finalization jobs
- `TranscriptionService` submits batch file / YouTube jobs plus saved-item retranscribes

### Migration path

1. Introduce `STTRuntime` and `STTScheduler`
2. Route all existing `STTClient` call sites through the scheduler
3. Remove per-feature STT client ownership
4. Make runtime warm-up / shutdown the single app-wide path
5. Add scheduler priority and backpressure tests

## Notes

- The primary product use case remains **meeting recording + dictation**.
- File transcription concurrency is worth supporting architecturally, even if it remains a lower-priority workflow in the UX and release messaging.
