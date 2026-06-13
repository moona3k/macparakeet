# Meeting VAD-Guided Live Chunking

> Status: **IMPLEMENTED** — shipped flag-on in v0.6.14 (`AppFeatures.meetingVadLiveChunkingEnabled = true`); archived 2026-06-12
> Date: 2026-05-29
> Scope: meeting live transcript chunk boundaries only.

## Implementation Status (2026-05-29)

Phases 1–4 are implemented behind `AppFeatures.meetingVadLiveChunkingEnabled`.
For the current release-candidate pass the flag is flipped **on** after Phase 0
and corpus replay showed clean inline performance; the fallback path remains the
fixed 5s / 1s live chunking via `FixedMeetingLiveAudioChunker`, byte-identical to
`AudioChunker`. The VAD path is exercisable in dev builds and fully unit-tested.

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
- **Model prep (Phase 4.5 — universal launch-time prep, IMPLEMENTED).**
  `MeetingVADModelPreparer` + `MeetingVADService.downloadModel` fetch the Silero
  VAD model, **only when `meetingVadLiveChunkingEnabled` is true**. The fetch now
  rides `AppDelegate.scheduleDeferredSpeechPreWarm` — the existing 1.5s-deferred,
  `.utility`, single-flight launch task that runs on **every launch for every
  user** — via the testable `MeetingVADLaunchPrep.run(featureEnabled:preparer:)`
  gate. So flipping the flag reaches the **whole installed base**, not just fresh
  installs, which is what makes default-on meaningful. The prep is idempotent
  (no-ops when `isModelReady()`), independent of the speech warm-up's own
  try/catch, and silent-fail: a download failure is logged + swallowed, the
  runtime falls back to fixed chunking, and the next launch retries (natural
  per-launch backoff). The **onboarding-only prep
  (`OnboardingViewModel.prepareMeetingVADModelIfNeeded`) and its injection through
  `OnboardingCoordinator` / `OnboardingWindowController` were deleted** — one prep
  path, and VAD is fully detached from `2026-05-dictation-first-onboarding.md`.
  (`.../Services/MeetingRecording/MeetingVADModelPreparer.swift`,
  `AppDelegate.scheduleDeferredSpeechPreWarm`)
  - **Telemetry:** `vad_model_prep` outcome event (`prepared` / `failed` only;
    `already_cached` and feature-off are silent to avoid per-launch spam).
    Two-repo allowlist: `"vad_model_prep"` added to `ALLOWED_EVENTS` in the
    website's `functions/api/telemetry.ts` and deployed to Cloudflare Pages
    production at website commit `65a32e9`
    (`83d90b72-ba62-4c26-86a6-d7b292d3e597`). If this event is removed or
    renamed later, keep the website Worker allowlist in lockstep or telemetry
    batches containing the event will be rejected.
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

**Phase 0 — DONE (2026-05-29, via `meeting-vad-sim` on a real 104-min meeting):**
Replayed both captured streams of a real meeting through the live path.
- **Mic stream** (6274s): VAD ran at **1553× realtime**, per-ingest p99=0.20ms /
  max=4.2ms, **0 VAD errors**, no fallback. 436 speech-aligned chunks (variable
  2–10s) vs 1569 rigid 5s fixed chunks. Diagnostics: 226 speech-end cuts, 256
  10s-cap force-emits, 289 dropped-silence windows.
- **System stream** (6238s, mostly silent): VAD ran at **1357× realtime**,
  max=11.6ms, **0 errors**; emitted only 8 chunks and dropped 618 silence
  windows (fixed would have produced ~1247 mostly-silent chunks) — a real
  efficiency win on system audio.
