# FluidAudio 0.15.6 → 0.15.7 eval (2026-09-13)

Record of the pin bump for [#1023](https://github.com/moona3k/macparakeet/issues/1023).
Replay recipe: [fluidaudio-0.15.7-ab.md](fluidaudio-0.15.7-ab.md). Harness:
[README.md](README.md).

**Headline.** Exact / `--speaker-count` / `--speaker-max` already bound on
0.15.6 for this public slice. 0.15.7 did **not** change unconstrained speaker
counts. LibriSpeech Parakeet v3 WER did not regress. Diarization *quality*
(Auto over-split) did not improve. The bump still ships FluidAudio [#891](https://github.com/FluidInference/FluidAudio/pull/891),
a dual-census cap fix whose published counterexample is synthetic.

This does **not** close [#944](https://github.com/moona3k/macparakeet/issues/944).

## Environment

| Item | Value |
|------|--------|
| Date | 2026-09-13 |
| Machine | Apple M4 Pro, arm64 |
| OS | macOS 26.6.2 (25G83) |
| Worktree | `/Users/dmoon/code/macparakeet-fa0157-eval` |
| Branch | `fix/1023-fluidaudio-0.15.7` |
| Base `HEAD` before pin | `566bd042` (`origin/main`) |
| Baseline CLI | `$HOME/asr-bench/fluidaudio-0.15.7-ab/cli-0.15.6` (copied before the pin) |
| Candidate CLI | `$HOME/asr-bench/fluidaudio-0.15.7-ab/cli-0.15.7` |
| FluidAudio 0.15.6 | `Package.resolved` revision `4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b` |
| FluidAudio 0.15.7 | `Package.resolved` revision `41540ea237350afe5117a082b5c28eda642d0612` |
| App STT for diarization JSON | `transcribe --engine parakeet` (saved GUI Parakeet build; this machine’s default is v3) |
| App STT for WER | `--engine parakeet --parakeet-model v3` |
| History | every run `--no-history` |
| Diarization | `--speaker-detection on` plus `--output-dir` so CoreML chatter cannot contaminate JSON |

One `.build` tree. The 0.15.6 binary was copied out, then the pin was applied
and rebuilt in place.

Local MacParakeet meeting folders were **not** used as labels. Calendar 1:1
rows that already showed two system speakers had no recoverable audio.
Remaining long system tracks in the library are 4–15 speakers and unlabeled.

## What 0.15.7 contains (inherited, not all measured)

From [FluidAudio v0.15.7](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.7)
(2026-09-10). Only the rows that can reach this app:

| Upstream | App surface | Measured here? |
|----------|-------------|----------------|
| [#891](https://github.com/FluidInference/FluidAudio/pull/891) dual-census Exact / max | GUI Other speakers Exact N, CLI `--speaker-count` / `--speaker-max`, `MeetingSpeakerPrior` ceiling | Speaker **counts** on VoxConverse. Not the synthetic `gamma`/`pi` unit case. |
| [#869](https://github.com/FluidInference/FluidAudio/pull/869) v3 long-form default no-mel | Parakeet v3 batch | Indirect: 200-utt WER, including one long utterance that 0.15.6 truncated and 0.15.7 finished |
| [#895](https://github.com/FluidInference/FluidAudio/pull/895) / [#903](https://github.com/FluidInference/FluidAudio/pull/903) streaming final-window / seam | Live dictation | **No** |
| [#898](https://github.com/FluidInference/FluidAudio/pull/898) / [#900](https://github.com/FluidInference/FluidAudio/pull/900) CTC vocab / spotter-rescue | Custom vocabulary boosting (CTC rescorer) | Unit tests only; no `say` Phase 0 audio |
| [#866](https://github.com/FluidInference/FluidAudio/pull/866) Nemotron decode-time vocab | Not this app’s CTC rescorer | **No** |
| TTS / Kokoro / podspec / x86_64 | Unused | **No** |

Unconstrained clustering is unchanged by design in #891.

## Speaker-count methodology

### Labels

[VoxConverse v0.3](https://github.com/joonson/voxconverse) (CC BY 4.0). Oracle
count = unique RTTM speaker ids (column 8). Copied labels: `rttm/*.rttm`.
Index of every official file: `voxconverse_v0.3_speaker_counts.tsv`.

Do **not** score Exact-N runs with DER. The cap is allowed to collapse people.

### Slice

Test split only (per-file WAVs, not the ~4.3 GB Oxford zip). Mid-length first,
one longer 2-speaker clip.

| Role | File | RTTM speakers | RTTM end (s) | WAV duration (s) | WAV |
|------|------|---------------|--------------|------------------|-----|
| Over-split control | `wibky` | 1 | 298.14 | 302.91 | 9.2 MB |
| Over-split control | `sfdvy` | 1 | 326.40 | 336.58 | 10.3 MB |
| Exact-1 bind | `bxcfq` | 2 | 196.44 | 196.48 | 6.0 MB |
| Exact-1 bind | `gylzn` | 2 | 363.06 | 363.65 | 11.1 MB |
| Exact-1 bind (long) | `ouvtt` | 2 | 718.41 | 727.62 | 22.2 MB |
| Max-2 ceiling | `fyqoe` | 3 | 290.84 | 311.10 | 9.5 MB |
| Max-2 ceiling | `ledhe` | 3 | 400.94 | 402.75 | 12.3 MB |

WAVs: 16 kHz mono PCM from Hugging Face `ggfox00000/dia-voxconverse-test`
(`audio/test/<id>.wav`). Duration can exceed RTTM end by trailing silence
(`fyqoe` +20 s). That does not change the speaker-count oracle.

Selection rule: 1- / 2- / 3-speaker test files with enough length to stress
VBx, without downloading the full zip. Not a random sample of the 232-file
test set; `selected_files.tsv` is the exact list.

### Runs

For each file × both CLIs:

1. Unconstrained (`--speaker-detection on`, no count flags).
2. If role starts with `exact1`: `--speaker-count 1`.
3. If role is `max2_ceiling`: `--speaker-min 1 --speaker-max 2`.

Follow-up hunts (same files, both CLIs), after the main table:

4. Exact 1 on the 1-speaker controls (`wibky`, `sfdvy`) — collapse a false split.
5. Exact 2 on `bxcfq`, `ouvtt`, `fyqoe` — bind when unconstrained already over-split.

Roster in JSON = `len(speakers)`. Cross-check: unique
`wordTimestamps[].speakerId` and unique `diarizationSegments[].speakerId`.
On every run in this eval those three counts matched.

JSON lives under `$HOME/asr-bench/fluidaudio-0.15.7-ab/results/{baseline,candidate}/`
and is **not** in git.

```sh
export BASELINE_CLI="$HOME/asr-bench/fluidaudio-0.15.7-ab/cli-0.15.6"
export CANDIDATE_CLI="$HOME/asr-bench/fluidaudio-0.15.7-ab/cli-0.15.7"
export VOXCONVERSE_ROOT="$HOME/asr-bench/voxconverse"
export RESULTS_DIR="$HOME/asr-bench/fluidaudio-0.15.7-ab/results"
python3 benchmarks/diarization/scripts/download_selected_wavs.py
benchmarks/diarization/scripts/run_speaker_count_ab.sh
python3 benchmarks/diarization/scripts/score_speaker_count.py \
  --results-dir "$RESULTS_DIR" --arm baseline
python3 benchmarks/diarization/scripts/score_speaker_count.py \
  --results-dir "$RESULTS_DIR" --arm candidate
```

### Pass gate (as written before the run)

Ship 0.15.7 if: Exact 1 is 1 on 0.15.7; max 2 is ≤ 2; unconstrained counts match
across pins or are explained; LibriSpeech 200-utt WER is not worse by more than
**+0.5** absolute. If 0.15.6 Exact 1 was already 1, that file is a non-repro of
#891, not proof the library bug is gone.

## Speaker-count results

Unconstrained and the planned constraints, 0.15.6 vs 0.15.7 — **identical**.

| File | RTTM | Unconst. | Exact 1 | Max 2 |
|------|------|----------|---------|-------|
| wibky | 1 | **2** | 1 (follow-up) | — |
| sfdvy | 1 | 1 | 1 (follow-up) | — |
| bxcfq | 2 | **3** | 1 | Exact 2 → 2 (follow-up) |
| gylzn | 2 | 2 | 1 | — |
| ouvtt | 2 | **4** | 1 | Exact 2 → 2 (follow-up) |
| fyqoe | 3 | **4** | — | 2; Exact 2 → 2 (follow-up) |
| ledhe | 3 | 3 | — | 2 |

Follow-up Exact 1 / Exact 2 also matched across pins. 0.15.6 already collapsed
`wibky` 2 → 1 under `--speaker-count 1`.

**Interpretation.** #891 did not fire on this audio. Caps already held. The
user-visible over-split (`wibky` 1→2, `bxcfq` 2→3, `ouvtt` 2→4, `fyqoe` 3→4)
is unconstrained clustering, which #891 does not change. Auto 1:1 still uses
`MeetingSpeakerPrior` `max = n + 1`, so two other-speaker labels remain legal.

## ASR methodology

LibriSpeech `test-clean` at `$HOME/asr-bench/LibriSpeech/test-clean` (2620
flacs on disk). Runner: `benchmarks/asr/run_macparakeet.py --limit 200
--selection stride --engine parakeet-v3` (evenly spaced 200 utterances, not
the first 200). `--speaker-detection off --no-history --format transcript`.

Scorer: `benchmarks/asr/score.py --simple` (lowercase, strip punctuation).
`whisper-normalizer` was **not** installed on this machine, so these WER
figures are not Open ASR Leaderboard-normalizer numbers. They **are**
comparable across the two CLIs because both JSONLs used the same scorer.

`mutagen` was missing, so `audio_s` / RTFx were not recorded (`total_audio=0`).
Wall clock is not a speed claim (model already warm; 0.15.6 62.8 s vs 0.15.7
38.1 s for the 200-file batch is confounded by cache).

```sh
python3 benchmarks/asr/run_macparakeet.py \
  --cli "$HOME/asr-bench/fluidaudio-0.15.7-ab/cli-0.15.6" \
  --dataset-dir "$HOME/asr-bench/LibriSpeech/test-clean" \
  --dataset-name test-clean --engine parakeet-v3 --limit 200 --selection stride \
  --records "$HOME/asr-bench/fluidaudio-0.15.7-ab/asr/baseline_parakeet-v3_test-clean_200.jsonl" \
  --work-dir "$HOME/asr-bench/fluidaudio-0.15.7-ab/asr/baseline-work"

python3 benchmarks/asr/run_macparakeet.py \
  --cli "$HOME/asr-bench/fluidaudio-0.15.7-ab/cli-0.15.7" \
  --dataset-dir "$HOME/asr-bench/LibriSpeech/test-clean" \
  --dataset-name test-clean --engine parakeet-v3 --limit 200 --selection stride \
  --records "$HOME/asr-bench/fluidaudio-0.15.7-ab/asr/candidate_parakeet-v3_test-clean_200.jsonl" \
  --work-dir "$HOME/asr-bench/fluidaudio-0.15.7-ab/asr/candidate-work"

python3 benchmarks/asr/score.py --simple \
  "$HOME/asr-bench/fluidaudio-0.15.7-ab/asr/baseline_parakeet-v3_test-clean_200.jsonl"
python3 benchmarks/asr/score.py --simple \
  "$HOME/asr-bench/fluidaudio-0.15.7-ab/asr/candidate_parakeet-v3_test-clean_200.jsonl"
```

## ASR results

| Arm | Files | WER% | p90% | fail% (WER>20%) | I/D/S |
|-----|-------|------|------|-----------------|-------|
| 0.15.6 | 200 | 2.56 | 8.4 | 3.0 | 12/20/70 |
| 0.15.7 | 200 | 2.23 | 7.8 | 2.5 | 13/9/67 |

Gate: do not worsen by more than +0.5 absolute. Observed **−0.33**.
Identical hypotheses: **192/200**.

The eight diffs (ref is LibriSpeech caps):

| ID | What changed |
|----|----------------|
| `1188-133604-0028` | 0.15.6 truncated after “as it is”; 0.15.7 finished “cloud and fire” (matches ref). Likely #869 long-form. |
| `1188-133604-0015` | Both truncated vs ref (“golden ground”); 0.15.7 reached “golden”, 0.15.6 stopped at “gold”. |
| `2961-960-0008` | 0.15.6 trailing “and”; 0.15.7 ends cleanly. |
| `6829-68771-0007` | “occupant” → “occupants” (0.15.7 matches ref). |
| `7729-102255-0044` | “Harry was” → “Here he was” (0.15.7 matches ref). |
| `7729-102255-0004` | “bogus” → “Bogus” (capitalization only under `--simple`). |
| `2300-131720-0033` | 0.15.7 inserted `meter.,` (extra period). |
| `4077-13751-0018` | 0.15.7 duplicated “as the as the”. Small local regression. |

Net: completeness and a few substitutions improved; one duplication and one
stray period went the other way. Not a dictation-seam test.

## Unit tests

Not a substitute for the CLI A/B. Full `swift test` was **not** run (DSP/audio
simulations would not exercise FluidAudio clustering on these WAVs).

```sh
swift test --filter 'DiarizationServiceTests|MeetingSpeakerPriorTests|CustomVocabularyBoostingTests|ModelDeletionTests|NemotronEnglishEngineLoadGatingTests'
# 86 passed

swift test --filter 'TranscribeCommandTests|RetranscribeCommandTests|ParakeetTDTASRConfigTests|STTClientTests|DiarizationServiceEmbeddingTests'
# 130 passed
```

## App change (what landed)

1. `Package.swift` `exact: "0.15.7"`; `Package.resolved` moved **only** FluidAudio.
2. `DiarizationService.pipelineRevision` `"fluidaudio-0.15.7"` (voiceprint
   aggregation identity; old 0.15.6 centroids are a different profile).
3. Spec / ADR-010 2026-09-13 amendment.
4. This harness (`benchmarks/diarization/`).

`spec/contracts/speaker-voiceprints.md` is unchanged. CLI flags are unchanged
(no `Sources/CLI/CHANGELOG.md` entry).

## What this eval cannot claim

- DER on VoxConverse or AMI.
- Live dictation truncation / duplication (#895 / #903).
- Custom-vocab recall on `say` audio.
- Nemotron / Whisper / Cohere WER.
- That Exact 1 “went from 2 to 1” on real audio (it was already 1).
- That Auto 1:1 meetings get cleaner (#944, `max = n + 1`).
- Open ASR Leaderboard WER (`--simple` only).
- Speed / RTFx.
