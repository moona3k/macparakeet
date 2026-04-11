# ADR-016 Two-Slot Convergence Plan

> Status: **COMPLETED** (historical snapshot)
> Date: 2026-04-06
> Completed: 2026-04-10
> Driving docs: `spec/adr/016-centralized-stt-runtime-scheduler.md`, `spec/03-architecture.md`, `spec/06-stt-engine.md`, `spec/adr/015-concurrent-dictation-meeting.md`
> GitHub context: issue `#64`, PR `#65`
> Implemented in: `70d76e7`, `585e142`, `a1af677` (+ follow-up hardening)
> Note: This plan is preserved as the original convergence checklist. References below to "still not aligned" reflect pre-implementation state.

## Objective

Converge the current centralized STT implementation on `feature/adr-016-stt-runtime-scheduler` from its intermediate three-lane shape to the approved ADR-016 two-slot design:

- one process-wide STT control plane
- one shared STT runtime owner
- one reserved interactive slot for `dictation`
- one shared background slot for `meetingFinalize`, `meetingLiveChunk`, and `fileTranscription`
- explicit meeting-preview backpressure
- diarization kept separate from the speech scheduler

This plan is for the **next coding agent**. It assumes the docs are already aligned to the approved target and that the code is the remaining work.

## Current Snapshot

### Already true on this branch

1. App-owned STT wiring is centralized in `AppEnvironment`.
2. `STTRuntime` and `STTScheduler` exist and are shared by dictation, meeting recording, and transcription.
3. `STTClient` is no longer app-owned architecture; it is a CLI/test compatibility facade.
4. Meeting transcript backlog reporting is already wired through the panel UI.
5. Docs/specs/ADRs now clearly distinguish:
   - approved target architecture
   - current branch implementation

### Still not aligned with the approved target

1. `STTRuntime` still owns **three** managers:
   - `dictationManager`
   - `meetingManager`
   - `batchManager`
2. `STTScheduler` still routes work through **three** internal lanes:
   - `dictation`
   - `meeting`
   - `batch`
3. That means the current code still protects file transcription from meeting work more strongly than the approved two-slot policy allows.
4. Onboarding still has a real readiness gap:
   - `runEnginePreflight()` only checks STT cache/readiness
   - diarization preparation still happens later
   - `DiarizationService.isReady()` is process-local, not a persistent cache/readiness check

## Locked Target

These are not open design questions for this pass.

### Job classes

1. `dictation`
2. `meetingFinalize`
3. `meetingLiveChunk`
4. `fileTranscription`

### Slot policy

1. **Interactive slot**
   - reserved for `dictation`
2. **Background slot**
   - shared by `meetingFinalize`, `meetingLiveChunk`, and `fileTranscription`

### Background-slot priority

1. `meetingFinalize`
2. `meetingLiveChunk`
3. `fileTranscription`

### Explicit accepted tradeoff

If a long `fileTranscription` job is already running on the background slot, later meeting STT work may wait until that non-preemptive batch job completes or reaches a future yield boundary. That is an accepted v1 tradeoff.

### Out of scope for this pass

1. Chunked/yielding batch transcription
2. Hardware-adaptive executor counts
3. A dedicated third batch slot
4. Folding diarization into the STT scheduler
5. Large UI redesign

## Current vs Target Shape

### Current branch implementation

```text
Feature services
    │
    ▼
STTScheduler
    ├── dictation lane
    ├── meeting lane
    └── batch lane
    │
    ▼
STTRuntime
    ├── dictationManager
    ├── meetingManager
    └── batchManager
```

### Approved target

```text
Feature services
    │
    ▼
STTScheduler
    ├── interactive slot
    │     └── dictation
    └── background slot
          ├── meetingFinalize
          ├── meetingLiveChunk
          └── fileTranscription
    │
    ▼
STTRuntime
    ├── interactiveManager
    └── backgroundManager
```

## Code Touchpoints

### Must change

1. `Sources/MacParakeetCore/STT/STTRuntime.swift`
2. `Sources/MacParakeetCore/STT/STTScheduler.swift`
3. `Sources/MacParakeetViewModels/OnboardingViewModel.swift`
4. `Sources/MacParakeetCore/Services/DiarizationService.swift`
5. `Tests/MacParakeetTests/STT/STTSchedulerTests.swift`
6. `Tests/MacParakeetTests/ViewModels/OnboardingViewModelTests.swift`

### Likely to inspect but not necessarily change much

1. `Sources/MacParakeet/App/AppEnvironment.swift`
2. `Sources/MacParakeetCore/STT/STTClient.swift`
3. `Sources/MacParakeetCore/Services/MeetingRecordingService.swift`
4. `Sources/MacParakeetCore/Services/TranscriptionService.swift`
5. `Tests/MacParakeetTests/ViewModels/MeetingRecordingPanelViewModelTests.swift`

## Recommended Delivery Order

### Phase 1: Runtime topology convergence

Goal: reduce the runtime from 3 internal managers to 2 without changing the public producer-facing API.