- **Verdict:** at >1300× realtime a live 1×-realtime source cannot back up the
  queue, so **VAD inference runs inline in the capture task** (no decoupled task
  needed — settles the #387 open architecture question). `.cpuOnly` confirmed
  sufficient; the `.cpuAndNeuralEngine` comparison is unnecessary given the
  headroom.

**Phase 0 — corpus breadth + false-negative check (2026-05-29, ~30 captured
meetings):** independent replay across the full local meeting corpus (single
streams, minutes to ~5 hours each) to extend the n=1 result above and verify VAD
isn't silently dropping speech.
- **Robustness at scale:** every stream ran clean — **0 VAD errors, 0 fallbacks**,
  uniformly **~1.3–1.6k× realtime**, worst-case per-ingest ~4–12ms. The inline
  verdict holds across the corpus, not just one meeting.
- **Three behavioral regimes** (all correct/desired): *conversational* cuts on
  natural pauses (one 176-min meeting: 2067 speech-end cuts, 8 dropped-silence);
  *presentation/monologue* hits the 10s cap (force-emit-dominated → ~10s windows);
  *listening/silent* drops silence instead of feeding it to STT.
- **False-negative check (the part #391 didn't cover):** a few system tracks
  emitted 0 chunks. Measuring input loudness (added a peak/RMS dBFS readout to
  `meeting-vad-sim`) showed these are genuinely silent — RMS **−48 to −75 dBFS**
  (silence + stray clicks that spike *peak* to "normal" but leave RMS near the
  floor) — vs a speech-dense control at **−27 dBFS** RMS / 2067 speech-ends. So
  VAD's empty output reflects silent input, **not dropped speech**: the default
  Silero threshold is sound and there's no false-negative problem. (Verdict keys
  on RMS, not peak — a lone click fools peak.)
- **Net:** corroborates the inline-in-capture decision and additionally validates
  *correctness* (no missed speech) across diverse real audio. Still unverified:
  live VAD-while-Parakeet contention and on-screen cadence feel — both need a real
  call (Phase 5 / enablement), not an offline replay.

**Done — reuse the `VadManager` across sessions** (was a deferred review item):
`MeetingRecordingService` now caches one `MeetingVADService` (`sharedVADService`,
loaded lazily via `liveVADService()`), so the CoreML model loads at most once per
app session instead of at every meeting start. Re-checks cheaply (file-existence)
while still nil, so a later session picks it up after launch-time prep fetches the model.

**Not yet done:**
- **Phase 5** — subjective live-preview feel on a real call (eyeball the cadence)
  is still the last human QA gate before tagging the flag-on build. The default
  is flipped for the release candidate, and `spec/05-audio-pipeline.md` /
  `spec/09-testing.md` now describe the VAD/fixed strategy split. The sim data
  above strongly supports it (speech-aligned, 0 errors over 104 min × 2 streams
  and the broader corpus), but the on-screen feel still needs a real-call smoke.
- **Sub-minimum speech-end then prolonged silence.** A <2.0s utterance keeps
  `sawSpeechSinceLastEmit` set, so a following long silence force-emits a mostly
  silent 10s chunk to live STT. Bounded and not data-loss (timestamps stay
  correct); the 256 mic force-emits above are mostly this + long monologue. A
  Phase 5 tuning target, not a blocker.

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

### 6. Universal VAD model availability (launch-time background prep)

**This is the gating enablement work — without it, turning VAD on reaches almost
no one.**

**The former gap.** Before Phase 4.5, the Silero model was fetched *only*
during the onboarding speech-engine warm-up
(`OnboardingViewModel.prepareMeetingVADModelIfNeeded`). Onboarding runs once
and never again — the coordinator gates on `onboarding.completedAtISO` — so the
model reached **new installs only**. Every already-onboarded user — essentially
the entire installed base — never acquired it, and the runtime
(`makeIfModelCached`, which *never* downloads by design) silently fell back to
fixed chunking for them. That is why Phase 4.5 moved prep to launch.

**Decision.** Prep the model in the **background on every launch, for all users**,
whenever the feature is on and the model is missing. The model is tiny (verified
~1.7s end-to-end, single-digit MB), so prepping it for users who never record a
meeting costs essentially nothing — one universal path beats scoping to meeting
users. This *subsumes* the onboarding-only prep.

**Integration — ride the existing deferred warm-up.**
`AppDelegate.scheduleDeferredSpeechPreWarm` (`AppDelegate.swift:511`) already runs
on every launch for every user: deferred 1.5s, `Task(priority: .utility)`,
single-flight. Append VAD prep to that task, after `sttRuntime.backgroundWarmUp()`:

```swift
// inside the existing deferred .utility task, after speech warm-up
if AppFeatures.meetingVadLiveChunkingEnabled,
   await environment.meetingVADModelPreparer.isModelReady() == false {
    do { try await environment.meetingVADModelPreparer.prepareModel() }
    catch { /* log + swallow; runtime falls back to fixed; retry next launch */ }
}
```

- **Own `try/catch`, independent of the speech warm-up**, so neither blocks the
  other.
- `prepareModel()` is **idempotent** (`MeetingVADModelPreparer` no-ops when
  `isModelCached()`), so the call is free once the model is present.
- **Silent-fail → fixed fallback** (the runtime already does this); a failed prep
  just retries on the next launch — natural per-launch backoff, no within-session
  hammering.

**Delete the onboarding-only prep.** Once launch prep covers everyone, remove
`OnboardingViewModel.prepareMeetingVADModelIfNeeded` (call site `:487`) and the
`meetingVADModelPreparer` injection through `OnboardingCoordinator` /
`OnboardingWindowController` / the onboarding ViewModel. One prep path instead of
two; also fully detaches VAD from the dictation-first onboarding plan
(`2026-05-dictation-first-onboarding.md`). (Leave `AppEnvironment`'s
`meetingVADModelPreparer` — the launch hook now consumes it.)

**Telemetry (implemented).** The whole point is reaching a population that's
invisible by default, so prep emits `vad_model_prep` only for the transitions
worth seeing: `prepared` (an install acquired the model) and `failed` (prep
failed and the next launch will retry). `already_cached`, feature-off, and
cancelled outcomes are intentionally silent to avoid per-launch telemetry spam.
The event name must be present in `macparakeet-website/functions/api/telemetry.ts`
`ALLOWED_EVENTS` before a flag-on build ships, or the Worker rejects the whole
batch.

**Network-awareness (optional, low priority).** A careful implementation skips the
silent download on metered / Low Data Mode connections (`NWPathMonitor.isExpensive`
/ `isConstrained`) and retries when unconstrained. For a ~couple-MB, ~1.7s model
this is nice-to-have, not a blocker — acceptable to defer past first enablement.

## Rollout Phases

### Phase 0: Benchmark and API spike

- Confirm `VadManager` initialization behavior when VAD assets are absent.
- Benchmark streaming VAD with `.cpuOnly` and `.cpuAndNeuralEngine`.
- Measure added live-preview latency while a meeting live chunk is also being
  transcribed.
- Decide whether first release is cached-only VAD, onboarding/model-repair prep,
  or launch-time prep. **Resolved in Phase 4.5: launch-time prep.**

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

- fixed mode remains the feature-off and fallback behavior
- VAD mode is exercisable in dev builds and tests
- pause/resume and source-alignment tests pass in both modes

### Phase 4.5: Universal VAD model availability (prerequisite for default-on) — IMPLEMENTED

The single most impactful piece — default-on without it reaches only fresh
installs. Implements **Design §6**.

- ✅ Idempotent VAD model prep appended to
  `AppDelegate.scheduleDeferredSpeechPreWarm` (after the speech warm-up), gated
  on `meetingVadLiveChunkingEnabled && !isModelReady()` via the testable
  `MeetingVADLaunchPrep.run(featureEnabled:preparer:)`, in its own swallowing
  path (never throws out of the launch task).
- ✅ Onboarding-only prep deleted
  (`OnboardingViewModel.prepareMeetingVADModelIfNeeded`, the
  `meetingVADModelPreparer` / `isMeetingVADLiveChunkingEnabled` ViewModel inputs,
  and the injection through `OnboardingCoordinator` / `OnboardingWindowController`).
  `AppEnvironment.meetingVADModelPreparer` retained — the launch hook consumes it.
- ✅ `vad_model_prep` telemetry outcome event (`prepared` / `failed`) +
  `"vad_model_prep"` added to the website `ALLOWED_EVENTS` and deployed to
  Cloudflare Pages production at website commit `65a32e9`
  (`83d90b72-ba62-4c26-86a6-d7b292d3e597`).

Exit criteria:

- ✅ full `swift test` — unit-tested via `MeetingVADLaunchPrepTests` (disabled /
  already-cached / prepared / failed-is-swallowed) and `TelemetryServiceTests`
  (outcome serialization + contract coverage). The flag-and-cache gate is tested
  without driving the launch timer.
- ⏳ dev smoke (manual, do at Phase 5 enablement): with the flag on and the model
  cache deleted, relaunch → the model is fetched in the background within
  seconds, then `isModelCached()` is true and a meeting uses VAD
  (`meeting_live_chunking_mode … mode=vad`).
- ⏳ offline relaunch → prep fails silently, meeting still starts on fixed
  chunking, next online relaunch fetches it.

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

### Model Prep (Phase 4.5)

- Launch prep no-ops when the model is already cached (`isModelReady() == true`
  → `prepareModel` not called). Use `MockMeetingVADModelPreparer`.
- Launch prep is skipped entirely when `meetingVadLiveChunkingEnabled` is false.
- A failing `prepareModel` is swallowed (no throw escapes the launch task) and
  leaves the app able to start a meeting on fixed chunking.
- Factor the flag-and-cache gate into a small testable function so the decision is
  unit-tested without driving `AppDelegate`.

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
  Mitigation: meeting start stays cached-only; launch-time prep is background,
  idempotent, and silent-fail.
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

- ~~Should VAD assets be prepared during onboarding/model repair, or should the
  first release use VAD only when the model already exists?~~ **RESOLVED** —
  neither. Prep in the background on **every launch for all users** (flag-on +
  uncached), riding `scheduleDeferredSpeechPreWarm`; onboarding-only prep strands
  the installed base. See **Design §6** / **Phase 4.5**.
- What initial max-duration gives the best live feel: 8s, 10s, or 14s?
- Should microphone and system sources use the same VAD thresholds?
- Should VAD mode be enabled only for Parakeet live chunks first, or also when a
  meeting is pinned to WhisperKit?
- Once echo suppression ships, should VAD fall back to raw mic or fixed chunks
  if the cleaned mic stream is unavailable?
