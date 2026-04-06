# Centralized STT Runtime + Scheduler Implementation Plan

> Status: **IMPLEMENTED**
> Date: 2026-04-05
> Driving ADRs: ADR-016 (centralized STT runtime and scheduler), ADR-015 (concurrent dictation and meeting recording), ADR-014 (meeting recording)

## Overview

Refactor MacParakeet's STT architecture from per-flow client ownership to one process-wide STT runtime with one explicit scheduler/broker in front of it.

This plan assumes the docs-first architecture update has already landed in spec/ADR form. The code should be brought into alignment with the new decision:

- one STT runtime owns `AsrManager`
- one scheduler owns admission, priority, backpressure, cancellation, and job-scoped progress
- dictation, meeting recording, and file/YouTube transcription become producers submitting jobs into the scheduler
- audio capture remains independent per flow

## Implementation Outcome

The implementation landed with the intended end-state architecture:

- `STTRuntime` is the sole app-owned owner of `AsrManager` lifecycle
- `STTScheduler` is the sole app-owned owner of STT job admission, priority ordering, and backpressure
- `AppEnvironment` wires one shared runtime/scheduler path for dictation, meeting recording, and file/YouTube transcription
- onboarding warm-up, readiness checks, cache clearing, and shutdown all route through that shared path
- meeting live chunks are dropped under backlog by scheduler policy rather than by service-local guards
- `STTClient` remains only as a compatibility facade around the shared stack for standalone callers/tests

## Goals

1. Make STT ownership explicit and singular.
2. Protect dictation latency during concurrent meeting recording.
3. Preserve meeting live preview while making it best-effort under backlog.
4. Keep file/YouTube transcription architecturally compatible without letting it degrade interactive responsiveness.
5. Replace incidental concurrency with tested scheduling policy.

## Non-Goals

1. Rewriting the audio capture architecture.
2. Reworking dictation or meeting UI state machines beyond integration changes.
3. Shipping a large product UX change in the same PR.
4. Solving perfect mid-job preemption for long batch transcription in phase 1.

## Current Problems To Eliminate

1. Multiple STT owners in `AppEnvironment`.
2. Warm-up/onboarding bound to only one STT client.
3. Shutdown/cleanup bound to only one STT client.
4. No explicit scheduler policy between dictation, meeting live chunks, and file transcription.
5. Progress handling coupled too closely to the raw runtime stream.

## Target Architecture

### Core Types

1. `STTRuntime`
   - Sole owner of `AsrManager`
   - Handles warm-up, initialization, readiness, shutdown, cache clearing
   - Exposes a minimal runtime API to execute one transcription request

2. `STTScheduler`
   - Sole owner of queueing, priorities, fairness, cancellation, and backpressure
   - Executes jobs against `STTRuntime`
   - Exposes request-scoped progress/results

3. `STTJob`
   - Encodes request kind and priority
   - Carries source metadata and cancellation/progress hooks

### Producers

1. `DictationService`
   - submits `dictation` jobs
2. `MeetingRecordingService`
   - submits `meetingLiveChunk` jobs
   - submits `meetingFinalize` jobs
3. `TranscriptionService`
   - submits `fileTranscription` jobs

### Priority Policy

1. `dictation`
2. `meetingFinalize`
3. `meetingLiveChunk`
4. `fileTranscription`

### Backpressure Policy

1. Meeting live chunk jobs are droppable under backlog.
2. Dictation must never wait behind queued low-priority work.
3. Batch file work may wait, pause between work units, or remain non-preemptive in phase 1.

## Execution Phases

### Phase 0: Pre-Flight and Design Lock

1. Keep ADR-016 and surrounding docs authoritative.
2. Identify all direct `STTClientProtocol` consumers.
3. Decide whether phase 1 keeps `STTClientProtocol` as the public producer-facing boundary or introduces a new scheduler protocol immediately.

Exit criteria:
- One agreed runtime/scheduler API surface documented in code comments or an implementation sketch.

### Phase 1: Introduce `STTRuntime`

1. Extract the current model lifecycle responsibilities from `STTClient` into a dedicated runtime owner.
2. Keep behavior identical:
   - lazy init
   - warm-up
   - readiness
   - shutdown
   - cache clearing
3. Ensure there is exactly one runtime instance in `AppEnvironment`.

Exit criteria:
- `AppEnvironment` has one runtime owner.
- warm-up and shutdown code paths target the shared runtime only.

