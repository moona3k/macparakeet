# Centralized STT Runtime + Scheduler Plan

> Status: **HISTORICAL** - implementation branch landed an intermediate lane-based design; ADR-016 was refined on 2026-04-06 to a two-slot target architecture
> Date: 2026-04-05
> Updated: 2026-04-06
> Driving ADRs: ADR-016 (centralized STT runtime and scheduler), ADR-015 (concurrent dictation and meeting recording), ADR-014 (meeting recording)

## Overview

This plan originally drove the refactor from per-flow STT ownership to one process-wide runtime owner with one explicit scheduler in front of it.

The branch that followed this plan successfully centralized runtime ownership and replaced implicit contention with explicit scheduling, but it implemented that policy as three fixed execution lanes:

- dictation
- meeting
- batch

After a final product and architecture review on 2026-04-06, MacParakeet's approved target architecture was simplified further. The accepted end state is now:

- one process-wide STT control plane
- one shared STT runtime owner
- four job classes:
  - `dictation`
  - `meetingFinalize`
  - `meetingLiveChunk`
  - `fileTranscription`
- two default execution slots:
  - an interactive slot reserved for `dictation`
  - a background slot shared by `meetingFinalize`, `meetingLiveChunk`, and `fileTranscription`
- background-slot priority:
  1. `meetingFinalize`
  2. `meetingLiveChunk`
  3. `fileTranscription`
- explicit backpressure for droppable meeting live preview
- diarization kept separate from the speech-slot scheduler

This archived plan is kept for historical context because it explains how the branch reached shared STT ownership, but ADR-016 and the active specs now define the canonical target architecture.

## What The Branch Accomplished

The implementation branch delivered these important architectural steps:

1. One app-owned `STTRuntime` path for model lifecycle, warm-up, readiness, cache clearing, and shutdown.
2. One app-owned `STTScheduler` path for admission, ordering, progress fan-out, and backpressure.
3. Shared app wiring through `AppEnvironment` instead of per-feature STT ownership.
4. Explicit meeting live-preview backlog handling instead of relying on incidental service-local behavior.

Those changes remain directionally correct and are the foundation of the approved design.

## Where The Plan Drifted

This plan assumed the end-state scheduler would keep three fixed execution lanes alive in parallel:

1. Dictation lane
2. Meeting lane
3. Batch lane

That design protects concurrent meeting and dictation work well, but it permanently reserves real inference capacity for file / YouTube transcription. For MacParakeet's product priorities, that turned out to be a stronger commitment than necessary.

The approved target architecture therefore does **not** reserve a dedicated third file-transcription slot in v1.

## Approved Target Architecture

### Control Plane

- One process-wide `STTScheduler` owns job admission, queueing, priority, slot assignment, cancellation, backpressure, and job-scoped progress.
- Producer services submit jobs into the scheduler; they do not own STT topology.

### Runtime

- One shared `STTRuntime` owns model lifecycle and the slot-scoped `AsrManager` instances behind the scheduler.
- Warm-up, readiness, shutdown, and cache clear remain single-path operations.

### Job Classes

1. `dictation`
2. `meetingFinalize`
3. `meetingLiveChunk`
4. `fileTranscription`

### Slot Policy

1. **Interactive slot**
   - reserved for `dictation`
2. **Background slot**
   - shared by `meetingFinalize`, `meetingLiveChunk`, and `fileTranscription`

Priority within the background slot:

1. `meetingFinalize`
2. `meetingLiveChunk`
3. `fileTranscription`

### Backpressure Policy

1. Meeting live preview is best-effort and droppable under backlog.
2. When a meeting stops, queued live-preview work may be cancelled/dropped so finalization can run next.
3. File transcription is intentionally queued and single-job in v1.
4. A running long file transcription may delay meeting STT on the background slot until the batch job finishes or reaches a future yield boundary.

### Diarization Boundary

Speaker diarization remains a separate service and is not part of the two-slot speech scheduler.

## Follow-Up Guidance

Any future implementation work should converge the code on ADR-016's two-slot design rather than extending the historical three-lane branch shape.

If the product later needs stronger simultaneous support for `dictation + meeting + file transcription`, the preferred follow-up order is:

1. chunk or otherwise bound file-transcription work so it can yield cleanly
2. measure whether a third batch slot is justified on baseline Apple Silicon hardware
3. only then consider enabling an optional third slot

## References

- ADR-016: `spec/adr/016-centralized-stt-runtime-scheduler.md`
- Architecture spec: `spec/03-architecture.md`
- STT engine spec: `spec/06-stt-engine.md`
