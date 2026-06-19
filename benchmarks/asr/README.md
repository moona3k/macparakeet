# MacParakeet ASR Benchmark

A reusable, **apples-to-apples** benchmark for comparing on-device ASR engines
on accuracy and speed. Every engine's hypotheses are scored through **one
canonical normalizer** (Whisper `EnglishTextNormalizer` / `BasicTextNormalizer`,
the HF Open ASR Leaderboard standard) so cross-engine numbers are directly
comparable — the single most important property a multi-model benchmark must have.

> Supersedes the LibriSpeech-`test-clean`-only `benchmarks/parakeet-unified/`
> evidence (kept for history). English numbers below are the **full** test sets;
> multilingual is a capped FLEURS first pass (see "Status").

## Methodology

Modeled on the HuggingFace **Open ASR Leaderboard** (arXiv 2510.06961), `jiwer`,
`whisper-normalizer`, and the WhisperKit/Soniqo Apple-Silicon harnesses:

- **Datasets:** English — LibriSpeech `test-clean` (clean read speech, a near-
  saturated *ceiling*) + `test-other` (noisier; exposes clean-only tuning), full
  sets (2620 + 2939). Multilingual — **FLEURS** en/ko/ja/zh (`FluidInference/fleurs-full`).
  Roadmap: a spontaneous/meeting set (AMI/GigaSpeech) and an accented set.
- **Normalizer:** Whisper `EnglishTextNormalizer` for English (`whisper-normalizer==0.1.12`;
  lowercase, strip punct, expand contractions, fold number words, British→American),
  `BasicTextNormalizer` for other languages — applied identically to ref and hyp
  for **every** engine. A `--simple` fallback reads ~0.16pt higher.
- **Metric:** **WER** = `(S+D+I)/N` for space-delimited languages (en, EU);
  **CER** (character error rate) for ko/ja/zh, where word boundaries are
  unreliable (Korean spacing is inconsistent → CER, the standard choice; word-WER
  is dominated by segmentation noise). Levenshtein via `jiwer`/RapidFuzz. We report
  **corpus** error per dataset, **macro-average** across datasets, and the
  **per-utterance** distribution (p90, failure-rate = share with WER > 20%).
- **RTFx** = `audio_seconds / wall_seconds` (higher = faster). M4 Pro-specific;
  batch numbers include one-time model load/compile.
- **Hardware:** Apple **M4 Pro**, 48 GB, macOS 15. ANE via FluidAudio CoreML
  (Parakeet / Nemotron / Cohere) and WhisperKit (Whisper).

## Harness

| File | Role |
|------|------|
| `score.py` | English scorer — canonical normalizer + jiwer → per-(engine,dataset) WER, macro-avg, p90, failure-rate, RTFx. `--simple` fallback. |
| `score_multi.py` | Multilingual scorer — WER (en/EU) or CER (ko/ja/zh) with `BasicTextNormalizer`. |
| `run_macparakeet.py` | Drives `macparakeet-cli transcribe --output-dir` for integrated engines on LibriSpeech (real shipping path). |
| `run_macparakeet_fleurs.py` | Same, over a FLEURS language subset (multilingual). |
| `fa_json_to_jsonl.py` | Converts a FluidAudio CLI benchmark JSON (asr / cohere-benchmark) → the same JSONL, so non-integrated engines score through the same scorer. |
| `results/` | Committed evidence: `multilingual/` (FLEURS per-file), `*.jsonl` (first-200) + `stride200/` (sampling check), and `full/_summary_full.json` (authoritative full-set English; the 13 MB of per-file hypotheses are git-ignored — regenerate via `run_macparakeet.py` with no `--limit`). |

Setup: `python3 -m venv venv && venv/bin/pip install whisper-normalizer==0.1.12 jiwer mutagen`

## Results — English (full sets, authoritative)

LibriSpeech `test-clean` (2620) + `test-other` (2939), one canonical normalizer.
Ordered by macro WER. RTFx is M4 Pro batch throughput (incl. model load).

