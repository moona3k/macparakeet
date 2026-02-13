# FluidAudio CoreML Migration: STT Backend Evaluation

> Status: **ACTIVE** — Research findings, February 12-13, 2026

## Problem Statement

MacParakeet runs Parakeet TDT 0.6B via a **Python daemon** (`parakeet-mlx`) using JSON-RPC over stdin/stdout. This works, but it's not the best architecture for the product we're building.

### The Core Problem: Wasted Silicon

Every Apple Silicon Mac has **three distinct compute units** on the same die:

```
Apple Silicon (M1/M2/M3/M4)
├── CPU — General purpose (app logic, UI, I/O)
├── GPU — Parallel compute, graphics (Metal)
└── ANE — Neural Engine (dedicated ML inference accelerator)
```

These are **physically separate silicon** with their own processing pipelines. They can run simultaneously without contending for resources.

Today, MacParakeet uses **two of three chips**:

```
CPU: [App logic, UI, hotkeys, clipboard]
GPU: [Parakeet STT] + [Qwen3-4B LLM]   ← two ML workloads sharing one chip
ANE: [idle]                               ← dedicated ML chip sitting unused
```

Both Parakeet (STT) and Qwen3-4B (LLM) run on the GPU via Metal/MLX. They share the GPU memory pool. On 8GB Macs (base M1/M2/M3/M4), this creates real memory pressure — the Qwen3-4B model alone occupies ~2.5-4GB.

**The ANE exists specifically for neural network inference, and we're not using it.**

### Secondary Issues

- **Unnecessary complexity**: JSON-RPC over stdin/stdout, subprocess management, daemon health checks, cross-process error propagation — all to bridge Swift and Python. Native Swift would be a single async/await call.
- **Extra runtime**: Python + uv + venv exist primarily because of the STT backend. Every one is a potential failure point (macOS updates can break venvs, every `.so`/`.dylib` needs codesigning). With FluidAudio, Python is eliminated entirely — yt-dlp and FFmpeg run as standalone binaries.
- **App Store incompatible**: Sandboxing prohibits spawning arbitrary subprocesses. This permanently closes a distribution channel.

## Discovery: FluidAudio

