# Orukeet versus Parakeet v3

Date: 2026-09-21, America/Los_Angeles.

**PR:** [#1091](https://github.com/moona3k/macparakeet/pull/1091).

Independent check of the optional Orukeet preview against Parakeet v3, using
the repo ASR harness. Orukeet stays a Parakeet variant
(`--engine parakeet --parakeet-model orukeet`). This is not a ranking against
Cohere, Unified, v2, WhisperKit, or Nemotron, and it does not replace the
committed macOS 15 table in [`benchmarks/asr/README.md`](../../benchmarks/asr/README.md).

## Verdict

On this Mac, with one CLI build, Orukeet is a small but statistically real
improvement over Parakeet v3 on full LibriSpeech English, and it sits in the
same speed and memory band. The multilingual picture is mixed and only
directional: on 150-clip FLEURS slices, Orukeet is better on Danish, Finnish,
Greek, Hungarian, Romanian, and Swedish, v3 is better on French and Polish, and
the other eight covered European languages tie. Both models fail Korean,
Japanese, and Chinese. Nine of the 25 languages named for this family were not
in the FLEURS mirror, so this run does not support a 25-language accuracy claim.

The vendor NeMo card (9.85% vs 11.01% pooled FLEURS) is not used here.

## Method

| Item | Value |
|------|--------|
| CLI | `macparakeet-cli`, release build of `4c30fd1a0` in the PR worktree |
| Flags | `--engine parakeet --parakeet-model orukeet` or `v3`, `--speaker-detection off`, `--no-history` |
| Telemetry | `MACPARAKEET_TELEMETRY=0` |
| Machine | Apple M4 Pro, 48 GB, macOS 26.6.2 (25G83) |
| English | LibriSpeech `test-clean` (2,620) and `test-other` (2,939), full sets |
| Multilingual | FLEURS via `FluidInference/fleurs-full`, first 150 sorted clips per language |
| Scorer | Whisper `EnglishTextNormalizer` for English, `BasicTextNormalizer` otherwise; `jiwer`; CER for Korean, Japanese, and Chinese |
| Uncertainty | Paired bootstrap, Orukeet minus v3, 2,000 resamples, seed 1234 |
| Selected model | Left as Parakeet Unified. This run did not `models select` Orukeet |

`--language` was passed on the FLEURS Orukeet runs. Parakeet ignores that flag,
so both models auto-detected. A negative delta means Orukeet had fewer errors.
"Significant" means the 95% CI excludes zero.

Records are local at `~/asr-bench/orukeet-2026-09-21/records/`. They are not
committed. The harness engine id `parakeet-orukeet` is what makes the run
repeatable.

## English

Full sets. This is the final-grade comparison for read English on this machine.

| Engine | test-clean WER | test-other WER | Macro | p90 clean / other | Fail rate clean / other | Batch RTFx clean / other |
|--------|----------------|----------------|-------|-------------------|-------------------------|--------------------------|
| Orukeet | 1.95% [1.79, 2.13] | 3.54% [3.32, 3.76] | 2.74% | 8.1 / 13.2 | 1.9% / 4.3% | 63.1× / 63.6× |
| Parakeet v3 | 2.21% [2.00, 2.44] | 3.92% [3.67, 4.18] | 3.06% | 8.7 / 14.3 | 2.3% / 5.3% | 62.1× / 64.3× |

| Subset | n | Δ WER (Orukeet − v3) | 95% CI | Verdict |
|--------|---|----------------------|--------|---------|
| test-clean | 2,620 | −0.25 pt | [−0.45, −0.10] | Orukeet better |
| test-other | 2,939 | −0.38 pt | [−0.54, −0.25] | Orukeet better |

Insertions / deletions / substitutions: Orukeet 112/154/769 on clean and
194/202/1475 on other; v3 141/250/779 and 254/241/1579. Orukeet returned no
empty hypotheses (0/2,620 clean, 0/2,939 other). v3 had one empty hypothesis
on test-clean and none on test-other.

Batch RTFx includes model load. Wall time was 308.2 s for Orukeet clean
(19,452.5 s of audio) and 302.3 s for Orukeet other (19,229.6 s). v3 was
313.2 s and 299.2 s. At this scale the two models are the same speed.

The previously published v3 row is 2.31% [2.11, 2.54] clean and 4.14%
[3.86, 4.40] other, macro 3.22%, from macOS 15 / CLI 2.11.0 / FluidAudio
0.15.4. The fresh v3 row above is close, and a bit better on test-other.
That older table also has Unified at macro 2.38% and Cohere at 2.07%. Those
rows were not re-run here, so Orukeet is not claimed to lead the English table.

## European FLEURS

n=150 per language. Ranking-grade, not a publishable absolute. Marginal CIs
are wide enough that several point gaps are ties.

| Language | Orukeet WER | v3 WER | Δ pt | 95% CI | Verdict |
|----------|-------------|--------|------|--------|---------|
| English (`en_us`) | 4.31 [3.50, 5.22] | 4.47 [3.67, 5.33] | −0.16 | [−0.77, +0.46] | tie |
| German | 6.06 [4.86, 7.36] | 5.94 [4.89, 7.10] | +0.12 | [−0.72, +1.02] | tie |
| French | 7.48 [6.13, 8.93] | 6.08 [5.00, 7.30] | +1.39 | [+0.50, +2.33] | v3 better |
| Spanish (`es_419`) | 3.94 [3.08, 4.88] | 4.07 [2.86, 5.59] | −0.13 | [−1.32, +0.98] | tie |
| Italian | 4.22 [3.33, 5.15] | 3.74 [2.99, 4.57] | +0.48 | [−0.18, +1.17] | tie |
| Portuguese (`pt_br`) | 6.31 [5.26, 7.44] | 6.20 [5.17, 7.35] | +0.11 | [−0.76, +0.92] | tie |
| Dutch | 8.18 [6.91, 9.59] | 7.76 [6.64, 8.94] | +0.42 | [−0.39, +1.33] | tie |
| Polish | 10.30 [8.46, 12.09] | 9.22 [7.68, 10.73] | +1.09 | [+0.07, +2.10] | v3 better |
| Russian | 6.54 [5.39, 7.83] | 6.78 [5.59, 8.07] | −0.24 | [−0.97, +0.49] | tie |
| Czech | 9.66 [8.00, 11.43] | 10.38 [8.73, 12.08] | −0.72 | [−2.17, +0.78] | tie |
| Danish | 16.41 [14.52, 18.25] | 18.28 [16.36, 20.09] | −1.86 | [−3.06, −0.69] | Orukeet better |
| Finnish | 11.15 [9.29, 13.23] | 14.23 [12.14, 16.43] | −3.08 | [−4.34, −1.92] | Orukeet better |
| Greek | 36.04 [33.76, 38.31] | 37.84 [35.36, 40.33] | −1.80 | [−3.18, −0.49] | Orukeet better |
| Hungarian | 15.42 [13.60, 17.24] | 19.32 [17.06, 21.77] | −3.90 | [−5.86, −2.22] | Orukeet better |
| Romanian | 12.61 [10.84, 14.44] | 14.49 [12.83, 16.12] | −1.87 | [−2.87, −0.83] | Orukeet better |
| Swedish | 13.35 [11.80, 15.03] | 14.80 [13.06, 16.55] | −1.45 | [−2.61, −0.30] | Orukeet better |

Greek hypotheses are Greek script and readable. The mid-30s WER is partly the
normalizer: `BasicTextNormalizer` does not fold Greek accents or final sigma,
so the absolute number is harsher than the transcripts look. The paired delta
is still fair, because both models take the same scorer. It is not evidence
that Greek is a strong language for either model.

## Korean, Japanese, and Chinese

These languages are outside the 25-language Parakeet v3 set. They are a
negative control. CER above 100%, plus romanized hypotheses, means both models
fail. The paired deltas are not a product win.

| Language | Orukeet CER | v3 CER | Δ pt | Empty hyps Orukeet / v3 |
|----------|-------------|--------|------|-------------------------|
| Korean | 146.66 [138.89, 154.85] | 174.32 [167.35, 181.00] | −27.66 [−35.67, −18.95] | 40 / 15 of 150 |
| Japanese | 152.41 [146.40, 158.51] | 162.60 [156.60, 168.63] | −10.19 [−16.09, −4.22] | 15 / 5 of 150 |
| Chinese | 134.17 [127.18, 142.39] | 125.83 [118.70, 133.76] | +8.35 [+2.03, +14.98] | 57 / 72 of 150 |

Orukeet has more empty Korean and Japanese hypotheses than v3. Chinese output
from both models is Latin-script noise. This matches the existing v3 finding
in the ASR README: Parakeet does not transcribe CJK.

## Speed and memory

`speed_bench.py`, 24 files, cold start from a 1-file run, steady RTFx from the
difference between a 1-file run and an N-file run. Same audio for both models
(10.4 s then 204.3 s).

| Engine | Cold start | Steady RTFx | Peak RSS | Wall, N files |
|--------|------------|-------------|----------|---------------|
| Parakeet v3 | 0.33 s | 70.9× | 124 MB | 3.07 s |
| Orukeet | 0.39 s | 81.3× | 120 MB | 2.78 s |

Orukeet starts a little slower and then runs a little faster, at the same
memory. The full-set batch rates above (~63×) are the number to quote for a
long job, because they include load. The micro-bench is the like-for-like
speed comparison. The old README's ~81× v3 figure is from macOS 15 and is not
the comparison for this pair; the fresh v3 row here is 70.9×.

## Coverage

Covered, and strong enough to keep:

- Full English `test-clean` and `test-other`, paired, same CLI, same Mac.
- Sixteen of the 25 family languages, at the harness's usual n=150: English,
  German, French, Spanish, Italian, Portuguese, Dutch, Polish, Russian, Czech,
  Danish, Finnish, Greek, Hungarian, Romanian, Swedish.
- Cold start, steady RTFx, and peak RSS.
- A CJK negative control, which both models fail.

Not covered, and not claimed:

- Bulgarian, Croatian, Estonian, Latvian, Lithuanian, Maltese, Slovak,
  Slovenian, and Ukrainian. They were not in the `FluidInference/fleurs-full`
  snapshot used for this run.
- A full FLEURS set. n=150 can move a ranking; the English full-set result is
  the one that should be quoted as a measurement.
- AMI, Earnings-22, and private dictation or meeting fixtures. File
  transcription is what ran. Meeting-session behavior was not exercised.
- Streaming, tail preview, and custom vocabulary. Those stay off for Orukeet
  and were not benchmarked.
- Unified, v2, Cohere, WhisperKit, and Nemotron on this OS. Their published
  numbers stay the macOS 15 table.
- Word-timestamp quality.

## What this supports

Orukeet is a reasonable optional preview next to v3: better read-English WER
on this machine, similar speed and memory, and no sign of a regression on the
European slices except the French and Polish gaps above. It does not justify
changing the default, which stays v3, and it does not justify quoting the
vendor's pooled FLEURS number or a 25-language accuracy line from this run.
