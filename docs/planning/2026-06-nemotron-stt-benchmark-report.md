# Nemotron 3.5 STT Benchmark Report

Last updated: 2026-06-08
Status: smoke benchmark complete; product-corpus benchmark still required before
promoting Nemotron beyond Beta.

## Scope

This report compares the production MacParakeet CLI path for:

- Parakeet TDT 0.6B v3
- Nemotron 3.5 ASR Streaming 0.6B, CoreML via FluidAudio
- Whisper Large v3 Turbo via WhisperKit

The goal is decision support for the Nemotron Beta engine. This is not a final
model-quality ranking. The current corpus is synthetic `say` audio and is good
for integration, setup, latency, memory, and obvious transcript regressions. It
is not enough to claim real-world accuracy or default-engine readiness.

## Upstream Context

NVIDIA describes `nvidia/nemotron-3.5-asr-streaming-0.6b` as a 600M parameter
multilingual streaming ASR model released on 2026-06-04. The model card states
support for 40 language-locales, punctuation/capitalization, automatic language
detection, and configurable chunk sizes including 80 ms, 160 ms, 320 ms, 560 ms,
and 1120 ms. Source:
https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b

MacParakeet currently exposes the 1120 ms multilingual CoreML path as the single
Nemotron Beta model variant.

## Method

Harness:

```bash
swift build -c release --product macparakeet-cli
PHASE_LABEL=warm REPS=1 ENGINES='parakeet-v3 nemotron whisper' \
  scripts/dev/benchmark_stt_engines.sh \
  output/benchmarks/stt/smoke-corpus-20260608/corpus.tsv
```

Artifacts:

- Warm raw TSV: `output/benchmarks/stt/stt-engine-benchmark-20260608-010344.tsv`
- Warm summary TSV:
  `output/benchmarks/stt/stt-engine-benchmark-20260608-010344-summary.tsv`
- First-run setup sample:
  `output/benchmarks/stt/logs/20260608-005353-*-english-short-1.stderr.tsv`
- Corpus: `output/benchmarks/stt/smoke-corpus-20260608/corpus.tsv`

The `output/benchmarks/...` files are local run artifacts, not tracked source
files. The source rows and log-derived setup values used below are reproduced in
this report so the PR carries the benchmark evidence.

Machine:

- Apple M4 Pro
- 48 GB RAM
- macOS 26.5 (25F71)
- Swift 6.3.1
- FluidAudio 0.15.2, revision `7f963cdc43ba89c5993654f1e138047d517a818d`

Metrics:

- `final_wall_s`: `/usr/bin/time -lp` real time for one CLI process
- `realtime_factor`: `final_wall_s / audio_duration_s`; lower is faster
- `first_progress_s`: first CLI progress event, not first transcript partial
- `max_rss_bytes`: `/usr/bin/time -lp` maximum resident set size, byte-scale on macOS
- `peak_memory_gb`: `/usr/bin/time -lp` peak memory footprint converted from bytes
- `wer`: normalized word error rate against synthetic references
- punctuation and boundary columns are in the raw TSV

Important limitation: the production CLI returns final transcripts and coarse
progress, not streaming partial transcript text. True first partial latency and
segment cadence still need a direct streaming probe or app live-preview
instrumentation.

## Corpus

| Sample | Type | Duration | Notes |
|---|---:|---:|---|
| `english-short` | dictation | 6.14s | Synthetic English dictation |
| `english-quiet` | quiet | 6.14s | Same text, -18 dB gain |
| `mixed-language` | mixed-language | 7.55s | English plus Spanish words |
| `english-meeting` | meeting | 9.86s | Meeting-style names and owners |
| `english-long` | long-file | 125.56s | Repeated planning text |

## Warm Results

Aggregate over all five samples:

| Engine | Total Wall | Overall RTF | Avg First Progress | Avg WER | Max Peak Mem |
|---|---:|---:|---:|---:|---:|
| Parakeet v3 | 2.42s | 0.0156 | 0.114s | 0.0399 | 0.070 GB |
| Nemotron | 3.91s | 0.0252 | 0.056s | 0.1201 | 0.086 GB |
| Whisper | 17.63s | 0.1136 | 0.053s | 0.0535 | 0.205 GB |

Per-sample:

| Engine | Sample | Wall s | RTF | WER | Peak GB |
|---|---|---:|---:|---:|---:|
| parakeet-v3 | english-short | 0.68 | 0.1108 | 0.0000 | 0.042 |
| nemotron | english-short | 0.70 | 0.1140 | 0.0455 | 0.073 |
| whisper | english-short | 2.57 | 0.4186 | 0.0000 | 0.183 |
| parakeet-v3 | english-quiet | 0.37 | 0.0603 | 0.0000 | 0.044 |
| nemotron | english-quiet | 0.43 | 0.0700 | 0.0455 | 0.073 |
| whisper | english-quiet | 2.26 | 0.3681 | 0.0000 | 0.185 |
| parakeet-v3 | mixed-language | 0.32 | 0.0424 | 0.1000 | 0.042 |
| nemotron | mixed-language | 0.60 | 0.0795 | 0.2500 | 0.074 |
| whisper | mixed-language | 2.33 | 0.3086 | 0.1000 | 0.184 |
| parakeet-v3 | english-meeting | 0.32 | 0.0324 | 0.0370 | 0.041 |
| nemotron | english-meeting | 0.53 | 0.0537 | 0.1852 | 0.073 |
| whisper | english-meeting | 2.34 | 0.2373 | 0.1111 | 0.184 |
| parakeet-v3 | english-long | 0.73 | 0.0058 | 0.0625 | 0.070 |
| nemotron | english-long | 1.65 | 0.0131 | 0.0744 | 0.086 |
| whisper | english-long | 8.13 | 0.0648 | 0.0565 | 0.205 |

