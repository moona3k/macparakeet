# MacParakeet ASR Benchmark

A reusable, **apples-to-apples** benchmark for choosing on-device ASR engines on
Apple Silicon. Every engine's hypotheses are scored through **one canonical
normalizer** (Whisper `EnglishTextNormalizer` / `BasicTextNormalizer`, the HF
Open ASR Leaderboard standard), so cross-engine numbers are directly comparable —
the single most important property a multi-model benchmark must have. It measures
three axes: **accuracy** (English + multilingual), **speed**, and **memory**.

Engines are the four families MacParakeet ships or is evaluating: **Parakeet**
(v2 / v3 / unified), **Nemotron** (English / multilingual, Beta), **WhisperKit**
(large-v3-turbo), and **Cohere** Transcribe (`cohere-transcribe-03-2026`, q8) —
the model flagged after #520 / #552 / #554 and confirmed runnable on-device via
the FluidAudio CoreML SDK MacParakeet already ships.

> Supersedes the LibriSpeech-`test-clean`-only `benchmarks/parakeet-unified/`
> evidence. English numbers below are the **full** test sets; multilingual is a
> capped FLEURS pass (see "Status & limitations").

## TL;DR (what the evidence says)

- **Cohere is the most accurate on-device engine** — but at a steep cost: it
  needs **~11 GB of RAM** at runtime (vs ~120 MB for Parakeet), a one-time **~73 s**
  ANE compile, and runs **~11× realtime** (vs ~70× for Parakeet). Its accuracy
  lead is *statistically real* only on noisy English (`test-other`) and Japanese;
  on clean English, Korean, and Chinese it ties the best alternative within 95%
  CIs. → **Add Cohere as an opt-in accuracy / noisy-audio / Japanese engine for
  16 GB+ Macs, not a default.**
- **Parakeet stays the right default** for fast dictation (best speed, ~120 MB
  RAM, English WER within noise of Cohere on clean speech). **Unified slightly
  beats v2** on clean speech (paired Δ −0.22 pt, CI [−0.34, −0.11]) and ties on
  noisy; it also adds punctuation/capitalization — so unified is the better
  English Parakeet build on both counts, modestly.
- **Parakeet-v3 (the multilingual default) cannot transcribe CJK/Korean at all**
  (CER > 100% — it romanizes into gibberish). A multilingual engine is required
  there; today that's WhisperKit (light, competitive on Korean/Chinese), with
  Cohere the premium option for Japanese.
- **Both Nemotron builds are dominated** — worse English WER than Parakeet, worse
  multilingual than Whisper/Cohere, no word timestamps. The "Beta" label is
  warranted; nothing here argues for promoting them.

## Methodology

Modeled on the HuggingFace **Open ASR Leaderboard** (arXiv 2510.06961), using
`jiwer` and `whisper-normalizer`, plus the WhisperKit/FluidAudio Apple-Silicon
harness conventions.

- **Datasets.** English — LibriSpeech `test-clean` (clean read speech, a near-
  saturated *ceiling*) + `test-other` (noisier; exposes clean-only tuning), full
  sets (2620 + 2939 utterances; 53,029 + 52,884 reference words). Multilingual —
  **FLEURS** en/ko/ja/zh, 150 utterances/language (`FluidInference/fleurs-full`).
- **Normalizer.** Whisper `EnglishTextNormalizer` for English (lowercase, strip
  punctuation, expand contractions, fold number words, British→American),
  `BasicTextNormalizer` for other languages — applied identically to reference
  and hypothesis for **every** engine. A `--simple` fallback reads ~0.16 pt
  higher. Curly apostrophes are folded to straight first (without this, the
  normalizer mis-splits contractions and inflates WER — see `test_scorers.py`).
- **Metric.** **WER** = `(S+D+I)/N` for space-delimited languages (en, EU);
  **CER** (character error rate) for **ko/ja/zh**, where word boundaries are
  unreliable (Korean spacing is inconsistent → CER is the conventional, spacing-
  robust choice; word-WER there is dominated by segmentation noise). We report
  **corpus** error per dataset, **macro-average** across datasets (equal-weight
  mean of the two corpus WERs — note this gives the noisy `test-other`, where
  Cohere's lead concentrates, the same weight as the near-saturated `test-clean`;
  for clean-dictation use, read `test-clean` directly), the per-utt **p90** /
  failure-rate (WER > 20%), and a **bootstrap 95% CI** (resampling whole
  utterances; 2000 resamples, seed 1234).
  - *CJK caveat:* `BasicTextNormalizer` lowercases and strips punctuation but
    does **not** fold numerals, units, or script (Hangul vs Latin), and ~23% of
    the Korean references contain digits that engines render divergently. So the
    CJK/Korean CER is **ranking-grade, not fully formatting-equalized** across
    engines — read small multilingual gaps as ties, not the precise apples-to-
    apples comparison the English numbers are.
