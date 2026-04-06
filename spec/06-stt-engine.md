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
| Peak working RAM | ~66 MB per active Parakeet inference slot (~130 MB with custom vocabulary boosting) |
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

The producer-facing STT contract was expanded in ADR-016 so callers declare job type explicitly and runtime lifecycle stays on the shared path:

```swift
public enum STTJobKind: Sendable, Equatable {
    case dictation
    case meetingFinalize
    case meetingLiveChunk
    case fileTranscription
}

public enum STTWarmUpState: Sendable, Equatable {
    case idle
    case working(message: String, progress: Double?)
    case ready
    case failed(message: String)
}

public protocol STTTranscribing: Sendable {
    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult
}

public protocol STTRuntimeManaging: Sendable {
    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws
    func backgroundWarmUp() async
    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>)
    func removeWarmUpObserver(id: UUID) async
    func isReady() async -> Bool
    func clearModelCache() async
    func shutdown() async
}

public typealias STTManaging = STTTranscribing & STTRuntimeManaging
public typealias STTClientProtocol = STTManaging

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

### Runtime and Scheduling

ADR-016 defines MacParakeet's STT architecture as:

- **One process-wide `STTRuntime` owner** for model lifecycle and warm-up/shutdown
- **Two STT execution slots by default**
  - an **interactive slot** reserved for `dictation`
  - a **background slot** shared by `meetingFinalize`, `meetingLiveChunk`, and `fileTranscription`
- **One STT scheduler / control plane** owning admission, slot assignment, priority, backpressure, cancellation, and job-scoped progress
- **Many producers** (`DictationService`, `MeetingRecordingService`, `TranscriptionService`) submitting jobs into the scheduler

The app does not treat "one service = one STT runtime" as a valid long-term architecture.
`STTClient` remains only as a standalone compatibility facade for the CLI and tests; app code uses the shared `STTRuntime` + `STTScheduler` from `AppEnvironment`.

### Lifecycle

- **Lazy init**: The shared runtime owner is not loaded at app launch; loaded on first STT request or warm-up
- **Keep loaded**: Once initialized, the runtime keeps its currently loaded managers ready for subsequent requests
- **Warm-up during onboarding**: Download models (~6 GB) + CoreML compilation (~3.4s first time)
- **Graceful shutdown**: The shared runtime is released when the app quits
- **Single owner**: Warm-up, readiness, shutdown, and cache clear happen once at the runtime layer
- **Cancellation-safe init**: Shutdown/cache clear cancel in-flight initialization and wait for loaded managers to clean themselves up before returning

### Scheduling Policy

The scheduler exists because STT is a scarce interactive resource even when audio capture is concurrent.

Default policy:

1. **Interactive slot**: reserved for `dictation`
2. **Background slot**: shared by `meetingFinalize`, `meetingLiveChunk`, and `fileTranscription`

Priority within the background slot:

1. `meetingFinalize`
2. `meetingLiveChunk`
3. `fileTranscription`

Backpressure and queueing rules:

- Meeting live chunks are best-effort and may be dropped under backlog
- When a meeting stops, queued live-preview work may be cancelled/dropped so `meetingFinalize` runs next
- Immediate post-stop meeting finalization uses `meetingFinalize`; archived meeting retranscribes remain `fileTranscription`
- Dictation must not be queued behind meeting or batch work
- File transcription is intentionally queued and single-job in v1; a running long batch job may delay meeting STT on the background slot
- Long-running batch work should be segmented into bounded work units in a future iteration if we want it to yield more gracefully
- Progress reporting must be fanned out per job, not broadcast globally from the raw runtime stream
- Cancellation is checked before scheduler admission so fast user cancels do not race into successful transcriptions
- Speaker diarization remains a separate service and is not part of the two-slot speech scheduler

### Data Flow

```
Dictation:
  AudioRecorder → AVAudioPCMBuffer → AudioConverter.resampleBuffer() → STTScheduler.transcribe(audioPath:, job: .dictation, onProgress:) → STTRuntime.transcribe() → STTResult

File transcription (v0.4+):
  FFmpeg (video demux) → .wav → AudioConverter.resampleAudioFile() → STTScheduler.transcribe(audioPath:, job: .fileTranscription, onProgress:) → queued background-slot STTResult
                                                                                                             → OfflineDiarizerManager.process() → DiarizationResult
                                                                                                             → Merge word timestamps + speaker segments

YouTube (v0.4+):
  yt-dlp → .m4a → FFmpeg → AudioConverter.resampleAudioFile() → STTScheduler.transcribe(audioPath:, job: .fileTranscription, onProgress:) → queued background-slot STTResult
                                                                                                        → OfflineDiarizerManager.process() → DiarizationResult
                                                                                                        → Merge word timestamps + speaker segments

Meeting live preview (v0.6):
  MicrophoneCapture/SystemAudioTap → AudioChunker → STTScheduler.transcribe(audioPath:, job: .meetingLiveChunk, onProgress:) → background-slot STT → live transcript update

Meeting stop / finalization:
  Final mixed meeting artifact → STTScheduler.transcribe(audioPath:, job: .meetingFinalize, onProgress:) → background-slot STT → final saved meeting transcript

Saved meeting retranscription from the library:
  Existing meeting audio file → AudioConverter.resampleAudioFile() → STTScheduler.transcribe(audioPath:, job: .fileTranscription, onProgress:) → queued background-slot STT → updated meeting transcript
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
2. If speaker detection is enabled, prepare diarization assets (~130 MB) on the separate diarization service path
3. One-time CoreML compilation (~3.4s)
4. Short warm-up transcription to verify everything works

Onboarding should not report the speech stack as ready until the runtime owner is ready **and** any required default-on speaker-detection assets are available.

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
- Memory pressure: CoreML uses ~66 MB working RAM per active Parakeet inference slot, far less likely to trigger OOM than the previous ~2 GB MLX path

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

- Parakeet STT: ~66 MB working RAM per active slot (~130 MB with vocab boosting)
- App process (UI + services): ~100 MB
- Audio buffers: ~50 MB
- Illustrative warm single-slot budget: ~200-250 MB before diarization
- Real total memory depends on how many STT managers/slots are loaded and active, whether background capacity stays lazy in the final two-slot design, and whether diarization models are also resident
- Recommended baseline: 8 GB RAM (Apple Silicon)

### Optimization Notes

- The shared runtime owner keeps its managers initialized after first use — subsequent calls skip model loading
- Apple Silicon's unified memory means no CPU↔ANE transfer overhead
- For dictation, latency is the primary concern — sub-100ms after warm-up
- For file transcription, throughput matters more — it is intentionally lower-priority than dictation and meeting work in the shared background slot
- The approved two-slot design assumes background capacity is a policy choice rather than a guaranteed always-hot third executor; benchmark any stronger concurrency claim before documenting it as fixed
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
    // segment.speakerId — e.g. "speaker_0", "speaker_1" (FluidAudio format; DiarizationService normalizes to "S1", "S2")
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
