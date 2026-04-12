# ADR-016: Centralized STT Runtime and Scheduler

> Status: ACCEPTED
> Date: 2026-04-06
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
- Meeting finalization after stop is more important than live preview and should complete promptly
- File transcription is usually background/batch work and can wait behind interactive work

Per-flow STT ownership leads to duplicated runtime lifecycle, unclear shutdown/warm-up behavior, and no explicit admission control. Even if CoreML serializes inference internally, the app should not rely on implicit contention as its scheduling policy.

## Decision

### 1. One process-wide STT control plane

MacParakeet owns exactly one app-level STT control plane for Parakeet inference in the process.

That control plane is responsible for:

- job admission
- queueing and priority
- slot assignment
- backpressure
- cancellation
- job-scoped progress fan-out
- runtime lifecycle coordination

Feature services submit jobs to the control plane; they do not own their own STT topology.

### 2. One shared STT runtime owner

The control plane coordinates one shared STT runtime owner for Parakeet model lifecycle.

That runtime is the sole owner of:

- slot-scoped `AsrManager` instances
- model download / initialization / readiness
- warm-up progress
- shutdown / cleanup
- model cache clearing

No feature service (`DictationService`, `MeetingRecordingService`, `TranscriptionService`) owns its own STT runtime.
Multiple internal managers/executors may exist behind the runtime owner, but that multiplicity remains hidden behind one shared lifecycle boundary.

### 3. Independent audio capture remains unchanged

This ADR does **not** change the audio architecture from ADR-014 / ADR-015:

- Dictation keeps its own `AVAudioEngine`
- Meeting microphone capture keeps its own `AVAudioEngine`
- Meeting system audio keeps its Core Audio Tap path

Concurrency at the audio layer remains independent. This ADR only centralizes ownership of the STT layer.

### 4. The default architecture has two execution slots

The control plane exposes four job classes:

1. `dictation`
2. `meetingFinalize`
3. `meetingLiveChunk`
4. `fileTranscription`

But it only guarantees **two STT execution slots** by default:

1. **Interactive slot** — reserved for `dictation`
2. **Background slot** — shared by `meetingFinalize`, `meetingLiveChunk`, and `fileTranscription`

This is deliberate. MacParakeet does **not** reserve a permanent third slot for file / YouTube transcription in v1.

Rationale:

- Dictation needs the strongest latency guarantee
- Meeting work is more latency-sensitive than file transcription
- File transcription is important, but it is asynchronous and can wait
- The product rarely needs three concurrent STT executions, so always reserving capacity for batch work is unnecessary complexity and pressure

### 5. Priority policy is slot-driven

The control plane uses the following policy:

- `dictation` always targets the interactive slot
- `meetingFinalize`, `meetingLiveChunk`, and `fileTranscription` target the background slot
- Priority within the background slot is:
  1. `meetingFinalize`
  2. `meetingLiveChunk`
  3. `fileTranscription`

This means:

- dictation stays responsive even during other work
- meeting finalization beats live preview
- file transcription yields to meeting work
- file transcription does not receive dedicated always-on capacity

Meeting recordings use `meetingFinalize` both immediately after stop and during archived retranscribe when the saved folder still contains `meeting-recording-metadata.json` plus the per-source files.
Legacy meeting rows without that archived metadata fall back to `fileTranscription` on the mixed `meeting.m4a` artifact.

Reference shape:

```text
DictationService -----------┐
MeetingRecordingService ----┼--> STTScheduler / Control Plane
TranscriptionService -------┘
                                  │
                                  ├── Interactive slot
                                  │     └── dictation
                                  │
                                  └── Background slot
                                        ├── meetingFinalize
                                        ├── meetingLiveChunk
                                        └── fileTranscription
                                               │
                                               ▼
                                        STTRuntime
                                  (slot-scoped AsrManager instances)
```

### 6. Backpressure is explicit

Meeting live chunk transcription is best-effort and droppable under backlog.

