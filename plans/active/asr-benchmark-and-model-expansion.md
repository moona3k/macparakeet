# Plan: Gold-Standard ASR Benchmark + Model Expansion

> Status: **ACTIVE** (proposal pending owner steer on Phase 3 scope)
> Branch: `asr/benchmark-model-expansion`
> Author: AI agent session, 2026-06-18
> Supersedes the ad-hoc `benchmarks/parakeet-unified/` harness with a
> reusable, methodologically-defensible cross-model benchmark, and proposes
> which new on-device ASR engines to evaluate and (conditionally) ship.

> **Update 2026-06-18 (capped pass run).** Phase 1 + the Cohere slice of Phase 2
> are done — see `benchmarks/asr/`. Two results that change the plan:
> 1. **Cohere is FluidAudio-native, not MLX.** This FluidAudio build ships
>    `cohere-transcribe`/`cohere-benchmark` and a q8 CoreML repo
>    (`FluidInference/cohere-transcribe-03-2026-coreml`). Cohere runs on-device
>    via the **same FluidAudio SDK MacParakeet already uses** — so it (and
>    SenseVoice/Paraformer, which auto-download) need **no MLX runtime**. MLX is
>    now only required for Qwen3-ASR and Moonshine.
> 2. **Measured (M4 Pro, first-200, canonical normalizer): Cohere is the
>    accuracy leader** (2.39% macro vs Parakeet-unified 2.65%), driven by noise
>    robustness on test-other, but ~9× slower than Parakeet (≈10–15× RTFx warm,
>    +74s one-time compile, 2.3 GB). Verdict: *Parakeet for fast dictation,
>    Cohere as an opt-in accuracy/noisy-audio engine.*
> **Update 2026-06-19 (full-set + multilingual done).** English finalized on the
> FULL test-clean+test-other: Cohere 2.07% macro / unified 2.38 / v2 2.57 /
> whisper 3.00 / v3 3.22 / nemotron-en 3.70 / nemotron-multi 5.17. Multilingual
> FLEURS (en WER, ko/ja/zh CER): Cohere en 4.69 / ko 7.15 / ja 5.56 / zh 12.49;
> Whisper 5.71 / 6.37 / 13.42 / 11.56; **Parakeet-v3 fails CJK (>100% CER)** —
> confirming the default can't serve KO/JA/ZH. Cohere ≈/> Whisper multilingually
> (crushes Japanese, ties KO/ZH). Cohere is the strongest single on-device engine
> on accuracy in both English and multilingual, via the existing FluidAudio SDK.
> Remaining: SenseVoice/Paraformer reproduced locally (os_log capture gap; cited
> from FluidAudio's published numbers for now), Qwen3-ASR & Moonshine (MLX, deferred).

> **Outcome & decision 2026-06-19 (benchmark complete).** The harness is hardened
> and independently verified in **PR #568** (bootstrap + paired-delta CIs, scorer
> tests, speed/memory micro-benchmark, pinned-version reproducibility, committed
> evidence). Decision recorded in **ADR-001 (2026-06-19 amendment + Cohere
> addendum)**: **Cohere is the recommended next engine — an opt-in Beta gated to
> ≥16 GB RAM — and it is FluidAudio CoreML, NOT MLX** (public `CoherePipeline` in
> FluidAudio ≥ 0.15.4; no new runtime). The MLX runtime path (Phase 3) is
> therefore needed only for Qwen3-ASR / Moonshine, which stay deferred. The
> stale Tier-3 / Phase-3 text below that filed Cohere under the MLX path is
> corrected inline.

## North Star tie-in

MacParakeet is "a fast, local-first voice app for Mac." Every model decision
is gated by one hard constraint: **it must run on-device on Apple Silicon**
(CoreML/ANE via FluidAudio, WhisperKit, MLX, or whisper.cpp). Accuracy and
speed only matter for models that clear that gate. The benchmark exists to pick
the best engines we can actually ship, and to back our public accuracy/speed
claims with reproducible numbers.