| Engine | Runtime | macro WER | test-clean | test-other | RTFx | Size | License |
|--------|---------|----------:|-----------:|-----------:|-----:|-----:|---------|
| **cohere-transcribe-03-2026** (q8) | FluidAudio CoreML | **2.07%** | 1.49 | **2.65** | ~12× | 2.3 GB | Apache-2.0 |
| **parakeet-unified** (EN) | FluidAudio CoreML | 2.38% | 1.64 | 3.13 | ~73× | ~565 MB | CC-BY-4.0 |
| parakeet-v2 (EN) | FluidAudio CoreML | 2.57% | 1.86 | 3.27 | ~73× | ~465 MB | CC-BY-4.0 |
| whisper-large-v3-turbo | WhisperKit | 3.00% | 1.96 | 4.04 | ~12× | 632 MB | MIT |
| parakeet-v3 (default, multiling.) | FluidAudio CoreML | 3.22% | 2.31 | 4.14 | ~71× | ~465 MB | CC-BY-4.0 |
| nemotron-en (Beta) | FluidAudio CoreML | 3.70% | 2.40 | 5.01 | ~50× | ~600 MB | CC-BY-4.0 |
| nemotron-multi (Beta) | FluidAudio CoreML | 5.17% | 3.17 | 7.16 | ~52× | ~1.5 GB | CC-BY-4.0 |

Cohere also pays a one-time ~74s ANE compile per process (warm RTFx ~10–15×).
Its `test-other` leg ran under CPU/ANE contention from concurrent jobs, so its
RTFx is cited from the uncontended `test-clean` leg.

## Results — Multilingual (FLEURS, 150 utts/lang)

English = WER; ko/ja/zh = CER. Same first-150 utterances per language for every engine.

| Engine | en (WER) | ko (CER) | ja (CER) | zh (CER) | Runtime |
|--------|---------:|---------:|---------:|---------:|---------|
| **cohere-transcribe-03-2026** | 4.69 | 7.15 | **5.56** | 12.49 | FluidAudio CoreML |
| whisper-large-v3-turbo | 5.71 | **6.37** | 13.42 | **11.56** | WhisperKit |
| nemotron-multi (Beta) | 7.08 | 9.32 | 15.29 | 19.47 | FluidAudio CoreML |
| parakeet-v3 (default) | **4.40** | 171.2 | 159.2 | 124.1 | FluidAudio CoreML |
| SenseVoice-Small* | ~3.2 (WER) | — | — | ~3.1 | FluidAudio CoreML |

\* SenseVoice numbers are **FluidAudio-published** (different harness/normalizer),
not reproduced here — its `sensevoice-benchmark` logs only to Apple `os_log`,
which isn't capturable via stdout. Listed for context only; not apples-to-apples.

## Findings

**English**
- **Cohere is the accuracy leader on-device** (2.07% macro), strongest on noisy
  `test-other` (2.65% vs 3.1–4.0% for the next tier). It runs on the **same
  FluidAudio CoreML SDK MacParakeet already ships** (q8, ANE) → *no new runtime
  to integrate it*. Cost: ~6× slower than Parakeet, +74s one-time compile, 2.3 GB.
  → *Parakeet for fast dictation; Cohere as an opt-in accuracy / noisy-audio engine.*
- **Unified edges v2** on the full set (2.38 vs 2.57); both beat Whisper and
  **both Nemotron builds** — settling issue #520's open "better than Nemotron"
  question (and Parakeet is far faster than either Nemotron or Whisper).
- The owner's "Cohere is incredible" tip was correct — a March-2026 release,
  Apache-2.0, #1 on the Open ASR Leaderboard.

**Multilingual** (the Korea→WhisperKit gap)
- **Parakeet-v3, the default, cannot do CJK/Korean at all** (CER > 100% = garbage;
  it's English/European-only). This is *why* a multilingual engine is required.
- **Cohere vs Whisper is a real contest:** Cohere crushes Japanese (5.6 vs 13.4
  CER) and wins English; Whisper edges Korean (6.4 vs 7.2) and Chinese (11.6 vs
  12.5). Cohere is a credible, often-better multilingual engine — not a sweep.
- Nemotron-multilingual is the weakest real multilingual option.

## Status & limitations

- **English: full sets, final-grade.** Multilingual: **capped** FLEURS (150/lang)
  first pass — fine for ranking, expand for publishable absolutes.
- **Sampling matters** (validated): a capped LibriSpeech subset shifts macro WER
  by up to ~1.5pt vs the full set and can reorder mid-pack engines. `results/`
  keeps the first-200 + `stride200/` evidence that motivated the full run.
- **Not benchmarked here:** SenseVoice/Paraformer reproduced locally (os_log
  capture gap), Qwen3-ASR & Moonshine (need an MLX runtime — deferred by owner).
  See `plans/active/asr-benchmark-and-model-expansion.md`.
- RTFx is M4 Pro-specific and batch-amortized; a warmup + median-of-N + peak-RSS
  micro-benchmark is the follow-up for headline speed claims.
