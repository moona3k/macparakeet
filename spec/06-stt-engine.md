# 06 - STT Engine

> Status: **ACTIVE** - Authoritative, current

MacParakeet uses Parakeet TDT 0.6B-v3 via FluidAudio CoreML, running on Apple's Neural Engine (ANE) — fully local, native Swift.

---

## Model

| Property | Value |
|----------|-------|
| Model | Parakeet TDT 0.6B-v3 |
| Runtime | FluidAudio SDK (CoreML on ANE) |
| Word Error Rate | ~2.5% (v3 multilingual) / ~2.1% (v2 English-only) |
| Speed | ~155x realtime on Apple Silicon |
| Peak working RAM | ~66 MB (~130 MB with custom vocabulary boosting) |
| Model download | ~6 GB CoreML bundle (one-time, during onboarding) |
| Output | Word-level timestamps with per-word confidence scores |
| Input format | 16kHz mono Float32 samples (FluidAudio's AudioConverter handles resampling) |
| Languages | v3: 25 European languages; v2: English only |
| Decoding | Optimized CTC/TDT decoding (FluidAudio implementation) |

### Three-Chip Architecture

Each ML workload runs on the chip it was designed for:

```
CPU:  MacParakeet app (UI, hotkeys, clipboard, history)
ANE:  Parakeet STT (via FluidAudio/CoreML) — dedicated ML accelerator
```

STT runs on dedicated silicon, leaving CPU and GPU free for the app and macOS.

---

## FluidAudio SDK

### Overview

[FluidAudio](https://github.com/FluidInference/FluidAudio) is an open-source Swift SDK by FluidInference that runs Parakeet TDT on Apple's Neural Engine via CoreML. Apache 2.0 licensed. ~1,500 GitHub stars, 34 releases, 20+ production apps.

**SwiftPM dependency:** Use the `FluidAudio` product only — NOT `FluidAudioEspeak` (GPL-3.0, includes Kokoro TTS via ESpeakNG). PocketTTS (GPL-free) is already included in the core `FluidAudio` product since v0.12.0.

### API Surface

Transcription in native Swift async/await:

```swift
import FluidAudio

let models = try await AsrModels.downloadAndLoad(version: .v3)
let manager = AsrManager(config: .default)
try await manager.initialize(models: models)

let result = try await manager.transcribe(samples, source: .system)
// result.text — full transcription
// result.confidence — e.g. 0.988
// result.tokenTimings — word-level timestamps with per-word confidence
```

### Audio Input

All methods require 16kHz mono Float32 samples. FluidAudio provides `AudioConverter`:

```swift
// From audio file (WAV, M4A, etc.)
let samples = try await AudioConverter.resampleAudioFile(path: "path.wav")

// From AVAudioPCMBuffer (microphone capture)
let samples = try AudioConverter.resampleBuffer(buffer)
```

**Critical:** Always use FluidAudio's `AudioConverter` — never manually decode audio. CoreML models require correctly resampled input; manual parsing silently corrupts it.

### Custom Vocabulary Boosting (v0.11.0+)

FluidAudio's CTC-based keyword boosting maps to MacParakeet's `CustomWord` model:

```swift
let vocabulary = CustomVocabularyContext(terms: [
    CustomVocabularyTerm(text: "MacParakeet"),
    CustomVocabularyTerm(
        text: "macOS",
        aliases: ["Mac OS", "Macos"]  // recognized variants → canonical form
    ),
])

let result = try await asrManager.transcribe(
    audioSamples,
    customVocabulary: vocabulary
)
// result.ctcDetectedTerms — vocabulary terms spotted
// result.ctcAppliedTerms — terms applied to transcription
```

This runs a secondary CTC encoder (110M params) alongside the primary TDT encoder. Memory doubles from ~66MB to ~130MB when active. Optimal at 1-50 terms.

### Additional Capabilities (via FluidAudio)

| Capability | Model | Details |
|-----------|-------|---------|
| Streaming ASR | Parakeet EOU 1.1B | Real-time with end-of-utterance detection, 160ms-1600ms chunks |
| Speaker diarization (offline) | Pyannote community-1 + WeSpeaker v2 + VBx clustering | ~15% DER (VoxConverse, CoreML), ~130 MB models, unlimited speakers. See ADR-010. |
| Speaker diarization (streaming) | Sortformer (NVIDIA) | ~32% DER, 4 speaker max. Not used — see ADR-010 for rationale. |
| Voice activity detection | Silero | 96% accuracy, 1220x RTF |
| Custom vocabulary | CTC/TDT keyword boosting | 99.3% recall, 110M secondary encoder |

**Note:** ASR (Parakeet TDT) and diarization (pyannote/WeSpeaker) are entirely separate model pipelines. Parakeet does NOT include diarization. Both are bundled in the FluidAudio SDK — no additional dependencies needed.

---

## STT Integration

### Protocol Layer

The `STTClientProtocol` interface is unchanged from v0.1. The runtime implementation uses FluidAudio/CoreML:

```swift
protocol STTClientProtocol: Sendable {
    func transcribe(audioPath: String, onProgress: (@Sendable (Int, Int) -> Void)?) async throws -> STTResult
    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws
    func isReady() async -> Bool
    func shutdown() async
}

struct STTResult: Sendable {
    let text: String
    let words: [TimestampedWord]
}

struct TimestampedWord: Sendable {
    let word: String
    let startMs: Int          // milliseconds
    let endMs: Int            // milliseconds
    let confidence: Double
}
```

### Lifecycle

- **Lazy init**: FluidAudio models are not loaded at app launch; loaded on first transcription request
- **Keep loaded**: Once initialized, `AsrManager` stays ready for subsequent requests
- **Warm-up during onboarding**: Download models (~6 GB) + CoreML compilation (~3.4s first time)
- **Graceful shutdown**: `AsrManager` released when app quits

### Data Flow

```
Dictation:
  AudioRecorder → AVAudioPCMBuffer → AudioConverter.resampleBuffer() → AsrManager.transcribe() → STTResult

File transcription (v0.4+):
  FFmpeg (video demux) → .wav → AudioConverter.resampleAudioFile() → AsrManager.transcribe() → STTResult
                                                                    → OfflineDiarizerManager.process() → DiarizationResult
                                                                    → Merge word timestamps + speaker segments

YouTube (v0.4+):
  yt-dlp → .m4a → FFmpeg → AudioConverter.resampleAudioFile() → AsrManager.transcribe() → STTResult
                                                               → OfflineDiarizerManager.process() → DiarizationResult
                                                               → Merge word timestamps + speaker segments
```

---

## Model Distribution

### CoreML Model Bundle

The CoreML model for `parakeet-tdt-0.6b-v3-coreml` is **~6 GB** on HuggingFace. Larger than the MLX weights (~2.5 GB) because CoreML stores pre-compiled, hardware-optimized model graphs for the ANE:

| Component | Format |
|-----------|--------|
| ParakeetEncoder_15s | `.mlmodelc` |
| ParakeetDecoder | `.mlmodelc` |
| RNNTJoint | `.mlmodelc` |
| Preprocessor | `.mlmodelc` |
| Melspectrogram_15s | `.mlpackage` |
| MelEncoder | `.mlmodelc` |
| Vocab files | `.json` |

### Download Mechanism

- `AsrModels.downloadAndLoad(version:)` checks local cache first
- If not cached, downloads from HuggingFace (configurable via `ModelRegistry.baseURL`)
- CoreML compilation: ~3.4s cold (first load), ~162ms warm (subsequent loads)
- After first run, models load from local cache

### First-Run Experience

During onboarding:

1. Download CoreML models (~6 GB) with progress indication
2. One-time CoreML compilation (~3.4s)
3. Short warm-up transcription to verify everything works

This replaces the previous Python venv bootstrap (~500 MB deps + ~2.5 GB model).

---

## Error Handling

### Model Download

- Show download progress bar in the UI
- Support retry on network failure
- Resume partial downloads where possible (HuggingFace supports range requests)
- Verify model integrity after download (checksum)

### CoreML Errors

- CoreML runs in-process (not a separate daemon) — no subprocess crash isolation
- Wrap transcription calls in error handling
- On CoreML failure, log the error, report to user, allow retry
- Memory pressure: CoreML uses ~66 MB working RAM, far less likely to trigger OOM than the previous ~2 GB MLX path

### Timeout Handling

- Transcription requests have a timeout proportional to audio duration
- Short dictations: 30-second timeout
- Long files: generous timeout (model runs at ~155x realtime)
- Warm-up/model download allows a longer timeout (first-run downloads can take minutes)

---

## Performance

| Scenario | Latency |
|----------|---------|
| CoreML compilation (first load) | ~3.4 seconds |
| Model warm load (cached) | ~162 ms |
| Short dictation (5-10 seconds audio) | <100ms transcription |
| Long file transcription | ~23 seconds per hour of audio |

### Speed Comparison

| Audio length | CoreML/ANE | Perceptible? |
|-------------|-----------|-------------|
| 5 seconds | 0.03s | No |
| 30 seconds | 0.2s | No |
| 1 minute | 0.4s | No |
| 5 minutes | 1.9s | Barely |
| 1 hour | 23s | Yes, but very fast |

For dictation (the primary use case), transcription time is imperceptible. For long file transcription, the ANE path is still remarkably fast.

### Memory Budget

```
Parakeet STT (CoreML/ANE)      ~66 MB working RAM (~130 MB with vocab boosting)
App process (UI + services)    ~100 MB
Audio buffers                  ~50 MB
────────────────────────────────────
Total peak                     ~300 MB (without vocab boosting)

Recommended: 8 GB RAM (Apple Silicon)
```

### Optimization Notes

- `AsrManager` stays initialized after first use — subsequent calls skip model loading
- Apple Silicon's unified memory means no CPU↔ANE transfer overhead
- For dictation, latency is the primary concern — sub-100ms after warm-up
- For file transcription, throughput matters more — progress reporting keeps the UI responsive
- ANE and GPU run simultaneously — STT never competes with LLM for processing cycles

---

## Speaker Diarization (v0.4)

> See [ADR-010](adr/010-speaker-diarization.md) for the full decision record.

Speaker diarization ("who spoke when") uses FluidAudio's **offline diarization pipeline**, which is entirely separate from the Parakeet ASR pipeline. It applies to file transcription and YouTube transcription only — not dictation.

### Pipeline

Three-stage pipeline, all via FluidAudio's `OfflineDiarizerManager`:

```
Audio → Pyannote community-1 (WHEN) → WeSpeaker v2 (WHO) → VBx clustering (GROUP) → Speaker segments
```

1. **Segmentation** (Pyannote community-1): Powerset segmentation detects speech/silence boundaries and speaker changes at frame level
2. **Embedding extraction** (WeSpeaker v2): Produces 256-dim voice fingerprints for each speech segment
3. **Clustering** (VBx + AHC warm start): Groups embeddings by voice similarity to assign consistent speaker IDs

### Models

| Component | Model | Size | License |
|-----------|-------|------|---------|
| Segmentation | Pyannote community-1 (powerset) | ~50 MB | CC-BY-4.0 |
| Filter bank | Fbank feature extractor | ~1 MB | Apache 2.0 |
| Embeddings | WeSpeaker v2 (256-dim) | ~40 MB | Apache 2.0 |
| PLDA scoring | PLDA rho model + psi parameters | ~10 MB | Apache 2.0 |

**Total**: ~130 MB (one-time download, cached at `~/Library/Application Support/FluidAudio/Models/`)

### Integration with ASR

ASR and diarization run on the same audio, then results are merged:

```
Audio file
  ├─→ AsrManager.transcribe()                → word timestamps + text
  └─→ OfflineDiarizerManager.process()        → speaker segments + IDs
                    ↓
         Merge by time overlap
                    ↓
         WordTimestamp entries with speakerId
```

Each word's time range is compared against diarization speaker segments. The speaker with the most overlap is assigned to that word. Words in silence gaps or overlapping speech zones (trimmed by the offline pipeline) get `speakerId = nil`.

**Diarization is non-fatal.** If diarization fails (`noSpeechDetected`, model error, etc.), the ASR result is still persisted. Speaker fields remain nil and the transcript displays without speaker attribution.

### API

```swift
let config = OfflineDiarizerConfig()
let manager = OfflineDiarizerManager(config: config)
try await manager.prepareModels()

let result = try await manager.process(url)
for segment in result.segments {
    // segment.speakerId — e.g. "S1", "S2" (offline pipeline format)
    // segment.startTimeSeconds, segment.endTimeSeconds
}
```

### Performance

| Metric | Value |
|--------|-------|
| DER (VoxConverse) | ~15% |
| DER (AMI) | ~17.7% |
| Speed | 64-122x RTF (config-dependent) |
| Memory | ~100 MB models + minimal working RAM |
| 1 hour audio | ~30-56 seconds processing |
| Total (ASR + diarization) | ~53-79 seconds per hour of audio |

### What's NOT included

- **No streaming diarization** — file transcription is batch, no need for real-time
- **No Sortformer** — 4-speaker hard limit and 32% DER (see ADR-010)
- **No cross-file speaker identity** — Speaker 1 in file A is not linked to Speaker 1 in file B
- **No dictation diarization** — single speaker by design
