# ADR-001: Parakeet TDT 0.6B-v3 as Primary STT Engine

> Status: **Accepted**
> Date: 2026-02-08
> Runtime Note (2026-02-13): Runtime/mechanism details in this ADR are historical and superseded by ADR-007. ADR-001 remains authoritative for STT model choice.
> Note: GPU/LLM references (Qwen3-8B, "three-chip") are historical — LLM support removed 2026-02-23. MacParakeet now uses a two-chip architecture (CPU + ANE).

## Context

MacParakeet needs a fast, accurate, local speech-to-text engine for macOS on Apple Silicon. The STT engine is the core of the product -- it must be fast enough for real-time dictation, accurate enough for professional use, and run entirely on-device to honor our local-only commitment (see ADR-002).

The two leading local STT options are:

| Model | Speed | WER | Optimization |
|-------|-------|-----|--------------|
| Whisper (various sizes) | 15-30x realtime | 7-12% | ONNX, CoreML, MLX |
| Parakeet TDT 0.6B-v3 | ~300x realtime | ~6.3% | MLX (Apple Silicon native) |

Whisper has broader ecosystem support and language coverage, but Parakeet is faster, more accurate for English, and better optimized for Apple Silicon via MLX.

## Decision

Use **Parakeet TDT 0.6B-v3** via the `parakeet-mlx` Python daemon as the primary (and only) STT engine.

The model runs as a Python daemon process communicating with the Swift app over JSON-RPC via stdin/stdout. The Python environment is bootstrapped automatically using `uv` on first launch.

## Rationale

### Speed

Parakeet TDT 0.6B-v3 achieves approximately **300x realtime** on Apple Silicon via MLX. This means a 60-second audio clip transcribes in ~0.2 seconds. Whisper large-v3, by comparison, achieves 15-30x realtime depending on quantization and optimization -- an order of magnitude slower.

For dictation, speed is critical. Users expect their words to appear almost instantly after they stop speaking. Parakeet's speed makes sub-second transcription the norm, not the exception.

### Accuracy

Parakeet TDT 0.6B-v3 achieves **~6.3% Word Error Rate** on standard benchmarks, compared to Whisper's 7-12% depending on model size. More importantly:

- **Better technical vocabulary**: Parakeet handles programming terms, product names, and technical jargon more reliably than Whisper.
- **Better punctuation**: Parakeet outputs well-punctuated text natively, reducing the need for post-processing.
- **Word-level timestamps**: Parakeet provides per-word timestamps and confidence scores, enabling precise audio-text alignment.

### Apple Silicon Optimization

Parakeet TDT 0.6B-v3 is specifically optimized for Apple Silicon through MLX. It leverages the Neural Engine and unified memory architecture effectively. Whisper can run on Apple Silicon but was not designed for it -- MLX ports exist but performance is secondary to Parakeet's native optimization.

### Model Size

At 0.6B parameters (quantized to ~600MB on disk, ~1.5GB downloaded with tokenizer and config), Parakeet is compact enough to bundle or download on first launch without being burdensome. Whisper large-v3 is 1.5B parameters and requires significantly more memory.

## Consequences

### Positive

- Sub-second transcription for typical dictation segments
- Better accuracy than Whisper for English technical content
- Native Apple Silicon performance via MLX
- Compact model size (~1.5GB download)
- Word-level timestamps and confidence scores included

### Negative

- **Requires Python daemon**: The parakeet-mlx library is Python-based, requiring a Python runtime managed by `uv`. This adds complexity to the app bundle and first-launch experience.
- **~1.5GB model download**: Users must download the model on first launch. Must handle this gracefully with progress indication and offline fallback messaging.
- **Apple Silicon only**: No Intel Mac support. This is acceptable given Apple Silicon's market penetration (all Macs since late 2020) and our target audience.
- **English-primary**: Parakeet TDT 0.6B-v3 is optimized for English. Multilingual support would require Whisper as a fallback (not planned for v1).

### Implementation Notes

- Python daemon managed via `uv` bootstrap (isolated venv, no system Python dependency)
- JSON-RPC protocol over stdin/stdout for Swift-Python communication
- Model downloaded on first launch with progress UI
- Daemon lifecycle managed by the Swift app (start on launch, stop on quit)

## Addendum: Runtime Migration to FluidAudio CoreML (February 2026)

> Date: 2026-02-13

**The model choice (Parakeet TDT 0.6B-v3) is unchanged.** The runtime is migrating from parakeet-mlx (Python/MLX/GPU) to FluidAudio (Swift/CoreML/ANE).

### What Changed

| Dimension | Original (ADR-001) | Updated |
|-----------|-------------------|---------|
| Runtime | parakeet-mlx (Python daemon, JSON-RPC) | FluidAudio SDK (native Swift, CoreML) |
| Runs on | GPU (Metal via MLX) | ANE (Neural Engine via CoreML) |
| Speed | ~300x realtime | ~155x realtime |
| WER | ~6.3% | ~2.5% (improved decoding) |
| Working RAM | ~1.5-2 GB (GPU pool) | ~66 MB |
| Model download | ~1.5-2.5 GB (MLX weights) | ~6 GB (CoreML compiled bundles) |
| Dependencies | Python + uv + venv | SwiftPM (FluidAudio) |
| IPC | JSON-RPC over stdin/stdout | In-process async/await |

### Why

1. **Three-chip utilization** — Moving STT to the ANE frees the GPU entirely for the Qwen3-8B LLM. Zero compute contention.
2. **Memory efficiency** — ~66 MB working RAM (vs ~2 GB+) makes 8GB Macs viable for both STT and LLM simultaneously.
3. **Better accuracy** — FluidAudio's CoreML decoding achieves ~2.5% WER (vs ~6.3% on MLX). Same model weights, better decoding.
4. **Eliminates Python** — No venv, no subprocess, no codesigning issues. Pure Swift. App Store compatible.
5. **Simpler architecture** — Native Swift async/await replaces JSON-RPC daemon management.

### Consequences Update

The "Requires Python daemon" negative consequence from the original ADR is resolved. The new negative consequence is a larger model download (~6 GB vs ~2.5 GB) due to CoreML's pre-compiled hardware-optimized model graphs.

See `docs/research/fluidaudio-stt-migration.md` for the full evaluation.

## References

- [NVIDIA Parakeet TDT 0.6B-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- [FluidAudio](https://github.com/FluidInference/FluidAudio) -- CoreML/ANE runtime for Apple Silicon
- [parakeet-mlx](https://github.com/senstella/parakeet-mlx) -- MLX port (original runtime, superseded)
- Oatmeal project ADR-011 (prior art for Parakeet selection)
