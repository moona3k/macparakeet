# Speaker diarization evaluation

## Nemotron comparison

The [2026-09-25 evaluation](2026-09-25-nemotron-evaluation.md) records the
measured comparison, integration decision, and remaining qualification limits.

The matched acoustic runner compares the frozen FluidAudio 0.15.7 Community-1
configuration with the new Nemotron adapter. It preserves overlaps and brief
intervals and scores zero-collar DER with overlap included. Downloaded audio,
model caches, and large prediction files stay outside Git.

- `manifests/ami-test.json`: all 16 AMI test meetings, mixed headset and true
  single distant microphone conditions, manual references and original UEMs.
- `manifests/ami-test-forced-alignment.json`: the same signals and UEMs with
  separately pinned word-aligned references, for reference-sensitivity analysis.
- `manifests/alimeeting-test.json`: all 20 official AliMeeting Test sessions,
  far channel one and a fixed arithmetic mean of every participant headset.
- `Baseline/`: isolated SDK 0.15.7 executable; reads existing models offline
  and records model/audio hashes. The app executable uses SDK 0.17.4.
- `scripts/run_comparison.py`: sequential matched runs, alternating backend
  order, checking audio identity, retaining failures and per-recording logs.
- `scripts/score_diarization.py`: pinned dscore/NIST engine, explicit coverage
  checks, per-recording errors, weighted condition totals and speaker counts.

Build the two release executables:

```sh
swift build -c release --product diarization-benchmark
swift build -c release --package-path benchmarks/diarization/Baseline
```

`prepare_ami.py --root /path/to/ami` downloads references and the scorer;
add `--recording ami_ES2004a_mhm` to download a particular official WAV.
Acquire every ID in the selected manifest before running the comparison.
Its frozen audio headers distinguish actual capture duration from the original
UEM; four distant-microphone recordings have small unscored tails. No timing
shift, cropping or padding is applied to AMI audio.

AliMeeting acquisition needs ffmpeg and the pinned requirements in
`scripts/requirements-acquisition.txt`. `prepare_alimeeting.py --root
/path/to/ali` streams the official 9.55 GB archive and retains approximately
2.4 GB of mono audio. It requires an empty destination and verifies complete
member coverage. Near headsets share the recording origin; shorter headset
tails contribute silence to the fixed 1/N mean. Audio, original annotations,
decoded durations and archive hashes are retained as provenance.

```sh
python3 benchmarks/diarization/scripts/run_comparison.py \
  --manifest benchmarks/diarization/manifests/ami-test.json \
  --audio-root /path/to/ami/audio \
  --baseline benchmarks/diarization/Baseline/.build/release/diarization-baseline \
  --candidate .build/release/diarization-benchmark \
  --baseline-models /path/to/baseline-models \
  --candidate-models /path/to/candidate-models \
  --output /path/to/results --include-offline

python3 benchmarks/diarization/scripts/score_diarization.py \
  --manifest benchmarks/diarization/manifests/ami-test.json \
  --reference-root /path/to/ami/references \
  --predictions community1-0.15.7=/path/to/results/community1-0.15.7 \
  --predictions nemotron=/path/to/results/nemotron \
  --predictions nemotron-offline=/path/to/results/nemotron-offline \
  --md-eval /path/to/ami/tools/md-eval-22.pl \
  --output /path/to/results/ami-manual-scores.json
```

Use the separate forced-alignment manifest and reference directory to rescore
the same predictions. Never pool microphone conditions as independent meetings
or mix reference conventions into one headline score. Vendor numbers use a
different scorer; matching reference files alone does not reproduce its run.

After scoring, optional activity diagnostics reuse NIST's global speaker
mapping and validate the saved error totals before measuring coverage:

```sh
python3 benchmarks/diarization/scripts/analyze_activity.py \
  --results /path/to/results --md-eval /path/to/ami/tools/md-eval-22.pl
```

This reports mapped reference interval coverage for <=200 ms, 200 ms–1 s,
and longer intervals, plus minority speakers. It is not conversational turn
recall, word accuracy, or precision; extra predicted activity is not penalized.
The output lists any missing protocols, so a partial diagnostic cannot be
mistaken for complete corpus coverage.

The opt-in `NemotronDiarizationE2ETests` exercises real ASR, source-separated
meeting finalization, persistence, file transcription and model reuse. See its
environment-variable instructions before running it. Normal tests do not
download models or process real recordings.

Its JSON contains `fixedASRWordProjections` for both diarizers with identical
ASR word evidence, raw intervals, labels before smoothing, and final words.
To reproduce the report's conditional word-label diagnostic, clip/rebase AMI
ES2004a references from 50–230 seconds, use NIST `-M` to map each arm's raw
intervals independently, and hold that mapping fixed for both projections.
At each recognized word's midpoint, score only exactly one active reference
speaker (start inclusive/end exclusive); count nil/unmapped predictions as
wrong and report zero-activity/overlap exclusions. This is not cpWER or a
reference-word-aligned accuracy measure. The result receipt records mappings,
hashes, eligible counts and transitions.

## Existing speaker-count slice

Labeled public clips for checking whether MacParakeet honours Exact /
`--speaker-count` / `--speaker-max`. Audio is **not** in git. Ground truth is
RTTM speaker identity counts from [VoxConverse v0.3](https://github.com/joonson/voxconverse)
(CC BY 4.0).

This older count-only slice does **not** measure DER or close Auto 1:1 over-splits
([#944](https://github.com/moona3k/macparakeet/issues/944)). Auto still allows
`max = n + 1`. This suite tests the constraint path ([#1023](https://github.com/moona3k/macparakeet/issues/1023)).

Unconstrained Auto over-split on the same seven files is a separate gate:
[2026-09-15-issue-1046-baseline.md](2026-09-15-issue-1046-baseline.md) ([#1046](https://github.com/moona3k/macparakeet/issues/1046)).

Nemotron trained on VoxConverse development and test, so this slice is a
regression check rather than held-out evidence for its model quality.

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
