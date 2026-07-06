# ADR-001: Parakeet TDT 0.6B-v3 as Primary STT Engine

> Status: **Accepted**
> Date: 2026-02-08
> Runtime Note (2026-02-13): Runtime/mechanism details in this ADR are historical and superseded by ADR-007. ADR-001 remains authoritative for STT model choice.
> Note: GPU/LLM references (Qwen3-8B, "three-chip") are historical — the old on-device mlx-swift-lm path was removed 2026-02-23. Current LLM features use external providers or local CLI, while the speech runtime remains a two-chip architecture (CPU + ANE).
> Amendment (2026-04-28): Parakeet remains the **primary/default** STT engine. It is no longer the only engine. ADR-021 adds WhisperKit as an optional local multilingual engine for languages outside Parakeet's coverage.
> Amendment (2026-05-30): The Parakeet family now exposes both FluidAudio builds. Multilingual v3 remains the default/primary model chosen by this ADR; English-only v2 is an opt-in Parakeet model for users who want a faster no-auto-detect English path.
> Amendment (2026-06-08): Nemotron 3.5 is added as an opt-in Beta local multilingual engine through FluidAudio/CoreML. Parakeet v3 remains the primary/default STT engine; Nemotron is not a default replacement until real MacParakeet corpus benchmarks justify promotion.
> Amendment (2026-06-11): Nemotron Speech Streaming EN 0.6B (`english-1120ms`) is added as a second opt-in Beta build under the Nemotron engine, a peer of the multilingual build the way Parakeet v2 is a peer of v3. Parakeet v3 remains the primary/default STT engine; promotion of either Nemotron build still requires real MacParakeet corpus benchmarks.
> Amendment (2026-06-17): NVIDIA Parakeet Unified EN 0.6B (`unified`) is added as a third opt-in Parakeet build (English-only). Unlike the v2/v3 TDT builds it is a separate FluidAudio runtime (`UnifiedAsrManager`, no `AsrModelVersion`) served by a dedicated `ParakeetUnifiedEngine`, but it is presented to users as a Parakeet model. Parakeet v3 remains the primary/default; Unified provides strong English offline accuracy with punctuation/capitalization (FluidAudio v0.15.4 CoreML benchmark: 2.15% average / 1.68% aggregate WER on LibriSpeech test-clean; NVIDIA upstream card: 1.63% offline WER). Phase 1 shipped offline-only; the 2026-07-06 amendment below supersedes that initial runtime shape with FluidAudio's native low-latency streaming build (`parakeet-unified-2080ms`). Issue #520.
> Amendment (2026-07-06): Parakeet Unified now uses FluidAudio's native `StreamingUnifiedAsrManager` (`parakeet-unified-2080ms`) for final file transcription, meeting finalization, recorded-file dictation, and live dictation preview. FluidAudio v0.15.4 exposes token timings from that manager, so MacParakeet converts them into word timestamps for exports and speaker alignment. Unified remains English-only, opt-in, and non-default.
> Amendment (2026-06-19, integrated 2026-06-27): Cohere Transcribe (`cohere-transcribe-03-2026`, 2B, Apache-2.0) is added as an opt-in local accuracy engine. It runs fully on-device through the FluidAudio CoreML SDK already vendored here (FluidAudio >= 0.15.4 exposes a public `CoherePipeline`/`CohereAsrConfig` and a q8 CoreML repo); no MLX runtime or other new dependency is required, unlike the MLX-only candidates (Qwen3-ASR, Moonshine), which stay deferred. The gold-standard benchmark (`benchmarks/asr/`, hardened + independently verified in PR #568) found Cohere the most accurate on-device engine (full-LibriSpeech macro WER 2.07% vs 2.38% Parakeet-unified; best Japanese), but with a decisive cost: high resident memory, heavier cold-start/model prep, and ~2.1 GB download. Decision: Parakeet v3 remains the primary/default; Cohere is explicit opt-in, batch-only, user-downloaded, warned in Settings for model size/memory, and routed through `STTRuntime` by `CohereTranscribeEngine`. It has no live dictation preview, no meeting live chunks, and no word timestamps.

## Context

MacParakeet needs a fast, accurate, local speech-to-text engine for macOS on Apple Silicon. The STT engine is the core of the product -- it must be fast enough for real-time dictation, accurate enough for professional use, and run entirely on-device to honor our local-only commitment (see ADR-002).

The two leading local STT options are:

| Model | Speed | WER | Optimization |
|-------|-------|-----|--------------|
| Whisper (various sizes) | 15-30x realtime | 7-12% | ONNX, CoreML, MLX |
| Parakeet TDT 0.6B-v3 | ~300x realtime | ~6.3% | MLX (Apple Silicon native) |

Whisper has broader ecosystem support and language coverage (100+ languages including CJK), but Parakeet is faster, more accurate for English, and better optimized for Apple Silicon. Parakeet TDT v3 supports 25 European languages natively with auto-detection, though accuracy varies by language (~3-5% WER for English/Italian/Spanish/Portuguese, ~6-12% for French/German/Russian, higher for others).

## Decision

Use **Parakeet TDT 0.6B-v3** as the primary/default STT engine.

The original runtime described here used a Python daemon. ADR-007 superseded that runtime with FluidAudio CoreML/ANE. ADR-021 later added WhisperKit as an optional secondary engine. A 2026-05 update exposed FluidAudio's v2 English-only Parakeet build as an opt-in variant. A 2026-06 amendment adds Nemotron 3.5 as an opt-in Beta local engine. The durable decision in this ADR is v3's default/primary status.

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
- Better accuracy than Whisper for English and major European languages
- Native Apple Silicon performance via MLX
- Compact model size (~1.5GB download)
- Word-level timestamps and confidence scores included

### Negative

- **Requires Python daemon**: The parakeet-mlx library is Python-based, requiring a Python runtime managed by `uv`. This adds complexity to the app bundle and first-launch experience.
- **~1.5GB model download**: Users must download the model on first launch. Must handle this gracefully with progress indication and offline fallback messaging.
- **Apple Silicon only**: No Intel Mac support. This is acceptable given Apple Silicon's market penetration (all Macs since late 2020) and our target audience.
- **European languages only**: Parakeet TDT 0.6B-v3 supports 25 European languages natively with auto-detection, but does not cover CJK, Arabic, Hindi, or other non-European languages. ADR-021 resolves this product gap with optional local WhisperKit, while keeping Parakeet as the default.

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
| Model download | ~1.5-2.5 GB (MLX weights) | ~465 MB fetched components per Parakeet build (current); full CoreML repos are larger |
| Dependencies | Python + uv + venv | SwiftPM (FluidAudio) |
| IPC | JSON-RPC over stdin/stdout | In-process async/await |

### Why

1. **Three-chip utilization** — Moving STT to the ANE frees the GPU entirely for the Qwen3-8B LLM. Zero compute contention.
2. **Memory efficiency** — ~66 MB working RAM (vs ~2 GB+) makes 8GB Macs viable for both STT and LLM simultaneously.
3. **Better accuracy** — FluidAudio's CoreML decoding achieves ~2.5% WER (vs ~6.3% on MLX). Same model weights, better decoding.
4. **Eliminates Python** — No venv, no subprocess, no codesigning issues. Pure Swift. App Store compatible.
5. **Simpler architecture** — Native Swift async/await replaces JSON-RPC daemon management.

### Consequences Update

The "Requires Python daemon" negative consequence from the original ADR is resolved. The pre-implementation concern about a very large full CoreML repo download is mitigated in current FluidAudio usage: MacParakeet fetches only the loaded components, roughly ~465 MB per Parakeet build.

See `docs/research/fluidaudio-stt-migration.md` for the full evaluation.

## Addendum: Optional WhisperKit Secondary Engine (April 2026)

> Date: 2026-04-28

Parakeet remains the default engine for dictation, file transcription, and meeting recording. WhisperKit is available as an explicit local secondary engine for broader multilingual coverage. The user can select it in Settings or per CLI invocation. Active meeting recordings capture the engine/language at start so live preview, final transcription, and crash recovery stay deterministic.

See ADR-021 for the full decision.

## Addendum: Optional Nemotron Beta Engine (June 2026)

> Date: 2026-06-08

Parakeet remains the default engine for dictation, file transcription, and meeting recording. Nemotron 3.5 ASR Streaming 0.6B is available as an explicit Beta local engine through FluidAudio/CoreML. It can be selected in Settings or per CLI invocation, and active meeting recordings capture the engine/language at start so live preview, final transcription, and crash recovery stay deterministic.

Nemotron is labeled Beta because the first MacParakeet smoke benchmark showed strong warm-path speed but weaker English-heavy transcript quality than Parakeet on the synthetic corpus. It should not replace Parakeet as the default without a larger real-world dictation/meeting benchmark.

> Amendment (2026-06-20): MacParakeet now preserves FluidAudio's Nemotron token
> timings through `finishWithTokenTimings()` and maps them into `STTResult.words`
> for both Nemotron builds. Timed transcript views, subtitle exports, and
> meeting speaker-turn assembly can therefore use Nemotron timestamps when the
> upstream manager reports them; the engine remains Beta for quality reasons.

## Addendum: Nemotron English Beta Build (June 2026)

> Date: 2026-06-11

The Nemotron engine now exposes two builds, selected through a persisted
Nemotron model preference (Settings build picker, `config set nemotron-model`,
`models select nemotron-english-1120ms`, or `transcribe --nemotron-model`):

- `multilingual-1120ms` (default) — the Nemotron 3.5 multilingual build from
  the 2026-06-08 amendment, with the existing `nemotron-language` hint.
- `english-1120ms` — **Nemotron Speech Streaming EN 0.6B** (FastConformer-RNNT,
  ~600 MB CoreML download via `FluidInference/nemotron-speech-streaming-en-0.6b-coreml`,
  1120 ms chunk tier). English-only; it has no language-hint surface, so the
  stored `nemotron-language` is ignored while it is selected. Vendor-published
  benchmarks (M5 Pro: 2.28% WER / 65x RTFx at the 1120 ms tier, 100-file
  LibriSpeech subset) motivated surfacing it — see
  `docs/research/stt-models-and-voice-personalization-2026-06.md` §2.1 and
  roadmap item 2 (§9) (June 2026 STT research, currently on the
  `research/stt-models-voice-personalization` branch pending merge).

Scope notes: file and meeting jobs run batch-at-stop through the streaming
manager; MacParakeet maps FluidAudio token timings into word-level timestamps
when the EN build reports them, and only the 1120 ms tier is surfaced. Build
swaps follow the same scheduler guards as
Parakeet v2/v3 swaps (ADR-016). License posture: FluidAudio and its CoreML
conversion are Apache-2.0, but upstream NVIDIA model terms are not publicly
verifiable, so the model stays a user-triggered download — never bundled.

> Amendment (2026-06-14): the EN build now also streams **live dictation
> partials** (the display-only live transcript preview) through its native
> streaming path, matching the multilingual build; file and meeting jobs remain
> batch-at-stop. Gated by `AppFeatures.liveDictationStreamingEnabled`. See
> `plans/active/2026-06-13-live-dictation-streaming-parakeet-and-preview-ui.md`
> and `docs/research/live-dictation-streaming.md`.

Both Nemotron builds remain Beta; fresh installs default to Parakeet v3.
Promotion criteria are unchanged: real MacParakeet corpus benchmarks
(dictation + meeting audio with corrected transcripts), not vendor numbers.

## Addendum: Parakeet Unified English Build (June 2026)

> Date: 2026-06-17

The Parakeet model picker now exposes a third build alongside v3/v2, selected
through the persisted Parakeet model preference (Settings build picker,
`config set parakeet-model unified`, `models select parakeet-unified`, or
`transcribe --parakeet-model unified`):

- `unified` — **NVIDIA Parakeet Unified EN 0.6B** (Unified-FastConformer-RNNT,
  ~565 MB int8 CoreML download via
  `FluidInference/parakeet-unified-en-0.6b-coreml`, requires FluidAudio ≥
  0.15.3). English-only; no language-hint surface.

Architecturally Unified is **not** a TDT build: it has its own
preprocessor/encoder/decoder CoreML chain and no `AsrModelVersion`, so it is
served by a dedicated `ParakeetUnifiedEngine` (wrapping FluidAudio's
`StreamingUnifiedAsrManager`) that `STTRuntime` routes to when the persisted
`ParakeetModelVariant` is `.unified` — the same way the Nemotron engine routes
its English build. It is presented to users as a Parakeet model because that is
how the feature was requested (issue #520) and how users reason about it.

Why it earns a slot: FluidAudio's v0.15.4 CoreML benchmark on the full
LibriSpeech test-clean set (2620 files) puts the **offline** build at **2.15%
average WER / 1.68% aggregate WER** with punctuation/capitalization, while
NVIDIA's own model card reports 1.63% offline test-clean WER. It is a
competitive English opt-in, not a v3 replacement. Unlike v2/v3 it was also
trained for streaming; MacParakeet now uses the native streaming path for final
transcripts because FluidAudio v0.15.4 exposes token timings there.

Scope notes: file, meeting, final dictation-paste jobs, and live dictation
preview use FluidAudio's native low-latency streaming build
(`parakeet-unified-2080ms`, `StreamingUnifiedAsrManager`, ~2.08 s partials).
The build exposes token-derived word-level timestamps through MacParakeet, so
exports and speaker alignment work the same way they do for other timestamped
engines. Build swaps follow the same scheduler guards as v2/v3 swaps (ADR-016).
License posture: FluidAudio's conversion is Apache-2.0 and the
upstream model is under the NVIDIA Open Model License Agreement, so — like every
other model — it stays a user-triggered download, never bundled. Fresh installs
still default to Parakeet v3.

## Addendum: Cohere Transcribe Opt-In Engine (June 2026)

> Date: 2026-06-19
> Status: **Accepted** (integrated 2026-06-27 as opt-in, batch-only)

A gold-standard cross-engine benchmark (`benchmarks/asr/`, hardened and
independently verified in PR #568) evaluated Cohere Transcribe
(`cohere-transcribe-03-2026`, 2B params, Apache-2.0, #1 on the HF Open ASR
Leaderboard) as a candidate on-device engine. PR #602 integrates it as an
explicit opt-in engine for accuracy-critical record-then-transcribe work.

**It is FluidAudio CoreML, not MLX.** FluidAudio ≥ 0.15.4 — the exact SDK
MacParakeet already depends on — ships a public `CoherePipeline` actor and a q8
CoreML model repo (`FluidInference/cohere-transcribe-03-2026-coreml`). So Cohere
needs **no new runtime**: `CohereTranscribeEngine` wraps the FluidAudio pipeline,
routes inside `STTRuntime`, and uses a user-triggered `cohere-transcribe` model
download. This is what distinguishes it from the deferred MLX-only candidates
(Qwen3-ASR, Moonshine).

**Findings** (Apple M4 Pro; full LibriSpeech + FLEURS; one canonical normalizer;
paired-bootstrap significance):
- Most accurate on-device engine — English macro WER **2.07%** (vs 2.38%
  Parakeet-unified, 3.00% Whisper); best Japanese (FLEURS CER 5.56 vs Whisper 13.42).
- The accuracy lead is *statistically significant* only on **noisy English**
  (`test-other`) and **Japanese**; clean English, Korean, and Chinese are ties
  with the best alternative.
- Cost is the decisive factor: **~11 GB peak resident memory** (constant across
  file counts → model-resident, measured via the FluidAudio reference harness),
  **~73 s one-time ANE compile**, **~11× realtime** (vs ~70× / ~120 MB for
  Parakeet), ~2.1 GB download.

**Decision:** keep Parakeet v3 the default and WhisperKit the light multilingual
option. Ship Cohere as an explicit opt-in engine with a clear download-size /
memory warning, surfaced for accuracy-critical, noisy, or Japanese
transcription. Do not hard-gate RAM in this integration; the Settings copy
warns about higher memory use and the model is never bundled. Cohere is
batch-only: dictation records first and transcribes on stop; meetings use
Cohere only for final transcription, not live preview chunks; transcripts have
no word timestamps or speaker alignment. Both Nemotron builds are dominated by
Parakeet in this benchmark (settling #520).

See `benchmarks/asr/README.md` (PR #568) for the full methodology, CIs, and
speed/memory tables; `plans/active/asr-benchmark-and-model-expansion.md` for the
candidate landscape.

## References

- [NVIDIA Parakeet TDT 0.6B-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- [NVIDIA Parakeet Unified EN 0.6B](https://huggingface.co/nvidia/parakeet-unified-en-0.6b) -- English-only unified offline+streaming build (issue #520)
- [FluidAudio PR #693](https://github.com/FluidInference/FluidAudio/pull/693) -- Parakeet Unified CoreML backend (v0.15.3)
- [FluidAudio](https://github.com/FluidInference/FluidAudio) -- CoreML/ANE runtime for Apple Silicon
- [parakeet-mlx](https://github.com/senstella/parakeet-mlx) -- MLX port (original runtime, superseded)
- [ADR-021: WhisperKit as Optional Multilingual STT Engine](021-whisperkit-multilingual-stt.md)
- [Nemotron 3.5 ASR Streaming 0.6B](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)
- [FluidInference/cohere-transcribe-03-2026-coreml](https://huggingface.co/FluidInference/cohere-transcribe-03-2026-coreml) -- q8 CoreML conversion of Cohere Transcribe (the on-device path; evaluated in PR #568 and integrated as opt-in in PR #602)
- Oatmeal project ADR-011 (prior art for Parakeet selection)
