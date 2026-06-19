# MacParakeet ASR Benchmark

A reusable, **apples-to-apples** benchmark for comparing on-device ASR engines
on accuracy and speed. Every engine's hypotheses are scored through **one
canonical normalizer** (Whisper `EnglishTextNormalizer`, the HF Open ASR
Leaderboard standard) so cross-engine WER is directly comparable — the single
most important property a multi-model benchmark must have.

> This supersedes the LibriSpeech-test-clean-only `benchmarks/parakeet-unified/`
> evidence (kept for history). The numbers here are **capped first-pass**
> subsets; see "Status & limitations" for the full-set plan.

## Methodology (what the pros do)

Modeled on the HuggingFace **Open ASR Leaderboard** (arXiv 2510.06961), `jiwer`,
`whisper-normalizer`, and the WhisperKit/Soniqo Apple-Silicon harnesses:

- **Datasets (multi-domain, never a single set):** LibriSpeech `test-clean`
  (clean read speech — a near-saturated *ceiling*) **+ `test-other`** (noisier;
  exposes models tuned only on clean audio). Roadmap: a spontaneous/meeting set
  (AMI/GigaSpeech) and an accented set (VoxPopuli/CORAAL), plus FLEURS/CommonVoice
  for multilingual (KO/JA/ZH).
- **Normalizer:** Whisper `EnglishTextNormalizer` (`whisper-normalizer==0.1.12`),
  applied identically to reference and hypothesis for **every** engine
  (lowercase, strip punctuation, expand contractions, fold number words, British→
  American spelling). A `--simple` dependency-free normalizer is kept as a
  fallback; it reads ~0.16pt higher (see below).
- **WER** = `(S+D+I)/N` via Levenshtein over whitespace tokens *after*
  normalization (`jiwer`/RapidFuzz, so it scales to long-form). We report
  **corpus WER** per dataset, **macro-average** across datasets (each dataset
  weighted equally), plus the **per-utterance distribution** (p90, failure-rate
  = share of utterances with WER > 20%).
- **RTFx** = `audio_seconds / wall_seconds` (higher = faster). Measured on this
  machine; hardware-specific — never compare across machines. Batch numbers
  include one-time model load/compile.
- **Hardware:** Apple **M4 Pro**, 48 GB, macOS 15. ANE compute via FluidAudio
  CoreML (Parakeet/Nemotron/Cohere) and WhisperKit (Whisper).

## Harness

| File | Role |
|------|------|
| `score.py` | Canonical scorer. Consumes `{id,ref,hyp,dataset,engine,audio_s?,proc_s?}` JSONL → per-(engine,dataset) WER, macro-avg, p90, failure-rate, RTFx. `--simple` for the dependency-free normalizer. |
| `run_macparakeet.py` | Drives `macparakeet-cli transcribe --output-dir` for the *integrated* engines (real shipping path, uniform text output) → JSONL. |
| `fa_json_to_jsonl.py` | Converts a FluidAudio CLI benchmark results JSON (asr/ja/cohere-benchmark) → the same JSONL, so non-integrated engines score through the same scorer. |
| `results/*.jsonl` | Per-(engine,dataset) hypotheses + ground truth (committed evidence). |

Setup: `python3 -m venv venv && venv/bin/pip install whisper-normalizer==0.1.12 jiwer mutagen`

```bash
# integrated engine (e.g. unified) on test-clean, first 200 files
run_macparakeet.py --cli .build/release/macparakeet-cli \
  --dataset-dir ~/asr-bench/LibriSpeech/test-clean --dataset-name test-clean \
  --engine parakeet-unified --limit 200 --selection first \
  --records results/parakeet-unified__test-clean.jsonl
# score everything through the canonical normalizer
score.py results/*.jsonl
```

## Results — capped first pass (200 files/dataset, lexicographic-first)

All engines (and Cohere) scored on the **identical** first-200 files of each
subset, one normalizer. RTFx is M4 Pro batch throughput (incl. model load).
Committed evidence: `results/*.jsonl` (first-200, all engines incl. Cohere) and
`results/stride200/*.jsonl` (a stride sample of the 6 integrated engines, for
the sensitivity check below).

Ordered by macro WER (best first). RTFx is batch incl. model load; Cohere also
pays a one-time ~74s ANE compile per process (warm RTFx ~15×/10×).

