# Meeting VAD-Guided Live Chunking

> Status: ACTIVE PLAN — Phases 1–4 IMPLEMENTED (flag-off)
> Date: 2026-05-29
> Scope: meeting live transcript chunk boundaries only.

## Implementation Status (2026-05-28)

Phases 1–4 are implemented behind `AppFeatures.meetingVadLiveChunkingEnabled`,
which defaults to **`false`** — production behavior is unchanged (fixed 5s / 1s
live chunking via `FixedMeetingLiveAudioChunker`, byte-identical to
`AudioChunker`). The VAD path is exercisable in dev builds and fully unit-tested.

- **Phase 1** — `MeetingLiveAudioChunking` protocol + `MeetingLiveChunkingDiagnostics`
  + `FixedMeetingLiveAudioChunker`; `CaptureOrchestrator` now depends on the
  abstraction. (`Sources/MacParakeetCore/Audio/MeetingLiveAudioChunking.swift`)
- **Phase 2** — `SpeechBoundaryMeetingLiveAudioChunker` actor with contiguous
  sample accounting, speech-end cuts, chunker-owned 2.0s/10.0s bounds,
  force-emit tail overlap, flush, reset, and degraded fixed-fallback on repeated
  VAD errors. Deterministic tests via a fake VAD (no FluidAudio models loaded).
  (`.../Audio/SpeechBoundaryMeetingLiveAudioChunker.swift`,
  `Tests/.../Audio/SpeechBoundaryMeetingLiveAudioChunkerTests.swift`)
- **Phase 3** — `MeetingVADService` (FluidAudio `VadManager` adapter) with
  cached-only, non-blocking init (`makeIfModelCached`, `.cpuOnly` default) and
  MacParakeet-owned `MeetingVoiceActivityDetecting` / `MeetingVAD*` types.
  (`.../Services/MeetingRecording/MeetingVADService.swift`)
- **Phase 4** — flag + `MeetingRecordingService.configureLiveChunkers(for:)`
  picks fixed vs speech-boundary per session (VAD only for cached-model Parakeet
  sessions; per-source fixed fallback otherwise), with `meeting_live_chunking_mode`
  diagnostics.
- **Model prep** — `MeetingVADModelPreparer` + `MeetingVADService.downloadModel`
  fetch the Silero VAD model during the onboarding speech-engine warm-up, **only
  when `meetingVadLiveChunkingEnabled` is true** and on the Parakeet path (VAD is
  gated to Parakeet sessions). Failure is logged + swallowed (warm-up still
  completes; runtime falls back to fixed). This makes the flag meaningfully
  flippable: flip → relaunch → model fetched → `makeIfModelCached()` starts
  succeeding. (`.../Services/MeetingRecording/MeetingVADModelPreparer.swift`,
  `OnboardingViewModel.prepareMeetingVADModelIfNeeded`)
  - **Verified end-to-end (2026-05-28, headless):** `downloadModel()` fetches the
    Silero model to `Models/silero-vad/` (the `repo.folderName` path the pinned
    FluidAudio `VadManager` actually loads from — `isModelCached()` uses the same
    path, so they agree; an older `silero-vad-coreml/` cache dir from a prior
    FluidAudio version is unrelated) in ~1.7s, after which `isModelCached()`
    flips true. Driving the **real** Silero model through
    `SpeechBoundaryMeetingLiveAudioChunker` with synthesized speech (two
    sentences split by a 1.5s pause) cut at the pause: 2 contiguous chunks, 1
    speech-end, 0 force-emits, 0 VAD errors, no fallback. Confirms the live path
    is correct against the real model, not just the fake-VAD unit tests.

**Not yet done (need hardware / live meetings):**
- **Phase 0** — `.cpuOnly` vs `.cpuAndNeuralEngine` benchmark + live-latency
  measurement. The service currently defaults to `.cpuOnly`. (The
  cached-only-vs-prepare-during-onboarding decision is now settled: prepare
  during onboarding, flag-gated — see "Model prep" above.)
- **Phase 5** — real-meeting threshold tuning and the default-on decision; only
  then update `spec/05-audio-pipeline.md` / `spec/09-testing.md`.

