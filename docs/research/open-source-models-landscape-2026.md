# Open Source Models Landscape (February 2026)

> Status: **HISTORICAL SNAPSHOT** — Research snapshot as of February 12, 2026. Runtime/model decisions are superseded by ADR-007 and current docs (`Parakeet TDT 0.6B-v3` via FluidAudio CoreML).

Deep dive into the current state of open source models relevant to MacParakeet: STT, small LLMs, and the Apple MLX ecosystem.

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [STT Models](#stt-models)
3. [Small LLMs (Sub-8B)](#small-llms-sub-8b)
4. [MLX Ecosystem & Inference](#mlx-ecosystem--inference)
5. [Hardware Trends](#hardware-trends)
6. [Competitive Landscape Update](#competitive-landscape-update)
7. [Recommendations for MacParakeet](#recommendations-for-macparakeet)
8. [Sources](#sources)

---

## Executive Summary

**Key takeaways:**

- **At snapshot time, Parakeet TDT 0.6B-v2 was assessed as the best English-first STT choice.** Current project decision is v3-only via FluidAudio CoreML (see ADR-007 and spec docs).
- **Qwen3-4B is still the right LLM**, but the **July 2025 "2507" update** is a meaningful upgrade — it ranked #1 among small language models for instruction following. Available as `mlx-community/Qwen3-4B-Instruct-2507-4bit`.
- **MLX is now Apple-endorsed** (WWDC 2025). MLX-Swift has breaking API changes. The ecosystem is maturing fast.
- **FluidAudio** is the most interesting new development — a Swift CoreML package that runs Parakeet natively on the ANE without a Python daemon. VoiceInk (competitor) already uses it.
- **No Whisper V4, no Qwen4, no Llama 4 small models.** The landscape is evolutionary, not revolutionary.

---

## STT Models

### Parakeet Family (NVIDIA)

At snapshot time, MacParakeet used Parakeet TDT 0.6B-v2 via parakeet-mlx (Python daemon, JSON-RPC). Current migration docs supersede this with FluidAudio + v3.

| Model | Params | Avg WER | RTFx | Languages | Release | License |
|-------|--------|---------|------|-----------|---------|---------|
| **Parakeet TDT 0.6B-v2** | 600M | 6.05% | 3,386 | English | May 2025 | CC-BY-4.0 |
| **Parakeet TDT 0.6B-v3** | 600M | 6.34% | 3,333 | 25 European | Aug 2025 | CC-BY-4.0 |
| Parakeet TDT 1.1B | 1.1B | ~8% | >2,000 | English | 2024 (updated) | CC-BY-4.0 |
| Parakeet CTC 1.1B | 1.1B | 23rd rank | 2,794 | English | 2025 | CC-BY-4.0 |
| Canary-1B-Flash | 883M | ~4.2% LS | >1,000 | EN/DE/FR/ES | Mar 2025 | CC-BY-4.0 |
| **Canary Qwen 2.5B** | 2.5B | **5.63%** | 418 | English | Jul 2025 | CC-BY-4.0 |

**Key findings:**

- **v3 adds multilingual** with a minor English accuracy trade-off (6.34% vs 6.05%). Same architecture, same parameter count. If MacParakeet ever needs multilingual, v3 is a drop-in upgrade.
- **No larger Parakeet TDT** (2B, 3B) exists. NVIDIA's larger models are in the Canary family, which use LLM decoders and are significantly slower.
- **Canary Qwen 2.5B** is the new accuracy leader (#1 on Open ASR Leaderboard) — a hybrid FastConformer + Qwen3-1.7B decoder. But it's 8x slower than Parakeet TDT and needs ~8-10GB RAM. Not suitable for real-time dictation.

### Whisper Family (OpenAI)

| Model | Params | Avg WER | RTFx | Languages | Notes |
|-------|--------|---------|------|-----------|-------|
| Whisper Large V3 | 1.55B | ~7.4% | 69 | 99+ | Nov 2023, no updates since |
| Whisper Large V3 Turbo | 809M | ~7.75% | 216 | 99+ | Late 2024, 6x faster |
| Distil-Whisper V3.5 | 756M | within 1% of V3 | 6.3x faster | English | 2025, 98K hours training |

**No Whisper V4.** OpenAI shifted to proprietary API-only models (gpt-4o-transcribe). Community forks remain active (whisper.cpp, faster-whisper, mlx-whisper), but the underlying model is stagnant. Parakeet TDT now clearly outperforms Whisper in both speed and English accuracy.

### Other Notable STT Models

| Model | Org | Params | WER | Speed | Notes |
|-------|-----|--------|-----|-------|-------|
| **IBM Granite Speech 3.3** | IBM | ~9B | 5.85% | RTFx 31 | Very accurate, very slow. Too large for local Mac inference. |
| **Phi-4 Multimodal** | Microsoft | 5.6B | 6.14% | N/A | Text + audio + vision. First multimodal STT. Too large for efficient local use. |
| **Kyutai STT 2.6B** | Kyutai Labs | 2.6B | 6.4% | RTFx 88 | Streaming-first (2.5s latency). French support. |
| **Moonshine** | Useful Sensors | 27M-larger | within 1% of Whisper | 5x less compute | Designed for edge/embedded. Too small for quality. |
| **Meta Omnilingual** | Meta | 300M-7.8B | CER<10 for 78% of 1600+ langs | N/A | Language breadth, not English accuracy. |

### Apple SpeechAnalyzer (macOS 26+)

Apple introduced native on-device STT at WWDC 2025:
- **~8% WER** in tests (3% CER). Between Whisper and Parakeet in accuracy.
- **55% faster than Whisper** — 34-min video processed in 45 seconds.
- Built by the Argmax/WhisperKit team.
- **Requires macOS 26 (Tahoe)**. Not usable on MacParakeet's macOS 14.2+ target.
- Worth monitoring for future minimum OS version bumps.

### FluidAudio (CoreML Parakeet)

**The most interesting new development for MacParakeet's architecture:**

- Swift package running Parakeet TDT v3 via **CoreML on the ANE** (not Python/MLX).
- **~110x RTF** on M4 Pro (1 hour audio in ~19 seconds).
- Includes speaker diarization, VAD, streaming ASR with end-of-utterance detection.
- macOS 14.0+ and iOS 17.0+ support.
- Apache 2.0 licensed.
- **VoiceInk already uses FluidAudio** for its Parakeet integration.
- Eliminates the Python daemon entirely — native Swift, runs on ANE (minimal CPU/GPU).

### Speed on Apple Silicon (1 hour audio)

| Implementation | Hardware | Time | RTF |
|---------------|----------|------|-----|
| FluidAudio (Parakeet v3 CoreML) | M4 Pro | ~19s | ~110x |
| parakeet-mlx (Parakeet v2) | M3 MacBook Pro | ~62s | ~65x |
| Apple SpeechAnalyzer | Apple Silicon | ~80s (est.) | ~45x |
| whisper.cpp (Large V3 + CoreML) | M4 Pro | ~300s | ~12x |
| mlx-whisper (Large V3) | M1 Max | ~400s (est.) | ~9x |

### STT Memory Requirements

| Model | Parameters | Approx. RAM |
|-------|-----------|-------------|
| Moonshine Tiny | 27M | <0.5 GB |
| Parakeet TDT 0.6B | 600M | ~2 GB |
| Distil-Whisper Large V3 | 756M | ~5 GB |
| Whisper Large V3 Turbo | 809M | ~6 GB |
| Canary Qwen 2.5B | 2.5B | ~8-10 GB |
| Whisper Large V3 | 1.55B | ~10 GB |

---

## Small LLMs (Sub-8B)

MacParakeet uses Qwen3-4B via MLX-Swift for command mode and AI text refinement.

### Qwen3 Family (Alibaba)

The most active player in the small model space.

**Qwen3 (April 2025):** Dense models at 0.6B, 1.7B, 4B, 8B, 14B, 32B + MoE models. All Apache 2.0. Every model supports dual-mode (thinking + non-thinking).

**Qwen3-4B-Instruct-2507 (July 2025):** A significant mid-cycle update:
- **Ranked #1 among all small language models** in comprehensive benchmarks.
- Better instruction following, logical reasoning, text comprehension.
- Improved text generation quality for subjective/open-ended tasks.
- 256K context window (extendable to 1M tokens).
- 100+ language support.
- HuggingFace: `mlx-community/Qwen3-4B-Instruct-2507-4bit`

**Qwen3-Next (September 2025):** Hybrid MoE — 80B total / 3B active. Matches Qwen3-32B. But ~17-20GB at 4-bit. Tight on 16GB Macs.

**No Qwen4 exists yet.** Latest generation remains Qwen3 with iterative improvements.

### Full Landscape Comparison

| Model | Params | Instruction Following | Memory (4-bit MLX) | Release | License |
|-------|--------|----------------------|---------------------|---------|---------|
| **Qwen3-4B-Instruct-2507** | 4B | **Best in class** | ~2.5-4GB | Jul 2025 | Apache 2.0 |
| Qwen3-8B | 8B | Very strong, most consistent | ~4-5GB | Apr 2025 | Apache 2.0 |
| Gemma 3 4B | 4B | Good | ~3GB | Mar 2025 | Apache-like |
| **Gemma 3n E4B** | 8B (3GB eff.) | Good | ~3GB | Jun 2025 | Apache-like |
| Phi-4-mini | 3.8B | Strong | ~2.5-3GB | Feb 2025 | MIT |
| Ministral 3B | 3B | Good | ~2GB | Dec 2025 | Apache 2.0 |
| Ministral 8B | 8B | Good | ~4-5GB | Dec 2025 | Apache 2.0 |
| DeepSeek R1 Distill 7B | 7B | Moderate (reasoning-optimized) | ~4GB | Jan 2025 | MIT |
| Llama 3.2-3B | 3B | Moderate | ~2GB | Sep 2024 | Llama license |

**Notable absences:**
- **No Llama 4 small models.** Llama 4 shifted entirely to MoE (17B+ active). Meta has effectively exited sub-8B.
- **No Whisper-era surprise entrants.** The sub-8B space is dominated by Qwen3, Gemma 3, Phi-4, and Ministral 3.

### Task-Specific Assessment

For MacParakeet's use cases (text cleanup/rewriting + command mode editing):

1. **Qwen3-4B-Instruct-2507** — Best choice. #1 SLM for instruction following. The July 2025 update specifically improved text generation quality. Dual-mode (thinking for complex edits, non-thinking for quick cleanup).

2. **Qwen3-8B** — Marginal quality upgrade, ~4-5GB RAM. Most consistent across all benchmarks. Consider if 4B proves insufficient for command mode.

3. **Gemma 3n E4B** — Interesting memory efficiency (8B params, ~3GB effective). Newer, less MLX tooling. Worth evaluating.

4. **Phi-4-mini** — Good fallback (3.8B, strong reasoning). Slightly behind Qwen3-4B-2507.

5. **Ministral 3B** — Newest (Dec 2025), Apache 2.0. Less community MLX optimization.

### Models to Avoid for This Use Case

- **Qwen3-30B-A3B / Qwen3-Next 80B-A3B** — Too much memory for a background task (~17-20GB).
- **Llama 3.2-3B** — Outdated, outperformed.
- **SmolLM2 1.7B** — Too small for quality text refinement.
- **DeepSeek R1 distillations** — Optimized for reasoning chains, not text cleanup.

### Quantization Notes

- **4-bit quality is excellent** for this use case. Benchmarks show quantization "does not matter" for practical tasks on MLX (Qwen2.5 Coder study). QAT variants from Google preserve near-BF16 quality at 3x less memory.
- MLX 4-bit is the clear winner on Apple Silicon — native Metal optimization, no GGUF overhead.

---

## MLX Ecosystem & Inference

### MLX Framework (v0.30.6)

Major developments since mid-2025:

- **WWDC 2025 endorsement** — Apple positioned MLX as the official framework for on-device AI. Two dedicated sessions.
- **M5 Neural Accelerator support** (macOS 26.2) — Up to 4x peak AI compute vs M4.
- **JACCL distributed backend** — RDMA over Thunderbolt 5 for multi-Mac clusters. Order-of-magnitude latency reduction.
- **Speculative decoding** — 20-50% speed gains via draft model acceleration.
- **Prompt/prefix caching** — 5.8x speedup on time-to-first-token.
- **iOS/iPadOS support** — MLX now officially cross-platform (all Apple Silicon devices).

### MLX-Swift Breaking Changes

**Important for MacParakeet's MLX-Swift integration:**

| Old API | New API |
|---------|---------|
| `loadModelContainer()` | `LLMModelFactory.shared.loadContainer()` |
| `ModelConfiguration` | `ModelRegistry.phi3_5_4bit` |
| `[Int]` token arrays | `UserInput` / `LMInput` types |
| Non-throwing `ModelContainer.perform` | Throwing `ModelContainer.perform` |
| Quantized linear bias `MLXArray` | `MLXArray?` (optional) |

The high-level package is now **[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)** — supports all major architectures (Qwen, Llama, Gemma, Phi, Mistral). Any MLX-format model from mlx-community works.

### mlx-community on HuggingFace

Thousands of pre-converted, quantized models. Key for MacParakeet:
- `mlx-community/Qwen3-4B-Instruct-2507-4bit` — Updated Qwen3-4B
- `Qwen/Qwen3-30B-A3B-MLX-4bit` — MoE option (if RAM allows)
- Qwen3 collection, Qwen3-Next collection, Qwen3-VL collection all available

### MLX vs. Alternatives (Academic Benchmark)

From [arXiv:2511.05502](https://arxiv.org/abs/2511.05502), tested on M2 Ultra with Qwen-2.5:

| Framework | Throughput | TTFT | Best For |
|-----------|-----------|------|----------|
| **MLX** | **Highest** (~230 tok/s) | Good | Maximum throughput on Apple Silicon |
| MLC-LLM | ~190 tok/s | **Lowest** | Low-latency applications |
| llama.cpp | Good | Good | Lightweight, cross-platform |
| Ollama | Lags behind | Lags behind | Developer ergonomics |
| PyTorch MPS | Constrained | Constrained | Research/training only |

- MLX is **50% faster than Ollama** and **30-50% faster than llama.cpp** on Apple Silicon.
- **vllm-mlx** (newer entrant) achieves 21-87% higher throughput than llama.cpp, up to **525 tok/s** on M4 Max via continuous batching.

### Apple Foundation Models Framework

Introduced at WWDC 2025 — access to Apple's on-device ~3B LLM powering Apple Intelligence:
- Free inference, Swift-native, offline capable.
- Good for: summarization, entity extraction, text refinement, short dialog.
- **Limitations:** Requires macOS 26, not a general chatbot, no fine-tuning, text-only, no control over model behavior.
- **Not a replacement for Qwen3-4B** — MacParakeet targets macOS 14.2+, and the Foundation model can't handle command mode editing. Could be a supplementary option for simple cleanup on macOS 26+ users.

### Emerging Inference Engines

| Engine | Description |
|--------|-------------|
| MLX | Core framework, Apple-endorsed standard |
| mlx-lm | High-level Python CLI for MLX inference |
| mlx-swift-lm | Swift LLM/VLM package (MacParakeet uses this) |
| vllm-mlx | OpenAI-compatible server, 400-525 tok/s, continuous batching |
| MLX Engine | LM Studio's MLX backend with speculative decoding |
| Exo | Distributed inference across multiple Macs |
| Ollama | Easy CLI/server (uses llama.cpp, not MLX — slower on Mac) |

---

## Hardware Trends

### M5 Chip (October 2025)

The biggest hardware leap for local LLM inference:

| Metric | M4 | M5 | Improvement |
|--------|----|----|-------------|
| Memory bandwidth | 120 GB/s | 153 GB/s | +28% |
| Peak AI compute | Baseline | 4x (Neural Accelerators) | +300% |
| TTFT (14B dense) | ~40s | <10s | ~4x faster |
| Token generation | Baseline | +19-27% | Bandwidth-bound |

**Critical insight:** Memory bandwidth is THE bottleneck for token generation. An M3 Max (400 GB/s) generates tokens faster than an M4 (120 GB/s). The M5's Neural Accelerators primarily help with prompt processing (TTFT), while generation scales linearly with bandwidth.

### M4 Family Performance

| Chip | Memory | Bandwidth | ~7B Model Performance |
|------|--------|-----------|----------------------|
| M4 | 16-32GB | 120 GB/s | 10-15 tok/s |
| M4 Pro | 24-48GB | 273 GB/s | 30-40 tok/s |
| M4 Max | 36-128GB | 546 GB/s | 60-80 tok/s |
| M4 Ultra | 192-512GB | 819 GB/s | 100+ tok/s |

### Unified Memory Advantage

Apple Silicon's unified memory = zero-copy for MLX operations. A $2,000 Mac Studio with 64GB can run 30B+ quantized models — equivalent NVIDIA setups cost far more.

---

## Competitive Landscape Update

### Dictation App Pricing (Feb 2026)

| App | Price | Key Update Since Last Review |
|-----|-------|------------------------------|
| WisprFlow | $12-15/mo | Now on Mac + Windows + iOS; SOC 2 Type II, HIPAA |
| MacWhisper | $35 Pro (one-time) | Price up from $30; speaker separation added |
| **VoiceInk** | $39.99 (one-time) | **Open source (GPL), uses FluidAudio/Parakeet** |
| Superwhisper | $250 lifetime / $5.41/mo | Unchanged |
| Voibe | $99 lifetime / $4.90/mo | Unchanged |

**VoiceInk's move to FluidAudio/Parakeet is significant.** It validates the Parakeet-first strategy and shows the CoreML path is production-ready.

### Voice Assistant Projects

| Project | Stack | Notes |
|---------|-------|-------|
| FluidAudio | CoreML Parakeet + diarization + VAD | Swift SDK, ANE-optimized, used by VoiceInk |
| mlx-audio | STT + TTS + STS on MLX | v0.3.1, speech-to-speech pipeline |
| Local-Voice-AI | LiveKit + Whisper + llama.cpp + TTS | Full voice loop |
| Parakeet Podcast Processor | Parakeet MLX + Ollama | Transcription + summaries, 100% local |

---

## Recommendations for MacParakeet

> Note: This section reflects pre-migration recommendations from the February 12, 2026 snapshot. Current implementation docs and ADR-007 supersede STT/runtime recommendations.

### Immediate (No Architecture Changes)

1. **Upgrade LLM to Qwen3-4B-Instruct-2507.** The July 2025 update ranked #1 among SLMs for instruction following — exactly what MacParakeet needs for text refinement and command mode. Change the HuggingFace model ID to `mlx-community/Qwen3-4B-Instruct-2507-4bit`. Minimal code change, meaningful quality improvement.

2. **Snapshot recommendation (historical): keep Parakeet TDT 0.6B-v2 for STT.** Current project decision is v3-only via FluidAudio CoreML.

3. **Monitor MLX-Swift breaking changes.** When upgrading mlx-swift-lm, prepare for `LLMModelFactory`, `UserInput`/`LMInput`, and throwing `ModelContainer.perform` changes.

### Medium-Term (Consider for v0.4+)

4. **Evaluate FluidAudio as a Python daemon replacement.** Running Parakeet via CoreML on the ANE (instead of Python/MLX) would:
   - Eliminate the Python dependency entirely (no uv, no venv, no daemon).
   - Run on the ANE instead of GPU (lower power, doesn't compete with LLM inference).
   - Match or exceed current performance (~110x RTF vs ~65x RTF).
   - Support macOS 14.0+ (matches MacParakeet's target).
   - Add speaker diarization, VAD, and streaming ASR for free.
   - This is a significant architectural change but would simplify distribution and improve the user experience.

5. **Evaluate Qwen3-8B if command mode quality is insufficient.** Only ~4-5GB RAM at 4-bit. Most consistent model across all benchmarks. Marginal quality upgrade over 4B-2507 for text tasks, but potentially meaningful for complex voice commands.

### Long-Term (Track for Future)

6. **Apple SpeechAnalyzer** — Native API, excellent speed. But requires macOS 26+. Worth considering when MacParakeet's minimum OS version reaches Tahoe.

7. **Apple Foundation Models** — Free on-device LLM via macOS 26+ API. Not a replacement for Qwen3 (too limited), but could supplement simple text cleanup at zero cost.

8. **Gemma 3n E4B** — 8B params with only ~3GB effective memory via Per-Layer Embedding. Interesting efficiency play, but newer and less tested.

9. **M5 Neural Accelerators** — 4x TTFT improvement. As M5 adoption grows, MacParakeet gets faster "for free" via MLX.

---

## Sources

### STT Models
- [Parakeet TDT 0.6B-v2 (HuggingFace)](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)
- [Parakeet TDT 0.6B-v3 (HuggingFace)](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- [Canary Qwen 2.5B (HuggingFace)](https://huggingface.co/nvidia/canary-qwen-2.5b)
- [Open ASR Leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)
- [Best Open Source STT 2026 (Northflank)](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks)
- [2025 Edge STT Benchmark (Ionio)](https://www.ionio.ai/blog/2025-edge-speech-to-text-model-benchmark-whisper-vs-competitors)
- [NVIDIA Speech AI Blog](https://developer.nvidia.com/blog/nvidia-speech-ai-models-deliver-industry-leading-accuracy-and-performance/)
- [FluidAudio GitHub](https://github.com/FluidInference/FluidAudio)
- [WhisperKit GitHub](https://github.com/argmaxinc/WhisperKit)
- [Apple SpeechAnalyzer Speed Tests (MacRumors)](https://www.macrumors.com/2025/06/18/apple-transcription-api-faster-than-whisper/)
- [Apple SpeechAnalyzer Accuracy Tests (9to5Mac)](https://9to5mac.com/2025/07/03/how-accurate-is-apples-new-transcription-ai-we-tested-it-against-whisper-and-parakeet/)
- [Kyutai STT (HuggingFace)](https://huggingface.co/kyutai/stt-2.6b-en)
- [Moonshine GitHub](https://github.com/moonshine-ai/moonshine)
- [Distil-Whisper V3.5 (HuggingFace)](https://huggingface.co/distil-whisper/distil-large-v3.5)
- [Meta Omnilingual ASR (arXiv)](https://arxiv.org/html/2511.09690v1)

### Small LLMs
- [Qwen3 Official Blog](https://qwenlm.github.io/blog/qwen3/)
- [Qwen3-4B-Instruct-2507 (HuggingFace)](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507)
- [Qwen3-Next (VentureBeat)](https://venturebeat.com/ai/qwen3-next-debuts-with-impressively-efficient-performance-on-just-3b-active)
- [Gemma 3 (Google DeepMind)](https://deepmind.google/models/gemma/gemma-3/)
- [Gemma 3n (Google DeepMind)](https://deepmind.google/models/gemma/gemma-3n/)
- [Phi-4-mini-instruct (HuggingFace)](https://huggingface.co/microsoft/Phi-4-mini-instruct)
- [Mistral 3](https://mistral.ai/news/mistral-3)
- [Llama 4 Overview (GPT-Trainer)](https://gpt-trainer.com/blog/llama+4+evolution+features+comparison)
- [Best Small LLMs 2026 (DataCamp)](https://www.datacamp.com/blog/top-small-language-models)
- [Gemma 3 vs Qwen 3 Comparison (Codersera)](https://codersera.com/blog/gemma-3-vs-qwen-3-in-depth-comparison-of-two-leading-open-source-llms/)

### MLX Ecosystem
- [MLX GitHub](https://github.com/ml-explore/mlx)
- [MLX-Swift GitHub](https://github.com/ml-explore/mlx-swift)
- [mlx-swift-lm GitHub](https://github.com/ml-explore/mlx-swift-lm)
- [mlx-community (HuggingFace)](https://huggingface.co/mlx-community)
- [WWDC25: Explore LLMs with MLX](https://developer.apple.com/videos/play/wwdc2025/298/)
- [WWDC25: Get Started with MLX](https://developer.apple.com/videos/play/wwdc2025/315/)
- [Apple Foundation Models Framework](https://developer.apple.com/documentation/FoundationModels)
- [MLX on M5 Neural Accelerators (Apple Research)](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)
- [LLM Inference on Apple Silicon (arXiv)](https://arxiv.org/abs/2511.05502)
- [vllm-mlx GitHub](https://github.com/waybarrios/vllm-mlx)
- [mlx-audio GitHub](https://github.com/Blaizzy/mlx-audio)

### Competitive
- [WisprFlow vs VoiceInk (WisprFlow)](https://wisprflow.ai/post/wispr-flow-vs-voiceink-2025)
- [Best Dictation Apps 2025 (Writingmate)](https://writingmate.ai/blog/best-dictation-app-for-mac)
- [9 Best Wispr Flow Alternatives (Voibe)](https://www.getvoibe.com/blog/wispr-flow-alternatives/)