[FluidAudio](https://github.com/FluidInference/FluidAudio) is a Swift SDK by FluidInference that runs Parakeet TDT on Apple's **Neural Engine (ANE) via CoreML** — no Python, no GPU, no subprocess.

- **~1,500 GitHub stars**, Apache 2.0 license
- **v0.12.1** released February 12, 2026 (34 releases in 7 months, extremely active)
- **20+ production apps** ship with it, including VoiceInk and Spokenly (direct competitors)
- Built by FluidInference — small independent team, not affiliated with NVIDIA or Apple
- Business model: open source SDK, paid custom model training/optimization for enterprises

### What It Includes

| Capability | Model | Details |
|-----------|-------|---------|
| ASR (batch) | Parakeet TDT v2 (English) | 2.1% WER, ~146x RTF on M4 Pro |
| ASR (batch) | Parakeet TDT v3 (multilingual) | 2.5% WER, ~156x RTF, 25 European languages |
| ASR (streaming) | Parakeet EOU 1.1B | Real-time with end-of-utterance detection, 160ms-1600ms chunks |
| Diarization | Pyannote + WeSpeaker (offline), Sortformer (real-time) | 15% DER |
| VAD | Silero | 96% accuracy, 1220x RTF |
| TTS | PocketTTS (in core product) | Apache 2.0 (GPL-free) |
| Custom vocabulary | CTC/TDT keyword boosting | 99.3% recall |
| Qwen3-ASR | Beta (v0.12.1) | LLM-enhanced ASR, early stage |

### API Surface

Transcription in 5 lines of native Swift:

```swift
import FluidAudio

let models = try await AsrModels.downloadAndLoad(version: .v3)
let manager = AsrManager(config: .default)
try await manager.initialize(models: models)

let result = try await manager.transcribe(samples, source: .system)
print(result.text)        // full transcription
print(result.confidence)  // e.g. 0.988
// result.tokenTimings provides word-level timestamps with per-word confidence
```

Async/await native. No subprocess. No JSON-RPC.

**Audio input:** All methods require 16kHz mono Float32 samples. FluidAudio provides `AudioConverter` for resampling:

```swift
// From audio file (WAV, M4A, etc.)
let samples = try await AudioConverter.resampleAudioFile(path: "path.wav")

// From AVAudioPCMBuffer (e.g., microphone capture)
let samples = try AudioConverter.resampleBuffer(buffer)
```

**Critical:** Always use FluidAudio's `AudioConverter` — never manually decode audio. CoreML models require correctly resampled input; manual parsing silently corrupts it.

### Custom Vocabulary Boosting (v0.11.0+)

FluidAudio's CTC-based keyword boosting maps directly to our `CustomWord` model:

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
// result.ctcDetectedTerms — which vocabulary terms were spotted
// result.ctcAppliedTerms — which were applied to the transcription
```

This runs a secondary CTC encoder (110M params) alongside the primary TDT encoder. Memory doubles from ~66MB to ~130MB working RAM when vocabulary boosting is active. Tested up to 230 terms, optimal at 1-50.

**Integration opportunity:** Our existing `CustomWord` entries could be fed as `CustomVocabularyTerm` objects, potentially replacing some deterministic pipeline correction with neural recognition at the STT level.

## Target Architecture: Three Workloads, Three Chips

With FluidAudio CoreML, each ML workload runs on the chip it was designed for:

```
CPU: [App logic, UI, hotkeys, clipboard]
GPU: [Qwen3-4B LLM]                      ← full GPU dedicated to text refinement
ANE: [Parakeet STT]                       ← dedicated ML chip, finally used
```

The dictation-to-refinement pipeline becomes:

```
Audio → [Parakeet on ANE] → raw text → [Qwen3-4B on GPU] → refined text
```

**What this means in practice:**

- **Zero compute contention** — ANE and GPU are separate silicon running simultaneously. STT never competes with the LLM for processing cycles.
- **Better memory efficiency** — FluidAudio benchmarks show ~66 MB peak working RAM for the TDT encoder (~130 MB with vocabulary boosting), dramatically lower than the ~2GB+ MLX/GPU footprint. Total memory including memory-mapped model files is higher but still an improvement. On 8GB Macs, this matters.
- **Better accuracy** — FluidAudio's CoreML path achieves 2.1-2.5% WER vs our current ~6.3% on MLX. Same Parakeet model weights, but FluidAudio's optimized decoding produces measurably better results.
- **Lower power** — The ANE is purpose-built for inference and is significantly more power-efficient than running the same workload on the GPU.
- **Scales with features** — As we add command mode, more AI refinement modes, and heavier Qwen3-4B usage, the GPU isn't also carrying STT. This separation becomes more valuable over time, not less.

### Unified Memory: The Shared Bottleneck

Apple Silicon's three compute units are separate processors, but they **share the same unified memory pool**. There's no dedicated VRAM — everything draws from one budget:

```
Apple Silicon (e.g., 8GB Mac)
├── CPU  ──┐
├── GPU  ──┼── All share 8GB unified memory
└── ANE  ──┘
```

This means moving STT to the ANE doesn't magically create new memory — but it does use **less** of the shared pool. The exact savings depend on how CoreML maps the model into memory, but FluidAudio's benchmarks show dramatically lower working memory (~66 MB) compared to the MLX path (~2GB+). On 8GB Macs, every reduction matters.

## Technical Comparison

| Dimension | Current (Python/MLX) | FluidAudio (CoreML/ANE) |
|-----------|---------------------|------------------------|
| **Language** | Python subprocess | Native Swift |
| **Runs on** | GPU (Metal) | ANE (Neural Engine) |
| **RTF** | ~300x | ~155x |
| **1 min dictation** | ~0.2s | ~0.4s |
| **1 hour file** | ~12s | ~23s |
| **WER** | ~6.3% | 2.1% (v2) / 2.5% (v3) |
| **Peak working RAM** | ~2GB+ (GPU/MLX pool) | ~66 MB (~130 MB with vocab boosting) |
| **GPU contention with Qwen3** | Yes | No |
| **First-run setup** | Minutes (venv + ~500 MB deps) | Seconds (CoreML compile) + ~6 GB model download |
| **Dependencies** | Python + uv + venv | SwiftPM (FluidAudio + swift-transformers) |
| **Signing** | Dozens of .so/.dylib files | One Swift framework |
| **App Store** | Blocked (subprocess) | Compatible |
| **Crash isolation** | Good (separate process) | Worse (in-process) |
| **Diarization** | Not included | Built-in |
| **VAD** | Not included | Built-in |
| **Streaming ASR** | Not available | Available (EOU 1.1B model) |
| **Custom vocabulary** | Not included | Built-in CTC boosting (v0.11.0+) |

### Speed Difference in Practice

The 300x vs 155x sounds like "twice as fast" but in absolute terms:

| Audio length | MLX/GPU | CoreML/ANE | Perceptible? |
|-------------|---------|-----------|-------------|
| 5 seconds | 0.02s | 0.03s | No |
| 30 seconds | 0.1s | 0.2s | No |
| 1 minute | 0.2s | 0.4s | No |
| 5 minutes | 1.0s | 1.9s | Barely |
| 1 hour | 12s | 23s | Yes, but both very fast |

For dictation (the primary use case), the difference is imperceptible. For long file transcription, CoreML/ANE is still remarkably fast — 23 seconds for an hour of audio.

### Accuracy Improvement

The WER improvement from ~6.3% (MLX) to 2.1-2.5% (CoreML) is a genuine bonus. Same Parakeet TDT model weights, but FluidAudio's CoreML decoding path produces measurably better results — likely due to their optimized CTC/TDT decoding implementation. The benchmark numbers are from LibriSpeech test-clean; real-world dictation results may vary, but the directional improvement is real.

### Model Size Tradeoff

The CoreML model bundle is **~6 GB** — roughly 2.4x larger than the MLX weights (~2.5 GB). This is the main cost of the migration in terms of user-facing download size.

**Why is the CoreML version larger?**

The MLX path stores model weights in a single quantized format that the GPU interprets at runtime. The CoreML path stores **pre-compiled, hardware-optimized model graphs** — separate compiled bundles for the encoder, decoder, joint network, preprocessor, and mel spectrogram, each optimized for the ANE's specific execution pipeline. This is analogous to how compiled binaries are larger than source code: the extra size buys faster, more efficient execution on the target hardware.

The tradeoff is straightforward:

| | MLX/GPU | CoreML/ANE |
|---|---------|-----------|
| Model download | ~2.5 GB | ~6 GB |
| Runtime memory | ~2 GB+ | ~66 MB working RAM |
| First-run compile | None | ~3.4s one-time |
| Speed | ~300x RTF | ~155x RTF |
| Accuracy | ~6.3% WER | 2.1-2.5% WER |

Larger download, but dramatically lower runtime memory and better accuracy. For a one-time download during onboarding, the extra ~3.5 GB is an acceptable cost — especially since the current Python venv setup already downloads ~500 MB of dependencies plus the ~2.5 GB MLX model weights (total ~3 GB). The net increase is about ~3 GB more than what users already download today.

## Licensing

All components we'd use are permissive:

| Component | License |
|-----------|---------|
| FluidAudio SDK | Apache 2.0 |
| Parakeet TDT v2/v3 CoreML models | CC-BY-4.0 |
| Parakeet EOU 1.1B | nvidia-open-model-license |
| Silero VAD | MIT |
| Diarization models | MIT / Apache 2.0 |

**GPL trap to avoid:** FluidAudio ships two SwiftPM products. `FluidAudio` (core) is all Apache/MIT — it includes ASR, diarization, VAD, and PocketTTS (GPL-free, moved into core in v0.12.0). `FluidAudioEspeak` adds Kokoro TTS with ESpeakNG (GPL-3.0). We only need the core product — no GPL contamination.

## Build Requirements

| Requirement | Current | With FluidAudio |
|-------------|---------|-----------------|
| Swift | 5.9+ | **6.0** (FluidAudio's Package.swift specifies swift-tools-version: 6.0) |
| macOS | 14.2+ | 14.0+ (FluidAudio minimum; our 14.2+ is fine) |
| Architecture | Apple Silicon | Apple Silicon (ANE required) |
| SwiftPM dependencies | GRDB, MLX-Swift, ArgumentParser | + FluidAudio, swift-transformers |
| C++ targets | None | FastClusterWrapper, MachTaskSelfWrapper (C++17, compiled by SwiftPM) |

**Swift 6 note:** FluidAudio requires Swift 6 toolchain. Our project currently specifies Swift 5.9+. We may need to update our `swift-tools-version` or ensure our project compiles under Swift 6's stricter concurrency model. Since FluidAudio is a dependency (not our code), this should work with Swift 5.9 tools that support Swift 6 packages — but needs validation.

## Model Distribution

### Download Size

The CoreML model bundle for `parakeet-tdt-0.6b-v3-coreml` is **~6 GB** on HuggingFace. This is significantly larger than the MLX weights (~2.5 GB) because CoreML bundles include multiple compiled components (encoder, decoder, joint network, preprocessor, mel spectrogram) in mixed precision optimized for ANE.

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
- If not cached, downloads from HuggingFace (configurable mirror via `ModelRegistry.baseURL`)
- CoreML compilation happens on first load (~3.4s cold, ~162ms warm on subsequent loads)
- After first run, models load from local cache

### Options

1. **Download on first use (recommended):** Show progress during onboarding. ~6 GB download, one-time cost. Keeps app bundle small.
2. **Pre-bundle in app:** Instant first-run, but app download is ~6 GB+ larger. Not practical for direct distribution.
3. **Custom mirror:** `ModelRegistry.baseURL = "https://your-cdn.example.com"` for faster downloads or air-gapped environments.

## Risk Assessment

### Risks of adopting FluidAudio

| Risk | Severity | Mitigation |
|------|----------|------------|
| FluidInference goes away | Medium | SDK is Apache 2.0 (forkable), CoreML models are on HuggingFace independently |
| Breaking API changes | Low | Pin to specific version, SDK has semver from v0.7.9+, 34 releases with no breaking changes so far |
| CoreML crash takes down app | Low | CoreML is mature; can wrap in crash handler. Trade-off vs subprocess complexity. |
| CoreML first-run compilation | Low | ~3.4s one-time, show progress indicator during onboarding |
| Model download on first run | Medium-High | ~6 GB download. Must show progress. Consider CDN mirror for faster downloads. One-time cost is acceptable. |
| Streaming ASR quality worse than batch | Low | Use batch mode for dictation (process after recording stops), streaming only for real-time feedback if added later |
| Swift 6 requirement | Low | Our macOS 14.2+ target is compatible; may need swift-tools-version bump |

### Risks of staying on Python/MLX

| Risk | Severity | Mitigation |
|------|----------|------------|
| GPU contention with Qwen3 | High | Sequential processing works, but wastes silicon — ANE sits idle while two workloads share GPU |
| App Store blocked | High | No mitigation possible with Python subprocess |
| macOS update breaks venv | Medium | Defensive checks, auto-rebuild, but adds complexity |
| Distribution/signing complexity | Medium | Automation scripts, but ongoing maintenance burden |
| First-run venv setup | Low | One-time cost, acceptable |

## Decision

**Migrate from parakeet-mlx (Python) to FluidAudio CoreML (Swift). Do it now — before v0.2 AI refinement adds Qwen3-4B to the GPU.**

The CoreML/ANE path is the better architecture — three workloads on three chips instead of two workloads fighting over one, native Swift throughout, fewer moving parts, better accuracy. Use the silicon Apple put in the machine.

### Why now, not later

- v0.2 is adding Qwen3-4B (LLM) to the GPU — the exact moment GPU contention becomes real
- Migrating now means every feature built on top (AI refinement, command mode) starts on the correct architecture
- The STT protocol abstraction (`STTClientProtocol`) makes the swap clean — consumers don't know the backend changed
- Delaying means building more features on Python/MLX, then migrating them later — more work, more risk

### Migration scope

1. **Add FluidAudio as SwiftPM dependency** (`FluidAudio` product only, not `FluidAudioEspeak`)
2. **New `STTClient` implementation** — replace JSON-RPC Python daemon calls with FluidAudio async Swift API, conforming to existing `STTClientProtocol`
3. **Delete entire Python stack** — remove `python/` directory, `PythonBootstrap.swift`, `JSONRPCTypes.swift`, `requirements.txt`, all uv/venv bootstrap code. No Python in the project at all.
4. **Standalone yt-dlp binary** — replace pip-installed yt-dlp with standalone macOS binary (`yt-dlp_macos`, ~35 MB). Store in `~/Library/Application Support/MacParakeet/bin/`. Auto-updates via `yt-dlp --update`. See "Eliminating Python" below.
5. **Bundled FFmpeg binary** — ship FFmpeg in app resources. Still needed for video file transcription (mp4/mov/mkv/webm/avi → audio extraction) and yt-dlp post-processing. FluidAudio's `AudioConverter` handles resampling but NOT video demuxing.
6. **Update STT tests** — new implementation, same `STTClientProtocol` contract
7. **Model download during onboarding** — replace Python venv setup with CoreML model download (~6 GB) + yt-dlp binary download (~35 MB)
8. **Evaluate custom vocabulary integration** — feed `CustomWord` entries as `CustomVocabularyTerm` to FluidAudio's CTC boosting

### Eliminating Python entirely

The entire Python stack is being removed — not slimmed down, removed. There is no foreseeable future need for Python in MacParakeet. The full Apple Silicon ML inference stack is native Swift (FluidAudio CoreML for STT, MLX-Swift for LLM). Python was only needed because parakeet-mlx was the fastest path to Parakeet in v0.1. That reason goes away with FluidAudio.

**yt-dlp without Python:**

yt-dlp publishes standalone macOS binaries (~35 MB) that include a bundled Python runtime — no system Python or venv needed. The binary supports **built-in self-updating** via `yt-dlp --update`, which downloads from GitHub releases with SHA-256 verification and atomic replacement.

| Aspect | Current (Python venv) | After (standalone binary) |
|--------|----------------------|--------------------------|
| Binary location | `~/...MacParakeet/python/bin/yt-dlp` | `~/...MacParakeet/bin/yt-dlp` |
| Auto-update | `uv pip install --upgrade yt-dlp` | `yt-dlp --update` (built-in) |
| Update frequency | Weekly check (current cadence) | Weekly check (same cadence) |
| Dependencies | Python 3.11 + uv + venv (~500 MB) | None (~35 MB standalone) |
| JS runtime for YouTube | `yt-dlp-ejs` pip package | System Node/Deno, or bundle QuickJS (~1 MB) |
| Code signing | Every `.so`/`.dylib` in venv | Not in app bundle, no signing issue |

**First-run bootstrap for yt-dlp:**

1. Download `yt-dlp_macos` from GitHub releases (~35 MB)
2. Verify SHA-256 checksum
3. Store at `~/Library/Application Support/MacParakeet/bin/yt-dlp`
4. Mark executable (`chmod +x`)

**Auto-update (weekly, same as current, non-blocking):**

```swift
// Equivalent of current autoUpdateYouTubeEngineIfNeeded()
let process = Process()
process.executableURL = URL(fileURLWithPath: ytDlpPath)
process.arguments = ["--update"]
try process.run()
process.waitUntilExit() // Failure is logged and ignored; does not block transcription
```

**FFmpeg without Python:**

After removing Python, FFmpeg is provided as a bundled app resource.

| Decision | Details |
|--------|---------|
| **Bundled FFmpeg only** | Include `ffmpeg` in app Resources (~80 MB). Resolve from app bundle at runtime. No Homebrew/system probing. No first-run FFmpeg download. |

### What doesn't change

- `STTClientProtocol` interface — consumers don't know or care about the backend
- `STTResult` format — text + word timestamps + confidence scores
- Qwen3-4B via MLX-Swift — the LLM path stays the same
- `AudioFileConverter` — still converts video files via FFmpeg (binary, not pip package)
- `YouTubeDownloader` — still uses yt-dlp (standalone binary, not pip package)
- All existing tests against the STT protocol — same contract, new implementation
- Deterministic text processing pipeline — unchanged
- UI, hotkeys, history, export — all unchanged

### What gets deleted

| Deleted | Reason |
|---------|--------|
| `python/` directory | Entire STT daemon and Python package |
| `PythonBootstrap.swift` | No Python to bootstrap |
| `JSONRPCTypes.swift` | No JSON-RPC protocol |
| `requirements.txt` | No pip dependencies |
| All uv discovery/bootstrap code | No uv needed |
| `imageio-ffmpeg` dependency | FFmpeg bundled directly |
| `yt-dlp-ejs` dependency | Use system JS runtime or bundle QuickJS |

### Additional opportunity: Qwen3-4B-Instruct-2507

While migrating the STT backend, also upgrade the LLM from `Qwen3-4B` to `Qwen3-4B-Instruct-2507`. The July 2025 update ranked #1 among all small language models for instruction following — directly relevant for our text refinement and command mode use cases. This is a model ID change, not an architecture change.

## Current STT Architecture (What We're Replacing)

For reference, the current architecture that this migration replaces:

### Protocol Layer

```swift
// STTClientProtocol — this interface stays unchanged
protocol STTClientProtocol: Sendable {
    func transcribe(audioPath: String, onProgress: (@Sendable (Int, Int) -> Void)?) async throws -> STTResult
    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws
    func isReady() async -> Bool
    func shutdown() async
}
```

### Data Flow (Current)

```
Dictation: AudioRecorder → .wav → STTClient → JSON-RPC → Python daemon → STTResult
File:      AudioFileConverter (FFmpeg) → .wav → STTClient → JSON-RPC → Python daemon → STTResult
YouTube:   yt-dlp (pip) → .m4a → AudioFileConverter (FFmpeg via imageio) → .wav → STTClient → JSON-RPC → Python daemon → STTResult
```

### Data Flow (After Migration)

```
Dictation: AudioRecorder → AVAudioPCMBuffer → FluidAudio AudioConverter → AsrManager.transcribe() → STTResult
File:      AudioFileConverter (FFmpeg binary) → .wav → FluidAudio AudioConverter → AsrManager.transcribe() → STTResult
YouTube:   yt-dlp (standalone) → .m4a → AudioFileConverter (FFmpeg binary) → .wav → FluidAudio AudioConverter → AsrManager.transcribe() → STTResult
```

### Files Affected

| Action | Files |
|--------|-------|
| **Rewrite** | `STTClient.swift` (actor, ~464 lines → FluidAudio wrapper) |
| **Rewrite** | `YouTubeDownloader.swift` (remove PythonBootstrap dependency, use standalone yt-dlp) |
| **Rewrite** | `AudioFileConverter.swift` (remove imageio-ffmpeg venv lookup, use bundled FFmpeg only) |
| **Delete** | `PythonBootstrap.swift`, `JSONRPCTypes.swift` |
| **Delete** | `python/` directory entirely (server.py, __main__.py, requirements.txt) |
| **Add** | `BinaryBootstrap.swift` or similar (download yt-dlp on first run; validate bundled FFmpeg) |
| **Update** | `STTClientTests.swift`, `JSONRPCTests.swift` (adapt or replace) |
| **Update** | `OnboardingViewModel` (model + binary download progress) |
| **Update** | `HealthCommand.swift` (check yt-dlp binary instead of venv) |
| **Unchanged** | `STTClientProtocol.swift`, `STTResult.swift`, all services, all UI, all other tests (~150+ files) |

## Related Documents

- [Open Source Models Landscape (Feb 2026)](./open-source-models-landscape-2026.md) — full STT/LLM/MLX ecosystem research
- [ADR-001: Parakeet TDT as Primary STT](../spec/adr/001-parakeet-stt.md) — original STT decision (model choice unchanged, runtime changes). Needs amendment post-migration.
- [Distribution & Signing](./distribution.md) — current distribution approach (will simplify after migration)

## Sources

- [FluidAudio GitHub](https://github.com/FluidInference/FluidAudio)
- [FluidAudio Releases](https://github.com/FluidInference/FluidAudio/releases)
- [FluidAudio API Documentation](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md)
- [FluidAudio ASR Getting Started](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/GettingStarted.md)
- [FluidAudio Custom Vocabulary](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/CustomVocabulary.md)
- [FluidAudio Benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)
- [Parakeet TDT v2 CoreML (HuggingFace)](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml)
- [Parakeet TDT v3 CoreML (HuggingFace)](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
- [VoiceInk GitHub](https://github.com/Beingpax/VoiceInk) — production app using FluidAudio
- [mlx-swift-lm GitHub](https://github.com/ml-explore/mlx-swift-lm) — Qwen3 LLM runtime (unchanged)
- [Qwen3-4B-Instruct-2507 (HuggingFace)](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507) — recommended LLM upgrade
