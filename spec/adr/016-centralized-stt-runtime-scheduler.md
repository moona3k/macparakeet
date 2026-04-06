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

### 1. One process-wide STT runtime

MacParakeet owns exactly one STT runtime for Parakeet inference in the app process.

That runtime is the sole owner of:

- `AsrManager`
- model download / initialization / readiness
- warm-up progress
- shutdown / cleanup
- model cache clearing

No feature service (`DictationService`, `MeetingRecordingService`, `TranscriptionService`) owns its own STT runtime.

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

### 4. Priority policy is product-driven

The scheduler uses the following priority order:

1. **Dictation** — highest priority
2. **Meeting finalization** — high priority after recording stops
3. **Meeting live chunks** — medium priority, best-effort
4. **File / YouTube transcription** — lowest priority

Rationale:

- Dictation is interactive and latency-sensitive
- Stopped meeting recordings should complete promptly
- Live meeting preview should degrade before dictation does
- Batch file work should yield to interactive work

### 5. Backpressure is explicit

Meeting live chunk transcription is best-effort and droppable under backlog.

If the scheduler exceeds configured queue or latency thresholds, it may:

- drop pending live meeting chunks
- coalesce stale live chunk jobs
- continue preserving the final mixed meeting artifact for post-stop transcription

This keeps the app responsive while preserving correctness of the final saved meeting.

### 6. Long-running jobs must be bounded

To support meaningful prioritization, long-running work must be divided into bounded units whenever practical.

- Meeting live preview already uses chunked work units
- Dictation is naturally short
- File / YouTube transcription should evolve toward chunked or segmented STT work if we want true coexistence with interactive dictation

Until batch transcription is segmented, the scheduler may only reorder jobs **between** transcriptions, not preempt a currently running long decode.

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
- The architecture naturally extends to future concurrency cases, including file transcription during meetings

### Negative

- Adds a real scheduling abstraction instead of relying on direct service calls
- Requires explicit queue, priority, and cancellation tests
- Chunked batch transcription is a larger follow-on change if full fairness is desired

## Implementation Direction

### Core types

- `STTRuntime` — owns `AsrManager` and model lifecycle
- `STTScheduler` — owns queueing, priority, progress fan-out, and job execution against the runtime

### Service boundaries

- `DictationService` submits interactive dictation jobs
- `MeetingRecordingService` submits live chunk and meeting-finalization jobs
- `TranscriptionService` submits batch file / YouTube jobs

### Migration path

1. Introduce `STTRuntime` and `STTScheduler`
2. Route all existing `STTClient` call sites through the scheduler
3. Remove per-feature STT client ownership
4. Make runtime warm-up / shutdown the single app-wide path
5. Add scheduler priority and backpressure tests

## Notes

- The primary product use case remains **meeting recording + dictation**.
- File transcription concurrency is worth supporting architecturally, even if it remains a lower-priority workflow in the UX and release messaging.