## Context zone

**In scope**
- A reusable benchmark harness that scores any engine reachable through
  `macparakeet-cli` (and, for not-yet-integrated models, standalone runners)
  on a multi-domain dataset suite, with the canonical Whisper/jiwer normalizer
  and a defensible on-device speed protocol.
- A full accuracy + speed + memory comparison of the best on-device ASR models,
  including candidates we do not yet ship (SenseVoice, Qwen3-ASR, Moonshine,
  Kyutai, Cohere Transcribe, Canary).
- Recommendations on which engines to integrate and in what order.

**Out of scope (this plan)**
- Shipping any new engine to users. Integration of a winner is a follow-up that
  needs its own ADR (esp. a new MLX runtime path — see Phase 3).
- Changing the default engine (Parakeet v3 stays the multilingual default).
- Cloud ASR. Disqualified for the local-first default; tracked only as a
  reference ceiling.

**Invariants (must not change)**
- ADR-016 process-wide STT scheduler/runtime ownership; ADR-021 engine routing.
- The benchmark must never contaminate hypotheses with diagnostics — keep the
  `transcribe --output-dir` (file-output) approach, not stdout scraping.
- GPL-3.0 compatibility of anything we ship (license is a first-class filter).
- No silent truncation/sampling: every subset/cap is logged in results.

## Background: review of the existing work (done this session)

PR #552 (offline Unified) and PR #554 (native streaming) are **merged and
sound**. A focused Swift review of #554 found no P0/P1 issues — it is a faithful
parity extension of the Nemotron streaming pattern (uniform `STTError` mapping,
cleanup-on-failure across all three managers, cooperative cancellation, correct
live-preview-vs-authoritative-paste separation). Two P2 follow-ups only:
1. `processLiveDictationSamples` splits append+process into two engine-actor
   awaits (Nemotron uses one call). Verified benign; wants a one-line comment.
2. No deterministic test drives a fake streaming session (cross-session reset,
   mid-stream cancel). Stale-token safety currently rests on reading FluidAudio's
   `reset()`, not on a MacParakeet test. Suggest a stub streaming-manager seam.

The `benchmarks/parakeet-unified/` harness is **mechanically correct and
honestly documented**, but is a merge-readiness artifact, not a
publishable cross-model benchmark. Gaps (all confirmed against the HF Open ASR
Leaderboard methodology, arXiv 2510.06961):
- **Single dataset.** LibriSpeech test-clean only. Near-saturated (<2% WER for
  good models); overstates real-world accuracy and barely separates models. The
  README's 2.15% Unified figure is test-clean-only; the same model is ~6.3% on
  the leaderboard's 8-dataset macro-average. Different question entirely.
- **Non-canonical normalizer.** Hand-rolled (lowercase, strip punct, keep
  apostrophes). Misses number-word folding, contraction expansion, and
  British→American spelling. Re-scoring the committed hypotheses under the
  canonical Whisper `EnglishTextNormalizer` this session:

  | 300-file stride | hand-rolled | canonical | Δ |
  |---|---|---|---|
  | Parakeet Unified | 1.93% | 1.76% | −0.17 |
  | Parakeet v2 | 2.41% | 2.25% | −0.16 |

  The hand-rolled scorer over-penalizes by ~0.16pt; the ranking is unchanged.
- **Non-rigorous speed.** Single wall-clock run, no warmup, no median-of-N, no
  peak-RSS, RTFx not computed. Indicative, not defensible.
- **Mixed-normalizer cross-engine rows.** The Nemotron row is scored with a
  different normalizer than the Parakeet rows, so issue #520's "better than
  Nemotron" question is still not settled on an apples-to-apples basis.

## Gold-standard methodology (target)