### Phase 2: Introduce `STTScheduler`

1. Add an explicit scheduler actor in front of the runtime.
2. Define job kinds and priority ordering.
3. Execute one job at a time against the runtime in phase 1.
4. Expose request-scoped progress and cancellation.

Exit criteria:
- producers no longer talk to runtime lifecycle directly.
- scheduler ordering is deterministic and testable.

### Phase 3: Migrate Producers

1. `DictationService` submits dictation jobs to the scheduler.
2. `MeetingRecordingService` submits live chunk jobs to the scheduler.
3. `MeetingRecordingService` finalization path submits a higher-priority meeting-finalize job.
4. `TranscriptionService` submits file/YouTube jobs to the scheduler.

Exit criteria:
- no feature service owns its own STT runtime/client.
- all transcription requests flow through one scheduler.

### Phase 4: Progress Isolation

1. Ensure progress is job-scoped.
2. Prevent crosstalk between:
   - onboarding warm-up
   - dictation progress
   - meeting live chunk work
   - file transcription progress
3. Update any producer assumptions that progress is globally sourced from the runtime.

Exit criteria:
- concurrent or interleaved jobs cannot leak progress to the wrong caller.

### Phase 5: Backpressure for Meeting Live Chunks

1. Move live chunk backlog policy into the scheduler or clearly partitioned scheduling logic.
2. Preserve current best-effort behavior for live preview.
3. Make dropped work observable in tests and logs.

Exit criteria:
- backlog behavior is explicit, not incidental.
- meeting live preview can degrade gracefully without affecting correctness of final saved meeting.

### Phase 6: Batch Work Strategy

1. Decide phase-1 behavior for file/YouTube transcription while interactive work exists:
   - queue-only, non-preemptive between jobs
   - or bounded segmentation if feasible now
2. Document tradeoff in code and tests.
3. If not segmented in this pass, add a follow-up task for chunked batch STT.

Exit criteria:
- product behavior is intentional and documented.

## Testing Plan

### New Tests

1. Scheduler priority ordering:
   - dictation beats queued meeting live chunks
   - meeting finalization beats queued file transcription
2. Shared ownership:
   - warm-up, readiness, shutdown, cache clear target one runtime
3. Progress isolation:
   - progress for one job does not leak to another
4. Backpressure:
   - meeting live chunks drop under thresholds

### Regression Coverage

1. Existing dictation service tests remain green.
2. Existing meeting recording tests remain green.
3. Existing transcription service tests remain green.
4. Full suite remains green after producer migration.

## Likely File Touchpoints

Core:
- `Sources/MacParakeetCore/STT/STTClient.swift`
- `Sources/MacParakeetCore/STT/STTClientProtocol.swift`
- new runtime/scheduler files under `Sources/MacParakeetCore/STT/`

Services:
- `Sources/MacParakeetCore/Services/DictationService.swift`
- `Sources/MacParakeetCore/Services/MeetingRecordingService.swift`
- `Sources/MacParakeetCore/Services/TranscriptionService.swift`

App wiring:
- `Sources/MacParakeet/App/AppEnvironment.swift`
- `Sources/MacParakeet/AppDelegate.swift`

Tests:
- `Tests/MacParakeetTests/STT/*`
- `Tests/MacParakeetTests/Services/MeetingRecordingServiceTests.swift`
- `Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift`
- new scheduler-focused tests

## Resolved Design Decisions

1. Keep `STTClientProtocol` as the producer-facing compatibility boundary for this pass, backed by the shared scheduler/runtime path.
2. Move meeting live chunk dropping fully into `STTScheduler` so backpressure policy has one owner.
3. Defer segmented file/YouTube transcription to follow-up work; ADR-016 ships centralized ownership and priority ordering first.

## Recommended Delivery Shape

1. Runtime extraction + single-owner wiring
2. Scheduler introduction + dictation migration
3. Meeting recording migration + backlog policy
4. File/YouTube migration + progress isolation
5. Final cleanup, tests, and doc sync

## Definition of Done

1. There is one process-wide STT runtime owner.
2. There is one explicit scheduler/broker for all STT work.
3. Dictation and meeting recording coexist without per-flow STT ownership.
4. Warm-up and shutdown are single-path and deterministic.
5. Scheduler priority/backpressure behavior is covered by tests.
6. Docs and code match ADR-016.
