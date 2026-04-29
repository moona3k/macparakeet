# Asian Language STT Options for MacParakeet

> Status: **HISTORICAL** — Research findings from before the WhisperKit implementation
> Last verified: 2026-04-02
> Implementation update: ADR-021 added optional local WhisperKit support on main for broad multilingual coverage. Parakeet remains the default engine.

## Summary

MacParakeet uses Parakeet TDT 0.6B-v3 via FluidAudio CoreML, which supports **25 European languages only**. This document evaluates options for adding Asian language support (Korean, Japanese, Chinese, and others).

**Bottom line:** No model matches Parakeet's speed (~155x realtime baseline, ~190x on M4 Pro) for Asian languages today. The best available option is **Qwen3-ASR-0.6B via FluidAudio CoreML** (~3–5x realtime), which is already shipped in FluidAudio v0.12.1+ and requires no new dependencies. Accuracy is strong — it beats Whisper large-v3 (a 2.5x larger model) on Chinese and is competitive on Korean/Japanese.

---

## Current Engine: Parakeet TDT 0.6B-v3

| Property | Value |
|----------|-------|
| Architecture | CTC/TDT (non-autoregressive — all tokens predicted in parallel) |
| Languages | 25 European (EU official languages + Russian, Ukrainian) |
| English WER | ~1.93% (LibriSpeech test-clean) |
| Speed | ~155x realtime baseline (M1); ~190x on M4 Pro |
| Working memory | ~66 MB |
| Model size on disk | ~6 GB CoreML bundle |
| Asian languages | **None** |

Source: [nvidia/parakeet-tdt-0.6b-v3 (HuggingFace)](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)

---

## Option 1: Qwen3-ASR-0.6B via FluidAudio CoreML (Recommended)

**FluidAudio already ships a CoreML conversion**, optimized for ANE. No new dependency needed.