If the control plane exceeds configured queue or latency thresholds, it may:

- drop pending live meeting chunks
- cancel queued live preview work when meeting stop is requested
- attempt to cancel running live preview work when practical
- continue preserving the per-source meeting artifacts and alignment metadata required for authoritative post-stop transcription

This keeps the app responsive while preserving correctness of the final saved meeting.

### 7. Long-running batch work is queued, not privileged

File / YouTube transcription is intentionally single-job and low-priority in v1.

Until batch transcription is segmented or made interruptible, a running long file transcription may occupy the background slot and delay meeting STT work. This tradeoff is acceptable in v1 because:

- the common case is one or two simultaneous STT producers, not all three
- dictation remains protected by the interactive slot
- no data is lost; the impact is queueing and latency, not correctness

Future improvements may add:

- chunked / yielding file transcription
- pause/cancel policy for running batch work when a meeting begins
- an optional third batch slot if measurements justify it

### 8. Diarization remains a separate service

Speaker diarization is not part of the speech-slot scheduler.

It remains a separate service because:

- it is a different model path from Parakeet STT
- it is not latency-critical like dictation
- it is usually post-STT enrichment rather than interactive inference

The STT control plane may coordinate with diarization for lifecycle/UI/reporting purposes, but diarization capacity policy remains separate.

Keeping diarization out of the speech-slot scheduler does **not** mean product readiness may ignore it. When speaker detection is enabled by default, onboarding and ready-state UX must account for diarization-model readiness before claiming file transcription is fully prepared.

### 9. Progress must be job-scoped

Progress reporting is owned by the control plane and exposed per job/request, not by directly broadcasting raw runtime progress streams to multiple callers.

This avoids crosstalk between:

- dictation progress
- meeting live chunk progress
- file transcription progress
- onboarding warm-up progress

## Consequences

### Positive

- Clear ownership: one control plane, one runtime owner, many producers
- Warm-up and shutdown become deterministic
- Dictation latency is protected explicitly
- Meeting live preview degrades gracefully under pressure
- File transcription is intentionally simple and low-risk in v1
- The architecture leaves room for chunked batch work or a third slot later without returning to per-feature STT ownership

### Negative

- Adds a real scheduling abstraction instead of relying on direct service calls
- Requires explicit queue, priority, and cancellation tests
- A running long file transcription can delay meeting STT on the shared background slot
- The control plane must clearly document that batch latency can rise during interactive work

## Implementation Direction

### Core types

- `STTRuntime` — owns slot-scoped `AsrManager` instances plus model lifecycle
- `STTScheduler` — owns admission, slot assignment, in-slot priority, progress fan-out, and job execution against the runtime

### Service boundaries

- `DictationService` submits interactive dictation jobs
- `MeetingRecordingService` submits live chunk and immediate post-stop meeting-finalization jobs
- `TranscriptionService` submits batch file / YouTube jobs plus saved-item retranscribes, including archived meetings that reconstruct into the dual-source `meetingFinalize` path when metadata is available

### Migration path

1. Introduce `STTRuntime` and `STTScheduler`
2. Route all existing `STTClient` call sites through the scheduler
3. Remove per-feature STT client ownership
4. Make runtime warm-up / shutdown the single app-wide path
5. Add scheduler priority, cancellation, and backpressure tests

## Notes

- The primary product use case remains **meeting recording + dictation**.
- File transcription remains a lower-priority workflow in the UX and release messaging.
- Upstream validation against the checked-out FluidAudio `0.13.6` dependency supports this design:
  - `AsrManager` is documented as thread-safe/concurrent.
  - `transcriptionProgressStream` is explicitly single-session per manager, which reinforces keeping progress isolated by slot instead of multiplexing unrelated jobs through one manager instance.
  - `OfflineDiarizerManager.prepareModels()` short-circuits once models are prepared, so MacParakeet's single shared diarization wrapper matches the intended lifecycle.