Per the Open ASR Leaderboard, jiwer, whisper_normalizer, WhisperKit, and Soniqo
Apple-Silicon harnesses:
- **Datasets:** multi-domain, macro-averaged (per-dataset WER, then mean), never
  a single set. Minimum credible suite: LibriSpeech test-clean **+ test-other**
  (noise robustness) **+ one spontaneous/meeting set (AMI or GigaSpeech)** **+
  one accented/non-native set (VoxPopuli or CORAAL)**. Multilingual: FLEURS /
  CommonVoice subsets for the langs we care about (KO/JA/ZH given our telemetry).
- **Normalizer:** Whisper `EnglishTextNormalizer` (English) / `BasicTextNormalizer`
  (other langs), identical on ref and hyp for every engine. Pin
  `whisper-normalizer==0.1.12` (the version NeMo model cards cite).
- **WER:** `(S+D+I)/N` via Levenshtein over whitespace tokens post-normalization,
  using `jiwer` (RapidFuzz) so it scales to long-form. Report macro-avg + per
  dataset + per-utterance distribution (mean/median/p90/failure-rate>20%).
- **Speed:** RTFx = audio_seconds / wall_seconds. Specify chip/RAM/OS/batch,
  idle thermals, median of ≥5 runs after 1 warmup, peak RSS per engine in a
  child process, short-form (<30s, dictation proxy) vs long-form reported
  separately, ANE/GPU/CPU surface noted.
- **Honesty:** label streaming vs offline (never compare WER across modes
  unqualified), pin model versions, note train/test overlap risk, log all caps.

## The candidate landscape (on-device Apple Silicon)

Tiered by integration cost, then accuracy/licensing. (WER = Open ASR
Leaderboard macro-avg unless noted; verify all numbers in Phase 2.)

**Tier 0 — already integrated (benchmark for the comparison table):**
Parakeet v3 (default, multilingual), v2 (EN), Unified (EN, new), Nemotron
multilingual + EN (Beta), WhisperKit large-v3-turbo. All reachable via
`macparakeet-cli`.

**Tier 1 — on-device today via FluidAudio CoreML, near-zero integration:**
- **SenseVoice-Small** — MIT, ~225 MB int8, already shipped in the FluidAudio
  SDK we depend on (FluidAudio reports 299x RTFx, 3.22% EN WER, 3.09% ZH CER),
  50+ langs + emotion/event tags. The cheapest meaningful add; strong ZH/JP/KO.
- Paraformer-Large — MIT, Mandarin-focused, also in FluidAudio.

**Tier 2 — on-device via a new MLX runtime path (real but bounded work):**
- **Qwen3-ASR 0.6B / 1.7B** — Apache-2.0, 52 langs incl. KO/JA/ZH + dialects,
  streaming+offline unified, MLX + Swift path exists (mlx-audio / qwen3-asr-swift).
  Strongest multilingual candidate; directly addresses the Korea→WhisperKit gap.
- **Moonshine v2 (Small/Medium)** — MIT, 123–245 MB, English, purpose-built
  ultra-low-latency streaming (107ms). Complements the #517 live-preview path.
- **Kyutai STT 2.6B** — CC-BY-4.0, English, streaming (2.5s delay), MLX weights
  + moshi-swift. Larger; watch FluidAudio for a CoreML conversion.

**Tier 3 — accuracy leaders, integration unproven on-device:**
- **Cohere Transcribe (cohere-transcribe-03-2026)** — Apache-2.0, 2B, **#1 on
  the Open ASR Leaderboard at 5.42% avg** (LibriSpeech-clean 1.25%), 14 langs
  incl. KO/JA/ZH/AR, Conformer enc + Transformer dec. **Runs on-device via
  FluidAudio CoreML** (q8 repo `FluidInference/cohere-transcribe-03-2026-coreml`,
  public `CoherePipeline` in FluidAudio ≥ 0.15.4) — **no MLX needed** (the earlier
  "MLX path exists; no CoreML yet" note was wrong). Benchmarked this session;
  recommended as an opt-in ≥16 GB add — see the 2026-06-19 outcome above and
  ADR-001.
- **Canary-1B-flash** — CC-BY-4.0, multilingual + translation; FluidInference
  (mobius) has CoreML conversion in progress. Watch the FluidAudio roadmap.