| Engine | Runtime | macro WER | test-clean | test-other | RTFx (clean/other) | Size | License |
|--------|---------|----------:|-----------:|-----------:|-------------------:|-----:|---------|
| **cohere-transcribe-03-2026** (q8) | FluidAudio CoreML | **2.39%** | 1.58 | **3.19** | 9× / 6× | 2.3 GB | Apache-2.0 |
| **parakeet-unified** (EN) | FluidAudio CoreML | 2.65% | **1.50** | 3.81 | 81× / 65× | ~565 MB | CC-BY-4.0 |
| **parakeet-v2** (EN) | FluidAudio CoreML | 3.10% | 1.99 | 4.20 | 84× / 60× | ~465 MB | CC-BY-4.0 |
| whisper-large-v3-turbo | WhisperKit | 3.16% | 1.50 | 4.82 | 14× / 10× | 632 MB | MIT |
| nemotron-en (Beta) | FluidAudio CoreML | 3.52% | 1.82 | 5.21 | 50× / 48× | ~600 MB | CC-BY-4.0 |
| parakeet-v3 (default, multiling.) | FluidAudio CoreML | 3.95% | 3.34 | 4.56 | 81× / 61× | ~465 MB | CC-BY-4.0 |
| nemotron-multi (Beta) | FluidAudio CoreML | 5.14% | 2.57 | 7.72 | 59× / 48× | ~1.5 GB | CC-BY-4.0 |

## Sampling sensitivity (why these are preliminary)

The same engines on a **stride-200** sample (every ~13th file, more
representative) give materially different macro-WER — and even reorder the top:

| Engine | first-200 macro | stride-200 macro |
|--------|----------------:|-----------------:|
| parakeet-unified | 2.65% | 2.33% |
| parakeet-v2 | 3.10% | 2.32% |
| whisper-turbo | 3.16% | 2.81% |
| parakeet-v3 | 3.95% | 3.14% |
| nemotron-en | 3.52% | 3.71% |
| nemotron-multi | 5.14% | 5.36% |

first-200 (the first 2–3 speakers) is noisier and harder on `test-other`; on
stride-200 Unified and v2 are tied. **Lesson: capped subsets shift WER by up to
~1.5pt and can flip rankings — only the full set gives final-grade numbers.**
Cohere can only be run on FluidAudio's lexicographic-first selection, so the
first-200 table is the comparable one; treat absolutes as indicative.

## Findings

- **Cohere is the accuracy leader on-device** (2.39% macro), and its edge is
  **noise robustness** — on `test-other` it scores 3.19% vs 3.8–4.8% for the
  next tier and has the best tail (p90 12.5, failure 5.5%). It runs on the
  **same FluidAudio CoreML SDK MacParakeet already ships** (q8, ANE), so adding
  it needs *no new runtime*. Cost: ~9× slower than Parakeet (≈10–15× RTFx warm),
  a one-time ~74s compile, and 2.3 GB. → *Parakeet for fast dictation; Cohere
  for accuracy-critical / noisy audio.* (The owner's "Cohere is incredible" tip
  was correct — it's a March-2026 release, #1 on the Open ASR Leaderboard.)
- **Unified vs v2:** a wash overall, not a clear win. Unified leads on clean
  read speech; v2 is competitive on noisy. (The test-clean-only benchmark
  overstated Unified's edge — exactly the single-dataset trap.)
- **Issue #520's open question is settled:** Unified/v2 beat *both* Nemotron
  builds on English **and** run faster. Nemotron-multilingual is weakest on
  English (expected; it's a multilingual streaming Beta).
- **Whisper-large-v3-turbo** is accuracy-competitive but ~5–6× slower than
  Parakeet on the ANE.
- **Normalizer matters:** the hand-rolled scorer reads ~0.16pt higher than the
  canonical one (it skips contraction/number/spelling folding).

## Status & limitations

- **Capped first pass.** 200 files/dataset. For publishable/final numbers, run
  the **full** `test-clean` (2620) + `test-other` (2939) — removes sampling
  bias and makes every engine (incl. Cohere) directly comparable.
- **English-only so far.** Multilingual (FLEURS/CommonVoice KO/JA/ZH) is the
  next axis — that's where SenseVoice, Qwen3-ASR, Cohere, and v3/Whisper matter.
- **Not yet benchmarked:** SenseVoice-Small / Paraformer (FluidAudio, auto-
  download), Qwen3-ASR & Moonshine (MLX). See the plan in
  `plans/active/asr-benchmark-and-model-expansion.md`.
- RTFx is M4 Pro-specific and batch-amortized; a warmup + median-of-N + peak-RSS
  micro-benchmark is the follow-up for headline speed claims.
