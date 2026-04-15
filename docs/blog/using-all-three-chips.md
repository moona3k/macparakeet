# Using All Three Chips: How We Rebuilt MacParakeet's Speech Engine for Apple Silicon

> Status: **HISTORICAL** - The old on-device Qwen3-8B / mlx-swift-lm path was removed 2026-02-23. GPU-local LLM content below is outdated; current LLM features use external providers or local CLI, while core speech remains a two-chip architecture (CPU + ANE).

*MacParakeet Engineering*

---

Your Mac has a chip inside it that most apps never touch. Not the CPU. Not the GPU. A third one — purpose-built for exactly the kind of work MacParakeet does.

This is the story of how we found it, why it matters, and what it means for running two AI models on your Mac without breaking a sweat.

---

## The Challenge: Two Models, One App

MacParakeet does two things with AI:

1. **Speech-to-text** — We use NVIDIA's Parakeet TDT, a 600-million-parameter model that turns your voice into text. When you press your hotkey and speak, Parakeet transcribes your speech at over 150x real-time speed.

2. **Text refinement** — We use Qwen3-8B, an 8-billion-parameter language model that cleans up, reformats, and refines your dictated text. Raw speech becomes polished prose — formal tone, email format, code comments, whatever you need.

Both models run entirely on your Mac. No cloud. No API calls. No data leaving your machine.

The question we kept coming back to: **where exactly on your Mac should each model run?**

---

## What's Actually Inside Apple Silicon

Most people think of their Mac as having two compute units: the CPU for general tasks and the GPU for graphics and heavy math. That's how Intel Macs worked, more or less.

Apple Silicon is different. Every M-series chip — from the base M1 to the M4 Ultra — has **three** distinct processors on the same die:

```
Apple Silicon
├── CPU    General-purpose cores. Runs your app, the OS, everything "normal."
├── GPU    Parallel compute. Graphics, Metal shaders, and general-purpose ML via MLX.
└── ANE    Neural Engine. A dedicated accelerator built specifically for ML inference.
```

These aren't software abstractions. They're physically separate silicon with their own transistors, their own processing pipelines, and the ability to run simultaneously. When the GPU is busy, the ANE can be doing completely different work at the same time.

They do share one thing: **unified memory**. Unlike a PC with dedicated VRAM, all three processors draw from the same memory pool. An 8GB Mac has 8GB for everything — CPU, GPU, and ANE included. This makes memory the shared bottleneck, which matters when you're running two AI models.

Most apps use the CPU. Games and creative tools use the GPU. Very few apps touch the Neural Engine at all.

We weren't using it either.

---

## Our Original Architecture

When we first built MacParakeet, we needed to get Parakeet TDT running on Apple Silicon. NVIDIA trains their models for NVIDIA GPUs — there's no official "run this on a Mac" path. The fastest route was **parakeet-mlx**, a Python package that runs Parakeet using Apple's MLX framework.

MLX is Apple's machine learning framework, and it's fast — the fastest way to run many models on a Mac. It works by running computations on the GPU via Metal, Apple's graphics API. For our speech-to-text model, this meant:

- A Python daemon running in the background
- Communicating with our Swift app over JSON-RPC (a text protocol over stdin/stdout)
- Parakeet running on the GPU via MLX/Metal

For the LLM (Qwen3-8B), we use **MLX-Swift** — the native Swift version of the same framework. Also runs on the GPU via Metal.

Here's what that architecture looked like:

```
CPU:  MacParakeet app (UI, hotkeys, clipboard, history)
GPU:  Parakeet STT (via Python/MLX) + Qwen3-8B LLM (via MLX-Swift)
ANE:  [idle]
```

Two ML models sharing one GPU. A dedicated ML accelerator doing nothing.

This worked. We shipped it. Users could dictate, transcribe files, and get their text refined — all locally, all fast. But we knew it wasn't the right long-term architecture.

---

## The Problem with Sharing

When you dictate in MacParakeet with AI refinement enabled, the pipeline looks like this:

```
You speak → Parakeet transcribes (GPU) → Qwen3 refines (GPU) → polished text
```