Warm summary source excerpt:

```tsv
engine_selector	sample_type	phase	n	avg_final_wall_s	avg_realtime_factor	avg_first_progress_s	avg_peak_memory_gb	avg_wer	avg_punctuation_per_100_words
nemotron	dictation	warm	1	0.7000	0.1140	0.0750	0.0732	0.0455	4.5500
nemotron	long-file	warm	1	1.6500	0.0131	0.0500	0.0856	0.0744	15.4100
nemotron	meeting	warm	1	0.5300	0.0537	0.0540	0.0727	0.1852	7.6900
nemotron	mixed-language	warm	1	0.6000	0.0795	0.0520	0.0741	0.2500	20.0000
nemotron	quiet	warm	1	0.4300	0.0700	0.0500	0.0732	0.0455	4.5500
parakeet-v3	dictation	warm	1	0.6800	0.1108	0.3440	0.0418	0.0000	13.6400
parakeet-v3	long-file	warm	1	0.7300	0.0058	0.0520	0.0704	0.0625	16.0200
parakeet-v3	meeting	warm	1	0.3200	0.0324	0.0500	0.0411	0.0370	11.1100
parakeet-v3	mixed-language	warm	1	0.3200	0.0424	0.0510	0.0415	0.1000	15.0000
parakeet-v3	quiet	warm	1	0.3700	0.0603	0.0750	0.0439	0.0000	13.6400
whisper	dictation	warm	1	2.5700	0.4186	0.0650	0.1831	0.0000	13.6400
whisper	long-file	warm	1	8.1300	0.0648	0.0490	0.2047	0.0565	13.6600
whisper	meeting	warm	1	2.3400	0.2373	0.0500	0.1841	0.1111	11.1100
whisper	mixed-language	warm	1	2.3300	0.3086	0.0520	0.1842	0.1000	15.0000
whisper	quiet	warm	1	2.2600	0.3681	0.0500	0.1854	0.0000	13.6400
```

## First-Run Setup Sample

First run on `english-short` after release build and model download:

| Engine | First Run Wall | Peak Mem |
|---|---:|---:|
| Parakeet v3 | 19.40s | 0.065 GB |
| Nemotron | 33.67s | 0.078 GB |
| Whisper | 212.70s | 0.245 GB |

Interpretation: these numbers include CLI process start plus model load and any
remaining CoreML compile/optimization cost. They are useful as first-use setup
signals, not steady-state latency.

Source stderr excerpts:

```text
20260608-005353-parakeet-v3-english-short-1.stderr.tsv:
real 19.40
539246592 maximum resident set size
69534728 peak memory footprint

20260608-005353-nemotron-english-short-1.stderr.tsv:
real 33.67
651902976 maximum resident set size
83313480 peak memory footprint

20260608-005353-whisper-english-short-1.stderr.tsv:
real 212.70
784023552 maximum resident set size
263537696 peak memory footprint
```

## Quality Notes

- Parakeet v3 was fastest and lowest WER on this synthetic corpus.
- Nemotron was much faster than Whisper in warm steady-state and used less peak
  process memory, but it had weaker transcript quality on this English-heavy
  smoke set.
- Nemotron output often had less punctuation than Parakeet/Whisper on short
  English samples.
- Whisper handled the Spanish-accented mixed-language text better than the
  other two engines in this synthetic sample, but it was much slower.
- The meeting-style sample shows why Beta labeling matters: Nemotron merged
  words around owner names and produced "analytics parody"; Parakeet also had
  "release days", and Whisper also had "analytics parody".

## Decision

Ship Nemotron as an opt-in Beta engine, not as a default candidate.

The integration is valuable because Nemotron is local, fast, and materially
faster than Whisper in warm-path tests. The current MacParakeet smoke data does
not justify replacing Parakeet v3 or making stronger quality claims.

## Remaining Benchmark Work

Before calling the benchmark side complete:

- Run a real product corpus with natural speech, laptop/headset quiet input,
  meeting audio, mixed-language speech, and a 10-30 minute file.
- Add a direct streaming probe for true first partial latency, partial cadence,
  and boundary clipping.
- Run at least 3 repetitions per engine/sample after warm-up.
- Capture Parakeet v2 where English-only speed is relevant.
- Re-run on an 8 GB or 16 GB Apple Silicon machine if the Beta is marketed to
  lower-memory Macs.
