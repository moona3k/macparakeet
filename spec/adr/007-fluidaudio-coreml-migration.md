# ADR-007: FluidAudio CoreML Migration (Python Elimination)

> Status: **Accepted**
> Date: 2026-02-13

## Context

MacParakeet v0.1 runs Parakeet TDT 0.6B-v3 via `parakeet-mlx`, a Python daemon communicating over JSON-RPC stdin/stdout. The Python environment is managed by `uv` (isolated venv, ~500 MB dependencies). This was the fastest path to ship Parakeet on Apple Silicon — ADR-001 chose the model, and parakeet-mlx was the only viable runtime at the time.

Three problems have emerged as we prepare to add Qwen3-4B (LLM) in v0.2:

### 1. Wasted Silicon

Every Apple Silicon Mac has three compute units — CPU, GPU, and ANE (Neural Engine). Today MacParakeet uses two:

```
CPU: [App logic, UI, hotkeys, clipboard]
GPU: [Parakeet STT] + [Qwen3-4B LLM]   ← two ML workloads sharing one chip
ANE: [idle]                               ← dedicated ML chip sitting unused
```

Both Parakeet (STT) and Qwen3-4B (LLM) run on the GPU via Metal/MLX. On 8 GB Macs, combined GPU memory pressure (~2 GB STT + ~2.5 GB LLM) makes simultaneous operation impractical. The ANE — purpose-built for neural inference — sits idle.

### 2. Python Complexity

The Python stack introduces:
- Subprocess management (daemon lifecycle, health checks, crash recovery)
- JSON-RPC protocol bridging (Swift ↔ Python serialization)
- `uv` + venv bootstrap on first launch (~500 MB download)
- Codesigning of every `.so`/`.dylib` in the venv
- Fragile venv that macOS updates can silently break

### 3. Distribution Blocked

App Store sandboxing prohibits spawning arbitrary subprocesses. Python daemon architecture permanently closes this distribution channel.

### New Option: FluidAudio