- **Significance.** Because every engine transcribes the *same* utterances (so
  their errors are correlated), we judge "is A better than B" with a **paired**
  bootstrap on the per-utterance delta (`paired_delta.py`) — a difference is
  significant only if its paired CI excludes 0. The per-engine marginal CIs in
  the tables are descriptive; their *overlap* is **not** used to call
  significance (overlap is over-conservative and under-detects real gaps).
- **Speed/memory** (separate micro-benchmark, one engine at a time, uncontended):
  **cold start** = wall to first transcript from a cold process (model load + ANE
  compile); **steady RTFx** = audio_s/wall with the one-time load removed;
  **peak RSS** = `/usr/bin/time -l` maximum resident set size of the isolated
  child. RTFx is throughput (audio_seconds / wall_seconds; higher = faster).
- **Hardware.** Apple **M4 Pro**, 48 GB, macOS 15. ANE via FluidAudio CoreML
  (Parakeet / Nemotron / Cohere) and WhisperKit (Whisper).

## Harness

| File | Role |
|------|------|
| `score.py` | English scorer — canonical normalizer + jiwer → corpus WER, macro-avg, p90, failure-rate, RTFx. `--ci N` adds a bootstrap 95% CI; `--simple` fallback. |
| `score_multi.py` | Multilingual scorer — WER (en/EU) or CER (ko/ja/zh) via `BasicTextNormalizer`; `--ci N`. |
| `paired_delta.py` | Paired bootstrap CI on the WER/CER *difference* between two engines (the significance test). |
| `speed_bench.py` | Speed/memory — steady RTFx, cold-start, peak RSS, one engine at a time. |
| `test_scorers.py` | Scorer correctness tests (run: `python3 test_scorers.py`). |
| `run_macparakeet.py` | Drives `macparakeet-cli transcribe` for integrated engines on LibriSpeech (the real shipping path). |
| `run_macparakeet_fleurs.py` | Same, over a FLEURS language subset (multilingual). |
| `fa_json_to_jsonl.py` | Converts a FluidAudio CLI benchmark JSON → the same JSONL, so non-integrated engines (Cohere) score through the same scorer. |
| `run_all.sh` | Driver: `verify` (repo-only: tests + re-score committed evidence with CIs), `speed`, `transcribe`. |
| `requirements.txt` | Pinned scorer dependencies. |
| `results/` | Committed evidence (see "Verification & reproducibility"). |

Setup: `python3 -m venv venv && venv/bin/pip install -r requirements.txt`

## Results — English (full sets, authoritative)

LibriSpeech `test-clean` (2620) + `test-other` (2939), one canonical normalizer,
ordered by macro WER. Brackets are the bootstrap 95% CI on that dataset's corpus
WER. RTFx here is full-set *batch* throughput (model load amortized over
thousands of files); see the speed table for steady-state and cold-start.

| Engine | Runtime | macro WER | test-clean (95% CI) | test-other (95% CI) | batch RTFx | Bundle | License |
|--------|---------|----------:|--------------------:|--------------------:|-----------:|-------:|---------|
| **cohere-transcribe-03-2026** (q8) | FluidAudio CoreML | **2.07%** | 1.49 [1.28–1.73] | **2.65 [2.40–2.92]** | ~12×† | 2.3 GB | Apache-2.0 |
| **parakeet-unified** (EN) | FluidAudio CoreML | 2.38% | 1.64 [1.50–1.80] | 3.13 [2.92–3.34] | ~73× | ~565 MB | CC-BY-4.0 |
| parakeet-v2 (EN) | FluidAudio CoreML | 2.57% | 1.86 [1.70–2.04] | 3.27 [3.06–3.49] | ~73× | ~465 MB | CC-BY-4.0 |
| whisper-large-v3-turbo | WhisperKit | 3.00% | 1.96 [1.81–2.12] | 4.04 [3.81–4.29] | ~12× | 632 MB | MIT |
| parakeet-v3 (default, multiling.) | FluidAudio CoreML | 3.22% | 2.31 [2.11–2.54] | 4.14 [3.86–4.40] | ~71× | ~465 MB | CC-BY-4.0 |
| nemotron-en (Beta) | FluidAudio CoreML | 3.70% | 2.40 [2.22–2.58] | 5.01 [4.74–5.29] | ~50× | ~600 MB | CC-BY-4.0 |
| nemotron-multi (Beta) | FluidAudio CoreML | 5.17% | 3.17 [2.98–3.37] | 7.16 [6.81–7.51] | ~52× | ~1.5 GB | CC-BY-4.0 |