Tasks:

1. Replace the internal runtime lane enum with two cases:
   - `interactive`
   - `background`
2. Replace:
   - `dictationManager`
   - `meetingManager`
   - `batchManager`
   with:
   - `interactiveManager`
   - `backgroundManager`
3. Route jobs as follows:
   - `dictation` -> `interactive`
   - `meetingFinalize`, `meetingLiveChunk`, `fileTranscription` -> `background`
4. Update initialization, cleanup, `isReady()`, and shutdown paths accordingly.

Exit criteria:

1. No `meetingManager` or `batchManager` remains in `STTRuntime`.
2. Runtime routing is two-slot only.

### Phase 2: Scheduler policy convergence

Goal: collapse scheduler internals from 3 lanes to the approved 2-slot policy.

Tasks:

1. Replace `SchedulerLane` with:
   - `interactive`
   - `background`
2. Update routing so:
   - `dictation` always enters `interactive`
   - `meetingFinalize`, `meetingLiveChunk`, `fileTranscription` enter `background`
3. Keep priority ordering inside the background slot:
   - `meetingFinalize`
   - `meetingLiveChunk`
   - `fileTranscription`
4. Preserve current meeting-live backpressure behavior on the background slot.
5. Preserve cancellation behavior and quiesce/shutdown semantics.

Important:

- Do **not** try to solve batch preemption in this pass.
- The implementation should intentionally allow a running batch job to occupy the background slot.

Exit criteria:

1. No separate `meeting` or `batch` scheduler lanes remain.
2. Queueing behavior matches the approved target.

### Phase 3: Onboarding and diarization readiness

Goal: remove the late speaker-model failure path and make onboarding readiness honest.

Tasks:

1. Add a persistent diarization readiness/cache check to `DiarizationService`.
   Recommendation:
   - introduce a static/nonisolated cache check or equivalent helper that does not rely on process-local `modelsReady`
2. Update `OnboardingViewModel.runEnginePreflight()` so it does not return early solely because the STT model is cached when required diarization assets are still missing.
3. Keep the accepted offline behavior:
   - if both required assets are already cached, onboarding can proceed offline
   - if any required default-on asset is missing, preflight must surface the disk/network requirement before warm-up claims success
4. Keep diarization outside the STT scheduler itself.

Exit criteria:

1. Onboarding cannot report ready while speaker-detection assets are still missing.
2. Reset-onboarding + offline no longer fails late in diarization preparation.

### Phase 4: Test realignment

Goal: make tests assert the approved two-slot behavior rather than the old three-lane independence behavior.

Tasks:

1. Rewrite `STTSchedulerTests` around:
   - reserved interactive slot for `dictation`
   - shared background slot for meeting + file jobs
   - background priority ordering
   - meeting-live backpressure
   - cancellation/quiesce behavior
2. Add or update tests for the accepted v1 tradeoff:
   - a running file transcription may delay later meeting STT on the background slot
3. Add onboarding tests that cover:
   - STT cached + diarization missing + offline -> preflight failure before false-ready
   - both cached -> offline success
4. Keep existing meeting lagging-state UI tests intact; that path is already wired.

Exit criteria:

1. Tests describe the approved target policy, not the superseded three-lane model.

### Phase 5: Final doc/code sync

Goal: make the docs stop needing “current branch implementation note” language once the code actually converges.

Tasks:

1. Remove or simplify the “current branch implementation note” blocks in:
   - `CLAUDE.md`
   - `spec/03-architecture.md`
   - `spec/06-stt-engine.md`
2. Re-check memory wording against the actual implementation that ships after convergence.
3. Update PR `#65` description if the implementation catches up to the docs during this pass.

Exit criteria:

1. Docs can describe the checked-out code directly again without caveats.

## Testing / Verification Checklist

### Required automated checks

1. `swift build`
2. `swift test`
3. Focused scheduler tests:
   - `swift test --filter STTSchedulerTests`
4. Focused onboarding tests:
   - `swift test --filter OnboardingViewModelTests`

### Recommended manual checks

1. Start file transcription, then start meeting recording:
   - dictation remains responsive
   - meeting preview/finalization behavior matches the accepted tradeoff
2. Meeting live preview under backlog:
   - lagging indicator appears
   - final saved meeting remains complete
3. Reset onboarding while offline with:
   - STT cached
   - diarization assets removed or unavailable
   Verify onboarding fails honestly before ready state

## Notes For The Next Agent

1. Do not re-open the architecture debate in this pass; ADR-016 is already locked to the two-slot target.
2. Do not spend time re-centralizing app wiring; that part is already done.
3. The real implementation work is:
   - topology convergence
   - onboarding/diarization readiness correctness
   - test realignment
4. The meeting lagging-state UI path is already wired end-to-end; do not redo it unless a regression appears.
5. If you need to preserve historical context, keep it in `plans/completed/2026-04-centralized-stt-runtime-scheduler.md`, not in active specs.