**Disqualified for the local default:** Canary-Qwen-2.5B (CUDA-only), Voxtral
Small 24B (too large), all cloud APIs (Deepgram/AssemblyAI/ElevenLabs/Speechmatics).

## Phases

### Phase 1 — Upgrade the harness to gold-standard (decision-free; start now)
1. Add a canonical-normalizer mode to the scorer (`whisper-normalizer==0.1.12`,
   curly→straight apostrophe pre-pass) and make it the default for headline
   numbers; keep the dependency-free scorer as a `--simple` fallback. Use
   `jiwer` for edit distance so long-form scales.
2. Add `test-other` (cheap, same format) and a multi-dataset runner that emits
   per-dataset + macro-avg WER and the per-utterance distribution.
3. Add the speed protocol: warmup + median-of-N, RTFx, peak-RSS-per-engine in a
   child process, short-form vs long-form split.
4. Re-run Tier 0 engines; commit a single `benchmarks/asr/README.md` results
   matrix that replaces the parakeet-unified-only framing. Settle the
   Unified-vs-Nemotron question on one normalizer.
5. Tests: a unit test that the canonical scorer reproduces a known WER on a tiny
   fixture; a load-every-dataset smoke guard.

### Phase 2 — Benchmark the candidates (produces the full comparison)
1. Tier 1: run SenseVoice/Paraformer via the FluidAudio CLI (already built at
   `~/asr-bench/FluidAudio-0154`). Near-free.
2. Tier 2/3: standalone MLX/Python runners (not integrated) for Qwen3-ASR,
   Moonshine, Kyutai, Cohere Transcribe — accuracy on the suite + on-device
   speed/RSS on this machine. Score through the same normalizer.
3. Publish the full matrix: model | langs | WER (per dataset + macro) | streaming |
   license | size | RTFx | peak RSS | on-device runtime | verdict.

### Phase 3 — Integration decisions (needs owner steer + ADRs)
- **Near-term, low-cost (FluidAudio CoreML, no new runtime):** **Cohere
  Transcribe** is the benchmark's recommended add — an opt-in Beta gated to
  ≥16 GB RAM (ADR-001, 2026-06-19). SenseVoice-Small is a second candidate
  (multilingual/ZH/JP/KO + emotion). Both mirror how Nemotron/Unified were added.
- **Strategic, ADR-scale:** an **MLX runtime path** (new ADR, mirrors ADR-021
  WhisperKit) to unlock Qwen3-ASR (multilingual flagship) and Moonshine
  (low-latency dictation) — the candidates that genuinely need MLX. This is the
  big fork — it adds a third on-device runtime family alongside FluidAudio/CoreML
  and WhisperKit. (Cohere does **not** require this fork.)
- Decide per winner: default vs opt-in, language routing, model download UX,
  Settings/CLI surfacing, telemetry.

## Open decisions for the owner
1. **Benchmark breadth:** Phase 1 only (defensible numbers on what we ship), or
   Phase 1 + Phase 2 (full landscape incl. Cohere/Qwen3)? Recommendation: both —
   the landscape is the point of the request.
2. **MLX runtime commitment:** do we take on an in-app MLX path (Phase 3
   strategic)? It's the gate for the best new multilingual + low-latency models
   but is ADR-scale. Recommendation: decide *after* Phase 2 numbers are in.
3. **Compute budget:** full multi-dataset runs across ~10 models download many GB
   (AMI/GigaSpeech) and take hours. Confirm we run the full suite vs. a capped
   subset (logged) first.

## Requirements / ADR pointers
- ADR-001 (Parakeet/Nemotron STT), ADR-016 (scheduler/runtime), ADR-021
  (WhisperKit secondary engine — the template for adding a new engine family).
- New ADRs likely needed in Phase 3: "MLX runtime path" and/or "SenseVoice
  optional engine."
- Issue #520 (Parakeet Unified) — this plan settles its open "better than
  Nemotron" question and generalizes the benchmark.