† Cohere's full-set `test-other` batch RTFx was contention-poisoned (0.5×); ~12×
is its clean `test-clean` batch corpus throughput, and steady-state is ~11× (see
speed table). All other cells are genuine full-set batch RTFx.

**Significance (paired bootstrap, not CI overlap).**
- Cohere vs parakeet-unified: a *real* win on noisy `test-other` (paired Δ −0.47 pt,
  CI [−0.70, −0.23]); a **tie** on clean `test-clean` (Δ −0.15 [−0.32, +0.04]).
- parakeet-unified vs parakeet-v2: a small but *significant* win for unified on
  `test-clean` (Δ −0.22 [−0.34, −0.11]); a **tie** on `test-other` (Δ −0.14
  [−0.28, +0.00]). (Marginal-CI overlap would have mislabelled the clean case a
  tie — hence the paired test.)

## Results — Multilingual (FLEURS, 150 utts/lang)

English = WER; ko/ja/zh = CER. Same first-150 utterances/language for every
engine. Brackets are the bootstrap 95% CI.

| Engine | en (WER) | ko (CER) | ja (CER) | zh (CER) | Runtime |
|--------|---------:|---------:|---------:|---------:|---------|
| **cohere-transcribe-03-2026** | 4.69 [3.71–5.69] | 7.15 [5.43–9.15] | **5.56 [4.14–7.10]** | 12.49 [9.79–15.26] | FluidAudio CoreML |
| whisper-large-v3-turbo | 5.71 [4.83–6.70] | **6.37 [4.81–8.09]** | 13.42 [11.33–15.59] | **11.56 [9.32–13.96]** | WhisperKit |
| nemotron-multi (Beta) | 7.08 [6.11–8.14] | 9.32 [7.64–11.17] | 15.29 [13.68–16.98] | 19.47 [16.62–22.30] | FluidAudio CoreML |
| parakeet-v3 (default) | **4.40 [3.59–5.27]** | 171.2 ❌ | 159.2 ❌ | 124.1 ❌ | FluidAudio CoreML |

**Paired bootstrap (cohere − whisper):** Japanese Δ −7.85 CER [−10.16, −5.70] —
a real, large win for Cohere; Korean (Δ +0.78 [−0.30, +1.95]) and Chinese
(Δ +0.93 [−0.79, +2.69]) are ties; English vs parakeet-v3 is a tie (Δ +0.29
[−0.61, +1.22]). parakeet-v3 is unusable on CJK/Korean. These are **n=150
single-language slices** — directional, not publishable absolutes (and CJK CER is
ranking-grade, not numeral/script-equalized; see the metric caveat). Validate on
a larger set before shipping per-language engine routing.

## Results — Speed & Memory (M4 Pro, uncontended)

| Engine | cold start | steady RTFx | peak RSS |
|--------|-----------:|------------:|---------:|
| parakeet-v2 | 0.55 s | ~90× | 123 MB |
| parakeet-v3 | 0.38 s | ~81× | 131 MB |
| parakeet-unified | 0.93 s | ~93× | 115 MB |
| nemotron-en | 0.87 s | ~57× | 141 MB |
| nemotron-multi | 0.70 s | ~61× | 142 MB |
| whisper-large-v3-turbo | 2.29 s | ~14× | 274 MB |
| **cohere-transcribe-03-2026** | **73 s** | **~11×** | **~11.6 GB** |

**Method note:** Cohere is measured via the FluidAudio CLI (the same SDK
MacParakeet would integrate); the other six via `macparakeet-cli`. So Cohere's
figures are a *reference-harness* proxy, not yet an in-app measurement — treat the
RAM floor as a lower bound.

The Cohere peak RSS is **constant at 2 / 8 / 12 files** → it's the model's
resident working set, not harness accumulation (an autoregressive 2B transformer
in CoreML). At ~11 GB it is the decisive practical caveat: Cohere is realistically
**16 GB+ only** (comfortable at 24 GB+), where Parakeet/Whisper fit on any
supported Mac. RTFx is clip-length-sensitive — Cohere is ~11× on ~8 s LibriSpeech
utterances and ~16× on shorter FLEURS-en; the ~70×-vs-~11× gap to Parakeet is not
constant across clip lengths (relevant since dictation is short-clip). Cohere's
cold start is dominated by the one-time ANE compile.