**Review findings deferred to enablement (multi-AI convergence on PR #387):**
- **Reuse the `VadManager` across sessions.** `makeIfModelCached` loads the
  CoreML model on every `startRecording()`. Harmless while the flag is off (no
  model on disk), but once the model is cached (follow-up model-prep PR) this
  adds a synchronous load to each meeting start — cache one `MeetingVADService`
  on `MeetingRecordingService` and reuse it.
- **Sub-minimum speech-end then prolonged silence.** A <2.0s utterance keeps
  `sawSpeechSinceLastEmit` set, so a following long silence force-emits a mostly
  silent 10s chunk to live STT. Bounded and not data-loss (timestamps stay
  correct), but a Phase 5 tuning target.

## Problem

Meeting recording currently feeds the live transcript preview with fixed
`AudioChunker` windows: 5 seconds of audio with 1 second of overlap. This is
simple and robust, but fixed windows can split active speech in the middle of a
sentence, enqueue silence-heavy chunks, and make the live preview feel choppier
than the final transcript.

The final transcript path is already safer than the live preview path:
MacParakeet re-transcribes retained `microphone.m4a` and `system.m4a` source
files after recording stops, then merges those source-aware results by persisted
alignment. This plan must not change that final path.

## Goals

- Cut meeting live-preview chunks at speech boundaries when VAD is available.
- Keep fixed 5s chunking as the fallback path.
- Preserve sample-time chunk timestamps and pause/resume monotonicity.
- Keep microphone and system chunkers source-specific and alignment-safe.
- Reduce live STT work on silence-heavy windows.
- Improve live transcript coherence without changing retained audio, final STT,
  or meeting storage.
- Make VAD availability, fallback, and chunk boundary reasons visible in
  diagnostics.

## Non-Goals

- No final transcript repair, coverage audit, or VAD-based mutation of saved
  transcripts.
- No change to `TranscriptionService.transcribeMeetingAudio`.
- No change to retained source files: `microphone.m4a`, `system.m4a`, and
  `meeting.m4a` remain as they are.
- No user-facing setting in the first implementation.
- No re-enable of VPIO, Core Audio process taps, or capture teardown on pause.
- No direct feature ownership of FluidAudio APIs outside a small adapter.

## Verified Current State

- `AudioChunker` is the current live-preview chunker. It emits one 5s chunk once
  80,000 samples are buffered at 16 kHz, retains 16,000 samples of overlap, and
  drops tails shorter than 8,000 samples.
- `CaptureOrchestrator` owns the live path's join, conditioning, and per-source
  chunkers. It feeds both mic and system chunkers on every joined pair so
  sample-position counters stay lockstep even when one source is silence-padded.
- Pause/resume intentionally does not reset `CaptureOrchestrator` or
  `AudioChunker`; resetting would zero `totalSamplesProcessed` and cause
  post-resume live chunks to be filtered as duplicates.
- `LiveChunkTranscriber` accepts `AudioChunker.AudioChunk`, writes a temporary
  16 kHz WAV, routes through the meeting's captured speech engine, and reports
  ordered results or backpressure drops.
- FluidAudio 0.14.5 is pinned in `Package.resolved` and exposes:
  - `VadManager.sampleRate == 16000`
  - `VadManager.chunkSize == 4096` samples, or 256 ms (model input is 4096 new
    samples + 64-sample context = 4160; the manager pads/truncates internally if
    you hand it a different size, but the streaming state advances by the count
    you pass, so feeding non-`chunkSize` windows desyncs the timeline)
  - `VadManager.makeStreamState()`
  - `VadManager.processStreamingChunk(_:state:config:returnSeconds:timeResolution:)`
  - `VadStreamEvent(kind:sampleIndex:time:)` — the boundary `sampleIndex` is
    **retroactive** (points back to where speech started/ended, minus padding),
    not the current ingest position
  - `VadSegmentationConfig` exists with min speech, min silence, max speech,
    padding, and hysteresis thresholds, **but the streaming state machine only
    reads `speechPadding`, `minSilenceDuration`, and the
    `negativeThreshold`/`negativeThresholdOffset` hysteresis** (verified in
    `VadManager+Streaming.swift:40-91`). `maxSpeechDuration`, `minSpeechDuration`,
    and `silenceThresholdForSplit` are **inert in streaming mode** — they only
    affect the batch `segmentSpeech` path. Streaming `speechEnd` fires *only* on
    real silence; FluidAudio never force-splits a long monologue.
- MacParakeet currently prepares ASR and diarization assets, but there is no
  MacParakeet-owned VAD service or VAD model readiness surface.

## Design

### 1. Add a MacParakeet-owned live chunking abstraction

Keep product code independent of any one VAD implementation:

```swift
protocol MeetingLiveAudioChunking: Sendable {
    func addSamples(_ samples: [Float]) async -> [AudioChunker.AudioChunk]
    func flush() async -> AudioChunker.AudioChunk?
    func reset() async
    var diagnostics: MeetingLiveChunkingDiagnostics { get async }
}
```

The existing fixed-window behavior becomes `FixedMeetingLiveAudioChunker`, a
thin adapter around `AudioChunker`. This keeps the fallback path testable and
lets `CaptureOrchestrator` depend on one shape.

`addSamples` returns an array, not an optional single chunk. The current path
usually emits at most one chunk per ingest, but a boundary-driven chunker should
not bake that assumption into the abstraction.

### 2. Add a speech-boundary chunker

Introduce `SpeechBoundaryMeetingLiveAudioChunker`, an actor that maintains:

- `totalSamplesSeen`
- `lastEmittedSample`
- buffered 16 kHz samples
- pending VAD input samples
- current `VadStreamState`
- recent VAD probabilities for diagnostics only
- fallback/error counters

VAD input must be fed in exact `VadManager.chunkSize` (4096-sample) windows. Do
not pass arbitrary buffer sizes to `processStreamingChunk`, because FluidAudio
pads or truncates model input internally while the streaming state advances by
the caller-provided sample count — mismatched sizes desync the boundary
timeline. Buffer incoming samples and feed them in exact 4096-sample slices,
holding the remainder for the next ingest.

**The chunker — not FluidAudio — owns the min and max chunk bounds.** As noted
in Verified Current State, the streaming state machine ignores
`maxSpeechDuration`/`minSpeechDuration`/`silenceThresholdForSplit`. So the
config below only carries the knobs that actually affect streaming, and the
2.0s minimum and 10.0s maximum are enforced by the chunker's own sample
counters.

Initial live config (only streaming-relevant knobs):

```swift
VadSegmentationConfig(
    minSilenceDuration: 0.50,   // silence before a speechEnd fires
    speechPadding: 0.15         // padding folded into the retroactive boundary index
    // negativeThreshold / negativeThresholdOffset: tune in Phase 5 for sensitivity
)
// NOTE: minSpeechDuration, maxSpeechDuration, and silenceThresholdForSplit are
// INERT in streaming mode. Do not rely on them — the chunker enforces min/max.
```

Initial chunking policy (enforced by the chunker):

- **Contiguous sample accounting (v1).** Chunks tile the recording with no gaps:
  each emitted chunk's audio is exactly the buffered slice
  `[lastEmittedSample, cutSample)`, and `lastEmittedSample` advances to
  `cutSample` on every emit. Silence between utterances becomes leading silence
  of the next chunk (minor STT cost, no correctness cost). Do **not** excise
  silence from the timeline — see the timestamp note below for why.
- **Cut at the retroactive `speechEnd` sample.** When a `speechEnd` event
  arrives, the cut point is `event.sampleIndex` (which points into the past),
  not the current ingest position. Emit `[lastEmittedSample, event.sampleIndex)`
  and retain the samples after it for the next chunk.
- Do not emit silence-only output: if no `speechEnd` has arrived and the buffer
  since `lastEmittedSample` is all silence, keep buffering rather than emitting.
- Do not emit a speech-end chunk shorter than 2.0 seconds unless `flush()` is
  called at stop; keep buffering and let the next `speechEnd` extend it.
- Force emit at 10.0 seconds (chunker sample counter, the *only* max mechanism)
  even if no `speechEnd` has arrived, to keep live preview latency bounded.
- Keep a small tail overlap, initially 250 ms, when force-emitting long speech
  (a forced cut lands mid-word, so re-feed the tail; speech-end cuts land in
  silence and need no overlap).
- On `flush()`, emit any remaining chunk with at least 0.5 seconds of audio and
  detected speech; otherwise drop it.

The chunk timestamps must be derived from sample counters. Under contiguous
accounting the first sample of each chunk is exactly `lastEmittedSample`:

```text
startMs = lastEmittedSample * 1000 / 16000     // == first sample of THIS chunk
endMs   = cutSample          * 1000 / 16000
```

No wall-clock `Date` or `hostTime` should be used for chunk timestamps.

> **Why contiguous accounting matters.** `MeetingTranscriptAssembler` places
> words at `chunk.startMs + wordRelativeMs` and dedups by absolute `endMs`
> (`MeetingTranscriptAssembler.swift:60-73`). It is overlap-agnostic, so
> variable/zero overlap is safe — *but only if `chunk.startMs` equals the true
> absolute position of the chunk's first sample.* If the chunker skipped silence
> gaps and still computed `startMs = lastEmittedSample`, it would understate the
> position and the new chunk's early words could land at `endMs <= cutoff` and be
> **silently dropped** from the live preview. Contiguous accounting keeps
> `startMs = lastEmittedSample` correct and avoids that bug.

### 3. Add a VAD service adapter

Add a small actor in Core, for example `MeetingVADService`, that owns
`VadManager` lifecycle behind a MacParakeet-owned protocol. The product-facing
types should not expose FluidAudio's `VadStreamState` or `VadStreamResult`
directly:

```swift
struct MeetingVADStreamState: Sendable { /* adapter-owned storage */ }

struct MeetingVADResult: Sendable {
    let state: MeetingVADStreamState
    let event: MeetingVADEvent?
    let probability: Float
}

enum MeetingVADEvent: Sendable {
    case speechStart(sampleIndex: Int)
    case speechEnd(sampleIndex: Int)
}

protocol MeetingVoiceActivityDetecting: Sendable {
    func makeStreamState() async -> MeetingVADStreamState
    func processStreamingChunk(
        _ samples: [Float],
        state: MeetingVADStreamState,
        config: MeetingVADConfig
    ) async throws -> MeetingVADResult
}
```

`MeetingVADConfig` should mirror only the knobs that actually affect streaming
(`minSilenceDuration`, `speechPadding`, and optionally `negativeThreshold` /
`negativeThresholdOffset` for sensitivity tuning). The FluidAudio adapter maps
those to `VadSegmentationConfig` and leaves the inert segmentation knobs at
their defaults. The min/max chunk bounds are **not** VAD config — they live in
`SpeechBoundaryMeetingLiveAudioChunker` as sample counters.

The first implementation should be conservative:

- Use VAD only when the VAD model is already available or can initialize quickly.
- If VAD initialization fails, fall back to fixed chunking for the session.
- If streaming VAD fails repeatedly during a session, fall back to fixed chunking
  for that source and record diagnostics.
- Do not block meeting start on VAD model download.

Compute-unit choice must be benchmarked before enabling by default. VAD is small
but runs frequently; the plan should compare `.cpuOnly` and
`.cpuAndNeuralEngine` against live STT latency. Prefer CPU-only if it is fast
enough and avoids ANE contention with Parakeet.

### 4. Integrate through `CaptureOrchestrator`

Replace the two concrete `AudioChunker` fields with two
`MeetingLiveAudioChunking` instances:

```swift
private var microphoneChunker: any MeetingLiveAudioChunking
private var systemChunker: any MeetingLiveAudioChunking
```

The orchestrator must preserve existing invariants:

- every drained `MeetingAudioPair` feeds both chunkers
- silence-padded absent sources still advance the corresponding chunker
- mic conditioning happens before microphone chunking
- system audio chunking remains source-specific
- `reset()` resets pair joiner and both chunkers
- `flushChunkers()` flushes both sources

The active echo-suppression plan wants cleaned mic samples to drive live mic
VAD/STT. This plan should integrate at the same seam: the microphone chunker
receives the already-conditioned mic samples from `MicConditioning`.

> **Sequencing dependency.** Three active plans touch the
> `CaptureOrchestrator.ingest` mic-conditioning seam: this one,
> `2026-05-meeting-neural-echo-suppression.md`, and
> `2026-05-silent-buffer-fallback.md`. VAD consumes the *post-conditioning* mic
> stream, so it is compatible with echo suppression, but the two should not
> refactor `ingest` simultaneously. Land (or branch from) the echo-suppression
> conditioner change first, then tap its output here. Coordinate before parallel
> implementation.

### 5. Diagnostics

Add private diagnostics, not user-visible text, for:

```text
meeting_live_chunking_mode source=microphone mode=vad|fixed reason=started|fallback|vad_unavailable|vad_error
meeting_live_chunk_boundary source=system mode=vad reason=speech_end|max_duration|flush start_ms=<n> end_ms=<n> duration_ms=<n>
meeting_live_vad_stats source=microphone chunks_processed=<n> speech_start=<n> speech_end=<n> force_emit=<n> dropped_silence=<n> fallback=<bool>
```

Do not log transcript text, audio paths, device names, model paths, or raw
sample values.

Telemetry should wait until the diagnostic shape is proven useful. If telemetry
is added later, keep it aggregated and privacy-safe.

## Rollout Phases

### Phase 0: Benchmark and API spike

- Confirm `VadManager` initialization behavior when VAD assets are absent.
- Benchmark streaming VAD with `.cpuOnly` and `.cpuAndNeuralEngine`.
- Measure added live-preview latency while a meeting live chunk is also being
  transcribed.
- Decide whether first release is cached-only VAD or prepares VAD assets during
  onboarding/model repair.

Exit criteria:

- documented compute-unit choice
- documented model-readiness behavior
- no plan to block meeting start on VAD download

### Phase 1: Abstraction and fixed adapter

- Add `MeetingLiveAudioChunking`.
- Wrap current `AudioChunker` as `FixedMeetingLiveAudioChunker`.
- Update `CaptureOrchestrator` to use the abstraction with fixed mode only.
- Keep behavior identical to current fixed 5s chunking.

Exit criteria:

- existing `AudioChunkerTests`, `CaptureOrchestratorTests`, and
  meeting-recording tests still pass
- no live chunk timing behavior changes yet

### Phase 2: Speech-boundary chunker with fake VAD

- Implement `SpeechBoundaryMeetingLiveAudioChunker` against a fake
  `MeetingVoiceActivityDetecting` test double.
- Cover speech start/end, silence-only input, max-duration force emits, flush,
  reset, VAD errors, and overlap.
- Verify timestamps stay sample-counter-derived and monotonic.

Exit criteria:

- deterministic unit tests cover the boundary state machine without loading
  FluidAudio models
- no dependency on wall-clock timers

### Phase 3: FluidAudio VAD adapter

- Add `MeetingVADService` backed by `VadManager`.
- Add cached/available checks or a nonblocking initialization strategy.
- Add per-session fallback to fixed chunking when VAD is unavailable.
- Keep VAD model lifecycle separate from `STTScheduler`; do not instantiate a
  second STT runtime or bypass ADR-016.

Exit criteria:

- VAD unavailable path starts meetings normally
- VAD errors do not fail capture
- diagnostics clearly show fixed fallback

### Phase 4: Orchestrator integration behind a feature flag

- Add an internal feature flag, for example
  `AppFeatures.meetingVadLiveChunkingEnabled`.
- When disabled, construct fixed chunkers.
- When enabled and VAD is available, construct speech-boundary chunkers.
- Keep source-specific mode decisions, so one source can fall back without
  forcing the other source to fall back.

Exit criteria:

- fixed mode remains current production behavior
- VAD mode is exercisable in dev builds and tests
- pause/resume and source-alignment tests pass in both modes

### Phase 5: Release hardening

- Tune thresholds with real meetings and synthetic fixtures.
- Decide whether to enable by default.
- If default-on, document fallback behavior in `spec/05-audio-pipeline.md`.
- Update `spec/09-testing.md` with VAD live chunk test coverage.

Exit criteria:

- full `swift test`
- `git diff --check`
- dev app smoke:
  - start meeting
  - verify live transcript appears after natural pauses
  - pause/resume
  - dictate during meeting
  - stop meeting and verify final transcript still uses source-file STT
- real call smoke on Zoom or Google Meet

## Test Plan

### Unit Tests

- Fixed adapter preserves current 5s/1s-overlap behavior.
- Speech-boundary chunker does not emit silence-only chunks.
- Speech-boundary chunker emits on speech end after minimum duration.
- Speech-boundary chunker does not emit sub-minimum fragments during normal
  streaming.
- Speech-boundary chunker force-emits at max duration.
- Force-emitted long speech keeps bounded overlap and monotonic timestamps.
- `flush()` emits a valid spoken tail and drops a silent/tiny tail.
- `reset()` clears buffer, stream state, and counters.
- VAD failure switches to fixed fallback without throwing out of the live
  capture path.
- Returned chunk `startMs`/`endMs` are sample-counter-based.

### Orchestrator Tests

- Both sources remain lockstep during paired input.
- Mic-only stretches still advance the system chunker with silence padding.
- System-only stretches still advance the mic chunker with silence padding.
- Mic conditioning output feeds the microphone VAD chunker.
- `flushPendingPairs` and `flushChunkers` preserve final live tail behavior.
- Pause/resume does not reset chunk timestamps.

### Meeting Service Tests

- VAD chunk mode enqueues fewer or equal silence-only live chunks than fixed
  mode.
- Low-signal and system-dominant mic chunk drops still apply after VAD chunking.
- Backpressure drops remain nonfatal.
- Stop cancels or drains pending live chunk tasks as today.
- Final transcription path is unchanged.

### Manual Validation

- Quiet room, local monologue.
- Remote-only meeting audio.
- Double-talk: local speaker talks over remote speaker.
- Long monologue over 60 seconds.
- Long silence between remarks.
- Pause/resume during an unfinished speech segment.
- Dictation during active meeting.
- VAD model absent or deleted before meeting start.
- Output-device switch during meeting remains nonfatal.

## Acceptance Criteria

- With VAD enabled and available, live chunks are emitted due to speech end,
  max duration, or stop flush; not solely every fixed 5 seconds.
- With VAD unavailable, live chunking falls back to the existing fixed behavior
  and the meeting still starts.
- Final saved transcript, retained audio files, source alignment, crash
  recovery, and export artifacts are unchanged by this plan.
- Chunk timestamps remain monotonic across pause/resume.
- Live transcript preview does not regress under STT backpressure.
- Diagnostics can answer whether a session used VAD, fixed fallback, or changed
  modes mid-session.

## Risks

- VAD model initialization could add hidden meeting-start latency.
  Mitigation: cached-only or nonblocking initialization in the first release.
- VAD inference could contend with Parakeet on ANE.
  Mitigation: benchmark compute units and prefer CPU-only if acceptable.
- VAD false negatives could delay live preview.
  Mitigation: max-duration force emit and fixed fallback after repeated errors.
- System audio can include non-speech sounds.
  Mitigation: low-signal filtering remains; final STT remains authoritative.
- Variable chunk lengths are largely safe: `MeetingTranscriptAssembler` is
  overlap-agnostic (placement + dedup are absolute-timestamp-based,
  `MeetingTranscriptAssembler.swift:60-73`). The real, narrow risk is a
  `startMs` that does not equal the chunk's true first-sample position, which
  drops words below the dedup cutoff.
  Mitigation: contiguous sample accounting (Design §2) guarantees
  `startMs == lastEmittedSample`; add a test asserting no live words are dropped
  across a speech-end cut and across a force-emit overlap.

## Open Questions

- Should VAD assets be prepared during onboarding/model repair, or should the
  first release use VAD only when the model already exists?
- What initial max-duration gives the best live feel: 8s, 10s, or 14s?
- Should microphone and system sources use the same VAD thresholds?
- Should VAD mode be enabled only for Parakeet live chunks first, or also when a
  meeting is pinned to WhisperKit?
- Once echo suppression ships, should VAD fall back to raw mic or fixed chunks
  if the cleaned mic stream is unavailable?