| Property | Value |
|----------|-------|
| Architecture | Encoder-decoder (autoregressive, 1-second chunks) |
| Languages | 30 languages + 22 Chinese dialects (52 total) |
| Parameters | 0.6B (180M audio encoder + Qwen3-0.6B decoder) |
| License | Apache 2.0 |
| Model size | ~2.5 GB (f32) or ~0.7 GB (int8 quantized) |
| FluidAudio version | v0.12.1+ (per [GitHub releases](https://github.com/FluidInference/FluidAudio/releases)); ANE-optimized in v0.12.6 |
| CoreML model | [FluidInference/qwen3-asr-0.6b-coreml](https://huggingface.co/FluidInference/qwen3-asr-0.6b-coreml) |
| Word timestamps | Yes, via companion [Qwen3-ForcedAligner-0.6B](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B) (42.9ms avg alignment accuracy) |

### Speed (M4 Pro, via FluidAudio CoreML)

| Benchmark | Realtime Factor |
|-----------|----------------|
| English (LibriSpeech test-clean) | ~2.8x realtime |
| Chinese (AISHELL-1 test) | ~4.5x realtime |

For a 5-second dictation: **~1–1.5 seconds** processing time. Usable, not instant.
For a 60-minute file: **~13–20 minutes** processing time (vs ~19 seconds with Parakeet).

### Accuracy — Asian Languages

**Korean:**

| Benchmark | Qwen3-ASR-0.6B (CER) | Qwen3-ASR-1.7B (CER) |
|-----------|-----------------------|-----------------------|
| Fleurs | 3.72% | **2.57%** |
| CommonVoice | 8.48% | **5.88%** |
| MLC-SLM | 10.31% | **8.61%** |

**Chinese (Mandarin):**

| Benchmark | Whisper-large-v3 (CER) | Qwen3-ASR-0.6B (CER) | Qwen3-ASR-1.7B (CER) |
|-----------|------------------------|-----------------------|-----------------------|
| AISHELL-2 test | 5.06% | 3.15% | **2.71%** |
| WenetSpeech net | 9.86% | 5.97% | **4.97%** |
| WenetSpeech meeting | 19.11% | 6.88% | **5.88%** |
| SpeechIO | 7.56% | 3.44% | **2.88%** |

**Japanese:**

| Benchmark | Qwen3-ASR-0.6B (CER) | Qwen3-ASR-1.7B (CER) |
|-----------|-----------------------|-----------------------|
| Fleurs | 8.33% | **5.20%** |
| CommonVoice | 14.96% | **11.64%** |
| MLC-SLM | 14.74% | **11.80%** |

**English (for comparison):**

| Benchmark | Parakeet TDT v3 0.6B (WER) | Whisper-large-v3 1.55B (WER) | Qwen3-ASR-0.6B (WER) |
|-----------|----------------------------|------------------------------|-----------------------|
| LibriSpeech clean | **1.93%** | 1.51% | 2.11% |
| LibriSpeech other | — | 3.97% | 4.55% |

*Note: Whisper large-v3 edges Parakeet on LibriSpeech clean, but it's 2.5x larger (1.55B vs 0.6B params). Parakeet's ~2.5% WER cited elsewhere in the project is the Open ASR Leaderboard average across diverse benchmarks.*

Sources:
- [Qwen/Qwen3-ASR-0.6B model card (HuggingFace)](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)
- [Qwen3-ASR technical report (arXiv:2601.21337)](https://arxiv.org/html/2601.21337v1)
- [FluidInference/qwen3-asr-0.6b-coreml (HuggingFace)](https://huggingface.co/FluidInference/qwen3-asr-0.6b-coreml)

### Why 0.6B and Not 1.7B?

Qwen3-ASR-1.7B has significantly better accuracy (see tables above), but it's 2.8x larger and would be even slower than the 0.6B's ~3–5x realtime. For dictation latency, smaller is better. The 0.6B already beats Whisper large-v3 on Chinese despite being 2.5x smaller. The 1.7B remains an option for file transcription where latency matters less.

### Memory and Cold Start

Memory footprint for Qwen3-ASR-0.6B via CoreML is not yet benchmarked publicly. For comparison, Parakeet uses ~66 MB working memory. Running both engines simultaneously (Parakeet for European + Qwen3 for Asian) may have memory implications worth measuring. Cold-start model loading time is also an open question — the first transcription after app launch may have additional latency.

### Supported Languages (Full List)

**30 languages:** zh, en, yue, ar, de, fr, es, pt, id, it, ko, ru, th, vi, ja, tr, hi, ms, nl, sv, da, fi, pl, cs, fil, fa, el, hu, mk, ro

**22 Chinese dialects:** Anhui, Dongbei, Fujian, Gansu, Guizhou, Hebei, Henan, Hubei, Hunan, Jiangxi, Ningxia, Shandong, Shaanxi, Shanxi, Sichuan, Tianjin, Yunnan, Zhejiang, Cantonese (HK), Cantonese (Guangdong), Wu, Minnan

---

## Option 2: WhisperKit (Argmax)

OpenAI Whisper models compiled for CoreML by [Argmax](https://github.com/argmaxinc/WhisperKit), who also develops FluidAudio. MIT license.

| Property | Value |
|----------|-------|
| Architecture | Encoder-decoder (autoregressive, 30-second windows) |
| Languages | 99 (all major Asian languages) |
| Model sizes | tiny (~80 MB) to large-v3 (~3 GB, ~947 MB quantized) |
| License | MIT |
| Speed (large-v3, M-series) | ~5–15x realtime |
| English WER (large-v3) | ~1.51% LibriSpeech clean |
| Word timestamps | Yes (via decoder attention alignment) |
| Extras | Translation (any → English), SpeakerKit diarization |
| Swift package | [github.com/argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit) |

### Why NOT WhisperKit

- **Adds a new dependency** (swift-transformers via HuggingFace) — FluidAudio is already in the project
- **Worse CJK accuracy** than Qwen3-ASR at comparable model sizes
- **Argmax positions FluidAudio/Parakeet as the faster successor** — their WhisperKit README promotes their Pro SDK as "9x faster and higher accuracy"
- **Hallucination on silence** — Whisper generates phantom text on quiet audio, problematic for hold-to-talk dictation

### When WhisperKit WOULD make sense

- If targeting a language Qwen3-ASR doesn't cover (Qwen3 has 30 languages; Whisper has 99)
- If translation (any language → English) becomes a feature
- If FluidAudio's Qwen3-ASR integration proves unreliable

---

## Option 3: NVIDIA Parakeet Language-Specific Variants

NVIDIA is training per-language Parakeet models with the same fast CTC/TDT architecture:

| Model | Language | CER | Training Data | CoreML? |
|-------|----------|-----|---------------|---------|
| [parakeet-tdt_ctc-0.6b-ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | Japanese | 6.4% (JSUT) | ReazonSpeech v2.0 (35K+ hours) | **No** |
| parakeet-ctc-0.6b-Vietnamese | Vietnamese + English | — | — | **No** |
| Parakeet-RNNT-1.1B (via Riva NIM) | ja, ko, th, hi, ar + European | — | — | **No** (server-side) |

**Status:** These exist as NeMo checkpoints but have **no CoreML conversions**. If FluidAudio converts them, they could potentially provide Parakeet-class speed for those specific languages (speed unverified — no CoreML benchmarks exist). This is the path to a snappy Korean/Japanese experience, but it doesn't exist yet.

Source: [NVIDIA Riva ASR Support Matrix](https://docs.nvidia.com/nim/riva/asr/latest/support-matrix.html)

---

## Option 4: SenseVoice-Small (Alibaba/FunAudioLLM)

| Property | Value |
|----------|-------|
| Architecture | Non-autoregressive (like Parakeet — fast) |
| Languages | 50+ (strong on Chinese, Cantonese, Japanese, Korean, English) |
| Speed | ~15x faster than Whisper (claimed) |
| License | MIT |
| CoreML? | **No** — ONNX export available, no CoreML conversion |
| Source | [github.com/FunAudioLLM/SenseVoice](https://github.com/FunAudioLLM/SenseVoice) |

**Interesting because** it's non-autoregressive (fundamentally faster) and strong on CJK. But without a CoreML conversion, it can't run on ANE. Would need someone (FluidAudio?) to convert it.

---

## Comparison Matrix

| Engine | Korean/CJK | Speed (RTFx) | CoreML Ready | New Dependency? | Accuracy (CJK) |
|--------|-----------|-------------|-------------|-----------------|-----------------|
| **Parakeet TDT v3** | No | ~155x (baseline) | Yes | No (current) | N/A |
| **Qwen3-ASR-0.6B** | Yes | ~3–5x | Yes (FluidAudio) | **No** | Strong (beats Whisper on Chinese) |
| WhisperKit large-v3 | Yes | ~5–15x | Yes | **Yes** (new pkg) | Good |
| Parakeet-ja (NeMo) | Japanese only | Unknown (no CoreML) | **No** | N/A | Good (6.4% CER JSUT) |
| SenseVoice-Small | Yes | ~15x (est.) | **No** | N/A | Strong |

---

## Architecture Assessment

MacParakeet's `STTClientProtocol` is already engine-agnostic. Both `DictationService` and `TranscriptionService` depend only on the protocol. Adding a second engine requires:

1. A new `STTClientProtocol` conformance (e.g., `QwenSTTClient`) wrapping FluidAudio's Qwen3-ASR API
2. A routing layer in `AppEnvironment` that picks the engine based on language setting
3. Model download/cache management for the second model (~0.7–2.5 GB)
4. UX for language selection (Settings → Language picker)

No refactoring of services, database, or UI needed — the protocol boundary is clean.

### Open UX Questions

- **Who picks the engine?** User sets language in Settings (simplest) vs auto-detect (seamless but harder)
- **How to communicate the speed difference?** Korean dictation at ~1–1.5s feels different from English at ~30ms
- **Dual model downloads?** Lazy-download Qwen3 model on first non-European language use to avoid bloating onboarding

---

## Recommendation

**Wait, but be ready.**

1. **No code changes now.** The architecture is clean and ready. Demand for Asian languages hasn't been demonstrated yet.
2. **Monitor FluidAudio releases.** If they ship CoreML conversions of NVIDIA's per-language Parakeet models (especially `parakeet-tdt_ctc-0.6b-ja` for Japanese), that's the ideal path — same speed, no architectural tradeoffs.
3. **If demand materializes**, implement Qwen3-ASR-0.6B via FluidAudio. It's already CoreML-ready, requires no new dependencies, and has strong CJK accuracy. The ~3–5x realtime speed is acceptable for dictation (short utterances) even if not ideal for long file transcription.
4. **Don't add WhisperKit** unless targeting languages beyond Qwen3-ASR's 30-language list.

---

## Future Signals to Watch

- **NVIDIA NeMo releases**: New Parakeet variants for CJK languages
- **FluidAudio releases**: CoreML conversions of per-language Parakeet models or SenseVoice
- **Qwen3-ASR updates**: Faster inference, larger language coverage
- **User feedback**: Requests for specific Asian languages in macparakeet-community issues
- **SenseVoice CoreML**: If someone converts SenseVoice to CoreML, it could offer near-Parakeet speed for CJK

---

*Research compiled April 2, 2026. Benchmark numbers verified against official model cards and arXiv paper.*
