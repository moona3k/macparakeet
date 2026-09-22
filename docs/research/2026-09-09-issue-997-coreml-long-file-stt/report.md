# Long-file Parakeet STT dies on macOS 14 with a Core ML ML Program error

Date: 2026-09-09
Issues: [#997](https://github.com/moona3k/macparakeet/issues/997) (open),
[#995](https://github.com/moona3k/macparakeet/issues/995) (closed as duplicate)
App: 0.7.3 (`d6321f87`, build `20260717011712`)
Pin: FluidAudio **0.15.6** on current `main` (was 0.15.4 on 0.7.3). Default
`parallelChunkConcurrency` is still **4** in 0.15.6.
Method: GitHub feedback + Cloudflare D1 `macparakeet-telemetry` + FluidAudio
0.15.4 checkout under `.build/checkouts/FluidAudio` + MacParakeet STT path.
No hardware repro on this host (M4 Pro / macOS 26, disk full, googlevideo 403).

## Verdict

The YouTube video is valid. The user hit the same Parakeet TDT Core ML crash
four times in twenty minutes (local mp3, local mov, drag-drop mp3, YouTube).

The encoder never sees 55 minutes of audio. FluidAudio splits long files into
fixed **15 s / 240,000-sample** windows and, by default, runs **four of those
windows at once** on **the same** `MLModel` instances. FluidAudio's own
architecture notes say Core ML prediction is **not reentrant**. On macOS 14
that concurrent ANE use is the class of bug `ANEInferenceGate` was added to
stop ([#614](https://github.com/moona3k/macparakeet/pull/614) /
FluidAudio [#661](https://github.com/FluidInference/FluidAudio/issues/661)).
The gate wraps the outer `transcribe(audioURL:)` call. It does **not** wrap the
four inner chunk workers.

Production telemetry for 0.7.3 since 2026-08-10, jobs with
`audio_duration_seconds >= 3000`:

| Surface | macOS 14 success | macOS 14 failure | macOS 15+ success | macOS 15+ failure |
|---|---:|---:|---:|---:|
| file / YouTube / drag-drop | 2 | 33 | 1412 | 19 |
| meeting | 0 | 11 | 2836 | 23 |

Hour-class Parakeet TDT on Sonoma is ~0–6% successful. On Sequoia/Tahoe it is
~99%. That is not a bad sermon and not a YouTube CDN problem.

**Shipping 0.8.0 without `ParakeetTDTASRConfig` does not fix this.** Current
`main` pins FluidAudio 0.15.6; the default is still `parallelChunkConcurrency: 4`.

## What the reporter did

In-app feedback, both from `0.7.3` / macOS `14.6.1` / Apple M2 / US:

```
Transcription failed: Unable to compute the asynchronous prediction using ML Program.
It can be an invalid input data or broken/unsupported model.
```

[#995](https://github.com/moona3k/macparakeet/issues/995) at 16:24:25Z, no URL.
[#997](https://github.com/moona3k/macparakeet/issues/997) at 16:45:46Z with
`https://youtu.be/613IwdXRQT4` — public ~55 min sermon, duration **3311 s**.

0.7.3 telemetry does not store `error_detail` on `transcription_failed`, so D1
cannot repeat the Core ML string. The session timeline still matches the
toasts.

Two consecutive GUI sessions, same chip/OS/locale:

| UTC | Input | Audio | Wall | Stage |
|---|---|---|---|---|
| 16:23:24 | file `mp3` 10–100 MB | 3367 s | 12.8 s | `stt` fail |
| 16:23:31 | `model_loaded` Parakeet **v3** | | 37.6 s warm-up **success** | |
| 16:24:25 | filed #995 | | | |
| 16:24:55 | file `mov` ≥1 GB | 3376 s | 12.2 s | `stt` fail |
| 16:31:13 | drag-drop same `mp3` | 3367 s | 8.9 s | `stt` fail |
| 16:45:08 | YouTube | **3311.0 s** | | started |
| 16:45:19 | YouTube | 3311 s | 50.3 s | `stt` fail |
| 16:45:46 | filed #997 | | | |

`diarization_requested=true`, `diarization_applied=false` on every attempt.
Diarization never started. yt-dlp worked: the YouTube job recorded the true
video duration before STT threw.

The 8–13 s local walls are conversion of a 56-minute file to 16 kHz WAV, then
an immediate first Core ML batch. They are not “transcribed 8 seconds of
speech.” YouTube’s extra ~40 s is the 51 MB m4a download.

## Mechanism

### 1. MacParakeet hands FluidAudio a WAV and waits

File / YouTube / meeting finalize all convert to 16 kHz mono WAV, then call
`STTRuntime` → `AsrManager.transcribe(audioURL:)` under `ANEInferenceGate`:

```734:736:Sources/MacParakeetCore/STT/STTRuntime.swift
            let result = try await inferenceGate.withExclusiveAccess {
                try await manager.transcribe(audioURL, decoderState: &decoderState)
            }
```

Managers are created with the FluidAudio default config:

```2346:2347:Sources/MacParakeetCore/STT/STTRuntime.swift
                let loadedInteractiveManager = AsrManager(config: .default)
                let loadedBackgroundManager = AsrManager(config: .default)
```

Core ML errors map to `STTError.transcriptionFailed(localizedDescription)`,
which is exactly the toast prefix `Transcription failed: …`.

File/YouTube diarization failures are caught and the transcript still
completes. A diarization ANE fault cannot produce this toast. The job died
in STT.

### 2. The encoder window is 15 seconds, not 55 minutes

```8:12:.build/checkouts/FluidAudio/Sources/FluidAudio/Shared/ASRConstants.swift
    /// Maximum audio duration supported by CoreML encoder (seconds)
    public static let maxDurationSeconds: Double = 15.0
    /// Maximum audio samples supported by CoreML encoder (sampleRate × maxDurationSeconds)
    public static let maxModelSamples: Int = 240_000
```

3311 s × 16 kHz = 52,976,000 samples. That is ~221 encoder windows. Anything
over `streamingThreshold` (480,000 samples, ~30 s) uses disk-backed
`ChunkProcessor`. Each Core ML call is padded to shape `[1, 240000]`.

Default visible chunk with `melChunkContext = true`:

| Quantity | Samples | Seconds |
|---|---:|---:|
| Encoder window | 240,000 | 15.00 |
| Visible chunk | 238,080 | 14.880 |
| Overlap | 32,000 | 2.000 |
| Stride | 206,080 | 12.880 |
| Chunks for 3311 s | 258 | |

The whole-file-as-one-tensor hypothesis is false.

### 3. Default is four workers sharing one compiled model

```70:79:.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/AsrTypes.swift
        parallelChunkConcurrency: Int = 4,
        ...
        self.parallelChunkConcurrency = max(1, parallelChunkConcurrency)
```

```96:99:.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrManager.swift
    internal func makeWorkerClone() -> AsrManager? {
        guard let models = asrModels else { return nil }
        return AsrManager(config: config, models: models)
    }
```

The clone copies the **same** `preprocessor` / `encoder` / `decoder` / `joint`
`MLModel` references. `ChunkProcessor.makeWorkerPool` builds four
`AsrManager` actors on those shared models, then a `ThrowingTaskGroup`
runs four `transcribeChunk` calls at once.

Preprocessor and encoder use the async Core ML API:

```30:32:.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrManager+Pipeline.swift
            let preprocessorOutput = try await preprocessorModel.compatPrediction(
                from: preprocessorInput,
                options: predictionOptions
            )
```

`compatPrediction` is `try await prediction(from:options:)`. Apple wraps ANE
`processRequest` failures as:

> Unable to compute the **asynchronous** prediction using ML Program.
> It can be an invalid input data or broken/unsupported model.

Decoder/joint use sync `prediction`, which would say “the prediction”, not
“the asynchronous prediction.” The toast therefore points at preprocessor or
encoder, i.e. the first STT inference, not a later merge step.

Compute units default to `.cpuAndNeuralEngine`.

### 4. FluidAudio already says this is unsafe

From FluidAudio `Documentation/Architecture.md`:

> CoreML's `MLModel` load and prediction APIs are async but **not
> reentrant** concurrent calls can corrupt internal scratch buffers.
> Actor isolation serializes access without manual locking.

Actor isolation is **per `AsrManager`**. Four clones are four actors. They do
not serialize `MLModel.prediction`. FluidAudio's long-form doc even states
the clones “reuse the already-loaded encoder/decoder/joint Core ML models.”
Their 4-wide speedup numbers were measured on M3, not M2 + Sonoma 14.6.1.

`ANEInferenceGate` exists because macOS 14 ANE SIGBUS'd when two inferences
overlapped (dictation vs file, or STT vs diarization). It is a process-wide
mutex around the **outer** call, and a no-op on macOS 15+:

```40:42:Sources/MacParakeetCore/Services/ANEInferenceGate.swift
    public static var serializationRequiredForCurrentOS: Bool {
        if #available(macOS 15.0, *) { false } else { true }
    }
```

Inside the gated `transcribe(audioURL:)`, macOS 14 still runs four ANE
predictions at once. The gate cannot see them.

### 5. Why 8–13 seconds, and why four containers failed the same way

Order of work:

1. MacParakeet ffmpeg → 16 kHz mono WAV (~106 MB for 56 min). Dominates the
   local 8–13 s.
2. FluidAudio resamples that WAV to a disk-backed float32 `.raw` (~202 MB) and
   mmaps it.
3. Four workers immediately run encoder windows 0 / 12.88 / 25.76 / 38.64 s.
4. First async `prediction` throws. Task group cancels the rest.
5. Diarization never runs.

mp3, mov, and YouTube m4a all reach step 3 as the same WAV shape, so they
fail the same way. Model load already succeeded, so this is not a broken
`.mlmodelc` on disk.

Short dictation never takes this path: clips ≤ 15 s are a single padded
window on one `AsrManager`. That matches “dictation works, hour files die.”

## Telemetry

Queries and tables: [evidence/d1-queries.md](evidence/d1-queries.md).

Since 2026-08-10 on 0.7.3, `STTError.transcriptionFailed` at stage `stt`:
72 meeting, 45 file, 13 drag-drop, 7 YouTube, 1 podcast (event counts).

Duration for file/YouTube/drag-drop with that error type: 35 of 65 events are
≥ 60 min; 11 more are 30–60 min. Typical wall clock on the hour-class
Sonoma failures is **7–15 s**, same as #997.

The OS split for **all** hour-class file/YouTube/drag-drop operations (any
error type) is the decisive result: Sonoma almost never completes; 15+ almost
always does. Hour-class **meetings** on Sonoma: **zero** successes in that
window. Same STT function, same chunk pool.

This is a platform bug in our configuration, not a one-user sermon.

## Ruled out

| Hypothesis | Why not |
|---|---|
| Invalid / private YouTube URL | Public 3311 s video; job recorded that duration; local mp3/mov failed first |
| yt-dlp / 403 / sign-in | Download completed; #310 is a different failure |
| Diarization ANE fault | Caught; transcript would complete; `stage=stt` |
| Whole file as one Core ML tensor | Encoder hard-limit 240k samples; 258 chunks |
| Corrupt Parakeet v3 weights | `model_loaded` / warm-up succeeded in 37.6 s |
| Chunk-seam quality bugs (FluidAudio #212, #747) | Missing words or blank last window, not a throw at t=0 |
| macOS 26 ANE compiler (FluidAudio PR #482) | Reporter is 14.6.1 |
| Idle-first-prediction (VoiceInk #614) | Four retries in 20 minutes all failed |
| [#883](https://github.com/moona3k/macparakeet/issues/883) E5RT zero-shape | Post-success log on macOS 26 CLI / Unified; different error |

Related but different: FluidAudio [#320](https://github.com/FluidInference/FluidAudio/issues/320)
is the same OS (14.6.1) and model (v3 TDT) with E5RT/IOSurface allocation
failure **later** in a long sequential run (`chunk 80/160`). Same ANE family,
not the 8 s first-batch signature. [#661](https://github.com/FluidInference/FluidAudio/issues/661)
is the concurrent-prediction SIGBUS that `ANEInferenceGate` targeted at the
wrong granularity.

## What 0.8.0 does and does not change

Still true on current main / freeze:

- `Package.swift` exact FluidAudio `0.15.4`
- `AsrManager(config: .default)` → `parallelChunkConcurrency = 4`
- `ANEInferenceGate` still outer-only, still no-op on 15+
- Current main **does** attach sanitized `error_detail` on
  `transcription_failed`. 0.7.3 did not. After 0.8.0 ships, D1 should show
  the ML Program string on new events.

No FluidAudio 0.15.5/0.15.6 release notes a fix for this throw. Those
releases are diarization/quality. Do not treat a pin bump as the repair.

## Repair

`ParakeetTDTASRConfig.make()` returns `ASRConfig(parallelChunkConcurrency: 1)`
when `ANEInferenceGate.serializationRequiredForCurrentOS` is true, otherwise
`ASRConfig.default`. Both TDT `AsrManager`s in `STTRuntime.ensureInitialized`
use that config.

Concurrency 1 still uses `ChunkProcessor`; it only collapses the pool to the
calling manager. FluidAudio documents this as the pre-parallel behavior.
Hour-class Sonoma jobs should complete instead of throwing; they are slower
than the 4-wide 15+ path (FluidAudio measured ~2.2–2.8× speedup from 4-wide
on M3).

If concurrency 1 still throws on 14, the next lever is encoder
`computeUnits: .cpuAndGPU`. Do not do that first.

Do not “fix” this by splitting files in the UI. The model already chunks.

0.8.0+ `error_detail` on `transcription_failed` will show the ML Program
string on new events. 0.7.3 did not store it.

## How to confirm on hardware

Needs a macOS 14 Apple Silicon Mac (M2 preferred). This investigation host
cannot: googlevideo 403, ~197 MB free, and it is macOS 26 where the job
would likely succeed anyway.

1. Isolated state (`MACPARAKEET_DEBUG_APP_STATE_DIR` on debug builds) so
   production databases are untouched.
2. 20 s clip of the same sermon → expect success (single window).
3. Full ~55 min file, Parakeet v3, speaker detection off, **before this
   fix** → expect STT throw in ~10 s after conversion with concurrency 4.
4. Same file **after this fix** (`parallelChunkConcurrency: 1` on macOS 14)
   → expect completion (wall clock ~55 min / ~80× ≈ 40 s plus conversion,
   not 10 s).
5. Repeat on macOS 15+ with default 4 → expect success (telemetry already
   shows this).

## Limits

- No local Core ML throw captured on this machine.
- 0.7.3 D1 rows have no `error_detail`; the ML Program string is only in
  GitHub feedback. Attribution to preprocessor/encoder async prediction is
  from FluidAudio call sites plus Apple’s wording, not a captured
  `NSUnderlyingError`.
- The two macOS 14 file successes (one session) were not inspected
  chunk-by-chunk; they do not change the 94% failure rate.
- Unified / Nemotron / Whisper / Cohere paths were not part of this
  reporter’s job (`engine_variant` v3 TDT). They may or may not share the
  4-wide pool.

## Sources

- GitHub [#997](https://github.com/moona3k/macparakeet/issues/997),
  [#995](https://github.com/moona3k/macparakeet/issues/995)
- D1 `macparakeet-telemetry`, queries in
  [evidence/d1-queries.md](evidence/d1-queries.md)
- FluidAudio 0.15.4: `ASRConstants.swift`, `AsrTypes.swift`,
  `AsrManager.swift`, `ChunkProcessor.swift`, `AsrManager+Pipeline.swift`,
  `Documentation/Architecture.md`, `Documentation/ASR/LongTranscription.md`
- MacParakeet: `STTRuntime.swift`, `ANEInferenceGate.swift`,
  `TranscriptionService.swift`, `STTClientProtocol.swift`,
  `TelemetryEvent.swift`
- FluidAudio [#661](https://github.com/FluidInference/FluidAudio/issues/661),
  [#320](https://github.com/FluidInference/FluidAudio/issues/320)
- MacParakeet [#614](https://github.com/moona3k/macparakeet/pull/614)