## Findings & recommendation

**Accuracy.** Cohere is the on-device accuracy leader, but the win is narrow and
domain-specific once CIs are honored: clearly best on noisy English and Japanese,
a statistical tie elsewhere. The owner's "Cohere is incredible" tip holds — a
March-2026 release, Apache-2.0, #1 on the Open ASR Leaderboard — but the on-device
*cost* reframes it from "obvious default" to "premium opt-in."

**Issue #520 settled.** Parakeet unified/v2 beat *both* Nemotron builds on English
and are far faster. Unified vs v2: a small but statistically significant win for
unified on clean speech (paired Δ −0.22 pt) and a tie on noisy — plus unified adds
punctuation/capitalization. So unified is the better English Parakeet build.

**Recommendation (evidence-based):**
1. Keep **Parakeet** the default (speed + memory + clean-English parity).
2. Add **Cohere** as an **opt-in** engine surfaced for noisy audio, Japanese, and
   accuracy-critical work, gated to **16 GB+ RAM** (reference-harness ~11 GB;
   confirm the in-app figure before shipping) with a clear cold-start/size
   warning. Reuses the existing FluidAudio SDK — no new runtime.
3. Keep **WhisperKit** as the pragmatic multilingual engine (light, competitive
   Korean/Chinese); it remains the better default for CJK on memory grounds.
   Per-language routing (Japanese→Cohere) is provisional on n=150 — validate on a
   larger multilingual set first.
4. No action on **Nemotron** — dominated; Beta status is justified.

## Verification & reproducibility

- **Scorer/CI determinism.** `./run_all.sh verify` (repo-only, no datasets or
  models) runs the scorer tests and re-scores the committed (frozen) hypotheses
  with CIs, reproducing the headline macro WER (2.07 / 2.38 / 2.57 / 3.00 / 3.22 /
  3.70 / 5.17). This proves the *scorer* is deterministic — it re-scores fixed
  text, it does not re-transcribe.
- **Spot pipeline reproduction.** Separately, re-transcribing through a clean
  `macparakeet-cli` and scoring on *identical utterance IDs* gives **Δ = 0.00 pt**
  vs the committed data on a stride-60 `test-clean` subset (six integrated
  engines) and first-40 LibriSpeech (Cohere) — a spot check that the committed
  hypotheses are faithful, not a full-set re-transcription.
- The 13 MB of full per-file English hypotheses are git-ignored but backed up
  compressed at `results/full/full_hypotheses.tar.gz` (4 MB) and auto-extracted by
  the driver. FLEURS per-language utterance-ID sets were verified identical across
  engines (not just assumed).
- **Committed evidence:** `results/full/_summary_full.json` (authoritative
  English + CIs), `results/multilingual/` (FLEURS per-file + summary + CIs),
  `results/speed/` (raw + curated speed/memory), `results/{*.jsonl, stride200/}`
  (first-200 + sampling-sensitivity check).
- **Determinism:** the scorers are deterministic; the bootstrap uses a fixed seed
  (1234). Same inputs → same numbers.

**Provenance.** macparakeet-cli **2.9.0**; FluidAudio **v0.15.4**; CPython
**3.14.5** with pinned deps; LibriSpeech test-clean/test-other (OpenSLR SLR12);
FLEURS via `FluidInference/fleurs-full` (HF); Cohere model
`FluidInference/cohere-transcribe-03-2026-coreml` (q8); Apple M4 Pro / 48 GB /
macOS 15.

## Status & limitations

- **English: full sets, final-grade.** Multilingual: **capped** FLEURS (150/lang),
  fine for ranking; expand for publishable absolutes.
- **Sampling matters** (validated): a capped LibriSpeech subset shifts macro WER
  by up to ~1.5 pt vs the full set and can reorder mid-pack engines — hence the
  full-set English run. `results/{*.jsonl, stride200/}` keep the first-200 +
  stride-200 evidence that motivated it.
- **Cohere speed/memory** is measured via the FluidAudio CLI (the same SDK
  MacParakeet would integrate), not yet through MacParakeet's own runtime (Cohere
  isn't an integrated engine) — treat the figures as a lower bound and confirm
  in-app before shipping.
- **Not benchmarked:** Qwen3-ASR and Moonshine (need an MLX runtime — deferred).
  Integrating any winner (e.g. Cohere as an opt-in FluidAudio engine) is a
  separate ADR-gated change.
