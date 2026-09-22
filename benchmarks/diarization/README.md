# Speaker-count evaluation

Labeled public clips for checking whether MacParakeet honours Exact /
`--speaker-count` / `--speaker-max`. Audio is **not** in git. Ground truth is
RTTM speaker identity counts from [VoxConverse v0.3](https://github.com/joonson/voxconverse)
(CC BY 4.0).

This is **not** a DER harness and does **not** close Auto 1:1 over-splits
([#944](https://github.com/moona3k/macparakeet/issues/944)). Auto still allows
`max = n + 1`. This suite tests the constraint path ([#1023](https://github.com/moona3k/macparakeet/issues/1023)).

Unconstrained Auto over-split on the same seven files is a separate gate:
[2026-09-15-issue-1046-baseline.md](2026-09-15-issue-1046-baseline.md) ([#1046](https://github.com/moona3k/macparakeet/issues/1046)).

## Layout

| Path | What it is |
|------|------------|
| `voxconverse_v0.3_speaker_counts.tsv` | Every official RTTM: unique speakers, last timestamp, speech seconds |
| `selected_files.tsv` | The default A/B slice (7 test-set files) |
| `rttm/*.rttm` | Copied v0.3 labels for that slice |
| `scripts/download_selected_wavs.py` | Fetches only those WAVs |
| `scripts/run_speaker_count_ab.sh` | Same files on two CLI binaries |
| `scripts/run_issue_1046_unconstrained_ab.sh` | Frozen 0.15.7 Auto baseline vs one candidate CLI |
| `scripts/score_speaker_count.py` | Roster vs RTTM / requested cap; `--unconstrained-only` also reports isolated flips and bounded nil words |
| `test_score_speaker_count.py` | Pure-Python correctness tests for the word-smoothing metrics |

Default audio root: `$HOME/asr-bench/voxconverse` (same pattern as LibriSpeech).

## Default slice

Chosen from the **test** split so files can be pulled individually (the Oxford
zips are ~2 GB + ~4.3 GB). Mid-length clips first; one longer 2-speaker file
for the bind test.

| Role | File | RTTM speakers | ~duration |
|------|------|---------------|-----------|
| Over-split control | `wibky`, `sfdvy` | 1 | 5.0 min, 5.4 min |
| Exact-1 bind | `bxcfq`, `gylzn` | 2 | 3.3 min, 6.1 min |
| Exact-1 bind (longer) | `ouvtt` | 2 | 12.0 min |
| Max-2 ceiling | `fyqoe`, `ledhe` | 3 | 4.8 min, 6.7 min |

`rttm_speakers` is `unique(SPEAKER column 8)` in the v0.3 RTTM. That is the
oracle count. Do not use MacParakeet library folders as labels. WAV duration
can exceed `rttm_end_s` by trailing silence (the Hugging Face test copies do);
that does not change the speaker-count oracle.

## What to measure

On a 2-speaker file, `--speaker-count 1` is supposed to **collapse** to one
cluster. Ground truth is still 2 people. Score the cap, not DER, on that run.

| Run | Pass on 0.15.7 | Notes |
|-----|----------------|-------|
| 2-spk + `--speaker-count 1` | roster = 1 | Cap test, not DER. This slice already bound on 0.15.6 |
| Same file, unconstrained | roster = 2 (or explained) | #891 claims unconstrained is unchanged |
| 1-spk unconstrained | roster = 1 | Over-segmentation control |
| 3-spk + `--speaker-max 2` | roster ≤ 2 | `MeetingSpeakerPrior` ceiling path |
| 3-spk unconstrained | roster ~ 3 | Context for the cap run |

ASR quality is a **separate** arm: LibriSpeech at `$HOME/asr-bench/LibriSpeech`
via `benchmarks/asr`. Diarization pass does not prove WER.

## Disk

A 16 kHz mono 16-bit minute is ~1.9 MB. This slice is on the order of
**150 MB**, not the full zips. One in-place `swift build -c release` is the
large cost (~5 GB `.build`). Copy the 0.15.6 CLI aside, then rebuild 0.15.7
in the same tree.

## Prepare audio

```sh
python3 benchmarks/diarization/scripts/download_selected_wavs.py
```

Canonical WAV source is Oxford (`voxconverse_dev_wav.zip` /
`voxconverse_test_wav.zip`). The script prefers per-file Hugging Face copies
of the **test** split when present, and falls back to documenting the zip
extract path.

## A/B

```sh
export BASELINE_CLI=/path/to/cli-0.15.6
export CANDIDATE_CLI=/path/to/cli-0.15.7
export VOXCONVERSE_ROOT="$HOME/asr-bench/voxconverse"
benchmarks/diarization/scripts/run_speaker_count_ab.sh
```

See [fluidaudio-0.15.7-ab.md](fluidaudio-0.15.7-ab.md) for the 0.15.6 → 0.15.7
gate. Frozen methodology and numbers:
[2026-09-13-fluidaudio-0.15.7-eval.md](2026-09-13-fluidaudio-0.15.7-eval.md).