[FluidAudio](https://github.com/FluidInference/FluidAudio) is an open-source Swift SDK (Apache 2.0, ~1,500 GitHub stars, 34 releases, 20+ production apps including competitors VoiceInk and Spokenly) that runs Parakeet TDT natively on the ANE via CoreML. No Python, no subprocess, no GPU.

See `docs/research/fluidaudio-stt-migration.md` for the full evaluation.

## Decision

**Migrate the STT runtime from parakeet-mlx (Python/MLX/GPU) to FluidAudio (Swift/CoreML/ANE). Eliminate Python from the project entirely.**

The model choice (Parakeet TDT 0.6B-v3) is unchanged. Only the runtime changes. This is an architecture decision, not a model decision — ADR-001's model rationale still holds.

### What changes

| Dimension | Before (v0.1) | After |
|-----------|---------------|-------|
| STT runtime | parakeet-mlx (Python daemon, JSON-RPC) | FluidAudio SDK (native Swift, CoreML) |
| Runs on | GPU (Metal via MLX) | ANE (Neural Engine via CoreML) |
| Speed | ~300x realtime | ~155x realtime |
| WER | ~6.3% | ~2.5% (improved decoding) |
| Peak working RAM | ~2 GB (GPU pool) | ~66 MB (~130 MB with vocabulary boosting) |
| Model download | ~2.5 GB MLX weights | ~6 GB CoreML compiled bundles |
| Dependencies | Python + uv + venv + JSON-RPC | SwiftPM (FluidAudio) |
| IPC | JSON-RPC over stdin/stdout | In-process async/await |
| Python in project | Yes (STT daemon, yt-dlp, FFmpeg via imageio) | None |
| yt-dlp | pip package in venv | Standalone macOS binary (~35 MB) |
| FFmpeg | Discovered via imageio-ffmpeg (pip) | Bundled binary |
| App Store | Blocked (subprocess) | Compatible |

### What doesn't change

- `STTClientProtocol` interface — consumers don't know the backend changed
- `STTResult` format — text + word timestamps + confidence scores
- Qwen3-4B via MLX-Swift on GPU — LLM path unchanged
- Deterministic text processing pipeline — unchanged
- All UI, hotkeys, history, export — unchanged

## Rationale

### Three-Chip Utilization

The core argument. With FluidAudio, each ML workload runs on the chip it was designed for:

```
CPU: [App logic, UI, hotkeys, clipboard]
GPU: [Qwen3-4B LLM]                      ← full GPU dedicated to text refinement
ANE: [Parakeet STT]                       ← dedicated ML chip, finally used
```

Zero compute contention. STT and LLM run on separate silicon simultaneously. On 8 GB Macs, this is the difference between "barely fits" and "runs comfortably."

### Memory Efficiency

FluidAudio uses ~66 MB working RAM (~130 MB with vocabulary boosting) vs ~2 GB+ on the MLX/GPU path. This makes 8 GB Macs viable for STT + LLM simultaneously:

```
Before:  ~2 GB (STT) + ~2.5 GB (LLM) = ~4.5 GB on GPU alone
After:   ~66 MB (STT on ANE) + ~2.5 GB (LLM on GPU) = ~2.6 GB across two chips
```

### Better Accuracy

FluidAudio's CoreML decoding achieves ~2.5% WER vs ~6.3% on MLX. Same Parakeet model weights, better decoding — likely due to FluidAudio's optimized CTC/TDT decoding implementation.

### Python Elimination

No venv, no subprocess, no codesigning of dozens of `.so` files, no daemon health checks, no JSON-RPC serialization. The entire complexity class disappears:

- **yt-dlp** → standalone macOS binary (~35 MB, self-updates via `--update`)
- **FFmpeg** → bundled binary (for video demuxing)
- **STT** → in-process FluidAudio async/await

### App Store Compatibility

Removing the Python subprocess is the only path to App Store distribution. This isn't the primary motivation, but it's a permanently closed door that this migration opens.

### Why Now

v0.2 adds Qwen3-4B to the GPU — the exact moment GPU contention becomes real. Migrating now means every feature built on top (AI refinement, command mode) starts on the correct architecture. Delaying means building more features on Python/MLX, then migrating them later with more surface area and more risk.

## Consequences

### Positive

- STT and LLM run on separate silicon — zero compute contention
- ~66 MB working RAM for STT (vs ~2 GB+) — 8 GB Macs viable
- Better accuracy (~2.5% WER vs ~6.3%)
- No Python, no subprocess, no venv — pure Swift
- App Store compatible
- Simpler architecture — native async/await, no IPC
- Custom vocabulary boosting built into FluidAudio (maps to our `CustomWord` model)
- Streaming ASR, VAD, and diarization available as future capabilities

### Negative

- **Larger model download**: ~6 GB CoreML bundles vs ~2.5 GB MLX weights. Acceptable for one-time onboarding download — the previous Python venv + model was already ~3 GB total, so the net increase is ~3 GB.
- **Slower raw throughput**: ~155x realtime vs ~300x. Imperceptible for dictation (0.4s vs 0.2s for 1 minute of audio). Noticeable only for very long file transcription (23s vs 12s for 1 hour).
- **No crash isolation**: CoreML runs in-process. A CoreML crash takes down the app (vs the Python daemon crashing independently). Mitigated by CoreML's maturity and proper error handling.
- **Third-party dependency**: FluidAudio is maintained by a small independent team (FluidInference). Mitigated by Apache 2.0 license (forkable), CoreML models hosted independently on HuggingFace, and 20+ production apps providing ecosystem validation.
- **Swift 6.0 required**: FluidAudio's Package.swift specifies swift-tools-version: 6.0. Our project needs to compile under Swift 6's stricter concurrency model.

### Migration Scope

| Action | Details |
|--------|---------|
| Add dependency | FluidAudio via SwiftPM (`FluidAudio` product only — NOT `FluidAudioEspeak` which is GPL-3.0) |
| Rewrite | `STTClient` — FluidAudio wrapper conforming to existing `STTClientProtocol` |
| Rewrite | `YouTubeDownloader` — standalone yt-dlp binary instead of venv |
| Rewrite | `AudioFileConverter` — bundled FFmpeg instead of imageio-ffmpeg |
| Delete | `python/` directory, `PythonBootstrap.swift`, `JSONRPCTypes.swift`, all uv/venv code |
| Add | Binary bootstrap (download yt-dlp + FFmpeg on first run) |
| Update | Onboarding (CoreML model download replaces Python venv setup) |
| Update | STT tests (new implementation, same protocol contract) |
| Unchanged | `STTClientProtocol`, all services, all UI, all ViewModels (~150+ files) |

## Alternatives Considered

### Stay on parakeet-mlx (Python/MLX/GPU)

Rejected. GPU contention with Qwen3-4B is the immediate problem with no solution — the ANE sits idle while two ML workloads share the GPU. The Python complexity and App Store incompatibility are secondary but reinforce the decision.

### whisper.cpp (C++ via Swift bridge)

Rejected. Whisper is slower (~15-30x realtime vs ~155x) and less accurate (~7-12% WER vs ~2.5%) for English. Would require maintaining a C++ bridge. Parakeet TDT remains the better model — ADR-001's rationale is unchanged.

### MLX-Swift for Parakeet (keep GPU, eliminate Python)

Partially addresses Python elimination but doesn't solve the core problem — STT would still run on the GPU, contending with Qwen3-4B. The ANE would remain idle. FluidAudio CoreML is strictly better: same model, better accuracy, lower memory, dedicated chip.

### Hybrid: FluidAudio STT + keep Python for yt-dlp

Rejected. Keeping Python solely for yt-dlp means keeping the entire venv infrastructure (~500 MB) for a single tool that publishes standalone binaries. The standalone yt-dlp binary is simpler, smaller (~35 MB), self-updating, and has no Python dependency.

## References

- [FluidAudio GitHub](https://github.com/FluidInference/FluidAudio) — CoreML/ANE runtime for Parakeet TDT
- [parakeet-mlx](https://github.com/senstella/parakeet-mlx) — MLX port (original runtime, superseded)
- [ADR-001: Parakeet TDT as Primary STT](./001-parakeet-stt.md) — model choice (unchanged), runtime addendum
- [FluidAudio STT Migration Evaluation](../../docs/research/fluidaudio-stt-migration.md) — full technical comparison
- [Open Source Models Landscape (Feb 2026)](../../docs/research/open-source-models-landscape-2026.md) — research that identified FluidAudio