Both steps run on the GPU. They run sequentially — Parakeet finishes, then Qwen3 starts — so they don't literally fight for cycles at the same moment. But they do share the GPU's memory pool.

Parakeet via MLX occupies roughly 2GB of GPU memory. Qwen3-8B at 4-bit quantization needs another ~5GB. On an 8GB Mac (the most common configuration for MacBooks), that leaves very little room for macOS itself. The math gets tight:

| What | Memory |
|------|--------|
| Parakeet STT (MLX/GPU) | ~2GB |
| Qwen3-8B LLM (MLX/GPU) | ~5 GB |
| macOS + app overhead | ~2-3GB |
| **Total** | **~9-10GB** |

On an 8GB machine, that's well over budget and actively swapping. And this is before the user opens a browser or Slack alongside MacParakeet.

Meanwhile, the Neural Engine — a chip Apple designed specifically for running neural networks efficiently — is doing absolutely nothing.

---

## The Discovery: FluidAudio

We found [FluidAudio](https://github.com/FluidInference/FluidAudio), an open-source Swift SDK by a team called FluidInference. They solve a specific problem: taking AI models trained for NVIDIA GPUs and making them run on Apple's Neural Engine via CoreML.

Think of it this way: NVIDIA trains Parakeet for their hardware. FluidInference converts it to run on *Apple's* hardware — specifically the ANE, not the GPU. Same model weights, but optimized decoding for Apple's silicon.

Their SDK wraps the converted models in a clean Swift API:

```swift
let models = try await AsrModels.downloadAndLoad(version: .v3)
let manager = AsrManager(config: .default)
try await manager.initialize(models: models)

let result = try await manager.transcribe(audioSamples, source: .system)
// result.text contains the transcription
```

Five lines. Native Swift. Async/await. No Python. No subprocess. No JSON-RPC. The transcription runs on the Neural Engine.

FluidAudio isn't new or unproven — over 20 production apps ship with it, including VoiceInk, a well-known macOS dictation app. It supports Parakeet TDT v2 (English) and v3 (25 European languages), and bundles speaker diarization, voice activity detection, and streaming speech recognition alongside batch transcription. All Apache 2.0 licensed.

---

## The New Architecture

With FluidAudio, we can put each workload on the chip it belongs on:

```
CPU:  MacParakeet app (UI, hotkeys, clipboard, history)
GPU:  Qwen3-8B LLM (via MLX-Swift)  — full GPU, no sharing
ANE:  Parakeet STT (via FluidAudio/CoreML) — dedicated ML chip, finally used
```

Three workloads. Three chips. Zero contention.

The dictation pipeline becomes:

```
You speak → Parakeet transcribes (ANE) → Qwen3 refines (GPU) → polished text
```

And the memory picture improves dramatically. FluidAudio's CoreML path uses roughly **66 MB of working memory** for the speech model during inference, compared to the 2GB+ that the MLX/GPU path occupies. On an 8GB Mac, that's the difference between "barely fits" and "runs with headroom."

---

## Speed: Does the ANE Keep Up?

The GPU is faster in raw throughput. MLX on the GPU processes audio at roughly 300x real-time; CoreML on the ANE runs at about 155x. That sounds like a big difference until you translate it to actual seconds:

| What you're transcribing | GPU (MLX) | ANE (CoreML) |
|--------------------------|-----------|-------------|
| A quick voice note (10 seconds) | 0.03s | 0.06s |
| A dictated paragraph (1 minute) | 0.2s | 0.4s |
| A meeting recording (30 minutes) | 6s | 12s |
| A full lecture (1 hour) | 12s | 23s |

For dictation — which is what MacParakeet users do most — both feel instant. The difference between 0.2 and 0.4 seconds is not something a human perceives.

For long file transcription, the ANE is still remarkably fast. Twenty-three seconds for an hour of audio. We'll take that trade-off gladly in exchange for better memory efficiency and zero GPU contention.

---

## Better Accuracy, Too

Here's something we didn't expect: the CoreML path is actually *more accurate* than our previous MLX setup.

FluidAudio's optimized decoding achieves roughly **2.5% word error rate** on standard benchmarks — compared to the ~6% we were seeing with the MLX/GPU path. Same Parakeet model, same weights, but FluidInference's CoreML implementation produces measurably better transcriptions.

We're still investigating why — likely their CTC/TDT decoding optimizations recover more accurate word sequences from the model's output. Whatever the reason, moving to the ANE didn't just save memory and free the GPU. It made our transcriptions better.

---

## The Model Size Tradeoff

There is one cost: the CoreML model bundle is larger. The MLX version weighs about 2.5 GB; the CoreML version is roughly 6 GB.

Why? MLX stores model weights in a compact format that the GPU interprets at runtime. CoreML stores **pre-compiled, hardware-optimized model graphs** — separate bundles for the encoder, decoder, joint network, and preprocessor, each optimized for the ANE's specific execution pipeline. Think of it like the difference between source code and a compiled binary: more bytes on disk, but faster and more efficient execution.

For a one-time download during first launch, we think that's a fair trade. Lower memory usage, better accuracy, and a simpler architecture are worth an extra few gigabytes of initial download.

---

## What Else We Get

Moving to FluidAudio isn't just about which chip runs the transcription. It simplifies the entire stack.

**Before:** Our app bundles a Python runtime, bootstraps a virtual environment on first launch, installs dependencies, spawns a background daemon, and communicates over a text protocol. Every Python binary needs to be individually codesigned for macOS distribution. A macOS update can break the virtual environment silently.

**After:** One Swift package. One framework to sign. Standard async/await calls. If it compiles, it runs.

We also pick up capabilities we would have had to build ourselves:

- **Speaker diarization** — identify who said what, built into the SDK
- **Voice activity detection** — know when someone is speaking vs. silence
- **Streaming ASR** — real-time transcription as audio arrives, not just batch processing
- **Custom vocabulary boosting** — improve recognition of domain-specific terms at the neural level

These aren't the reason we're making this change — the architecture is. But they're a welcome bonus.

---

## Why Parakeet, Not Whisper

A natural question: why not use OpenAI's Whisper? It's the most well-known open-source speech model.

The short answer is that Parakeet is better at the job:

| | Parakeet TDT 0.6B | Whisper Large V3 |
|---|---|---|
| Word Error Rate | ~2.5% | ~7.4% |
| Speed (CoreML/ANE) | ~155x real-time | ~12x real-time |
| Parameters | 600M | 1.55B |
| Memory | ~66 MB working RAM | ~10GB |

Parakeet is more accurate, 13x faster, one-third the size, and uses a fraction of the memory. It ranks #3 on the Open ASR Leaderboard for accuracy while being #1 for speed. The two models above it in accuracy (NVIDIA's Canary Qwen 2.5B and IBM's Granite Speech) are 8-100x slower.

The Whisper ecosystem is also stagnating. OpenAI hasn't released a new open-source Whisper model since November 2023. They've shifted to proprietary, cloud-only transcription models. Meanwhile, Parakeet got a multilingual update (v3, August 2025) supporting 25 European languages, and the FluidAudio team continues to optimize its Apple Silicon performance.

Even Apple's own SpeechAnalyzer — their native on-device transcription API introduced in macOS 26 — scores roughly 8% WER. Parakeet on FluidAudio beats Apple's own offering.

We chose the right model. Now it runs on the right chip.

---

## The Bigger Picture

There's a broader principle here that we think about a lot: **use the hardware you have.**

Apple spent billions designing custom silicon with three distinct compute units. Most apps use one or two of them. The Neural Engine — the one Apple specifically designed for AI workloads — sits idle in the vast majority of applications.

When you build a product that runs AI locally, you have a choice: take the path of least resistance (everything on the GPU), or take the time to put each workload where it belongs. The second path is harder. It requires understanding the hardware, finding the right tools, and rebuilding your foundation.

But the result is an app that uses your Mac the way Apple designed it to be used. Three chips, three jobs, zero waste.

That's what we're building.

---

*MacParakeet is a fast, private, local-first voice app for macOS with system-wide dictation and file transcription. No cloud. No subscriptions. Learn more at [macparakeet.com](https://macparakeet.com).*
