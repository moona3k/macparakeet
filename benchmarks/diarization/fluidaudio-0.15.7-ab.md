Record of the 2026-09-13 run (tables, commands, eight ASR diffs):
[2026-09-13-fluidaudio-0.15.7-eval.md](2026-09-13-fluidaudio-0.15.7-eval.md).

# FluidAudio 0.15.7 speaker-count A/B

Issue [#1023](https://github.com/moona3k/macparakeet/issues/1023). App change is
the pin plus `pipelineRevision`. This note is the measurement contract for that
bump, not a substitute for ADR-010 after numbers exist.

## Claim under test

On FluidAudio 0.15.6, Exact / `--speaker-count` / `maxSpeakers` can fail to bind
(FluidAudio [#891](https://github.com/FluidInference/FluidAudio/pull/891), shipped
in 0.15.7). MacParakeet maps GUI **Other speakers → Exact N** and CLI
`--speaker-count N` to `withSpeakers(exactly:)`.

This is **not** [#944](https://github.com/moona3k/macparakeet/issues/944) (Auto
1:1 split on 0.7.3 / 0.15.4). Auto still uses `MeetingSpeakerPrior` `max = n + 1`.
0.15.7 will not close that.

## Materials

| Arm | Source | Why we trust it |
|-----|--------|-----------------|
| Speaker-count | VoxConverse v0.3 test slice in `selected_files.tsv` + `rttm/` | Public RTTM; unique speaker ids |
| 1-speaker extra | LibriSpeech `test-clean` (already at `$HOME/asr-bench/LibriSpeech`) | Read speech, one talker |
| ASR WER | Same LibriSpeech, `benchmarks/asr` scorers | Independent transcripts |
| Not used | Local MacParakeet meeting folders | 1:1 rows lost audio; remaining long takes are 4–15 speakers and unlabeled |

Do not score Exact-1 runs with DER. The constraint is allowed to disagree with
the oracle count.

## Binaries

Keep a 0.15.6 CLI **outside** `.build`, then rebuild 0.15.7 in place:

```sh
WORK_DIR="${WORK_DIR:-$HOME/asr-bench/fluidaudio-0.15.7-ab}"
mkdir -p "$WORK_DIR"
swift build -c release --product macparakeet-cli
cp .build/arm64-apple-macosx/release/macparakeet-cli "$WORK_DIR/cli-0.15.6"
export BASELINE_CLI="$WORK_DIR/cli-0.15.6"
# after Package.swift → 0.15.7 and a rebuild:
export CANDIDATE_CLI="$PWD/.build/arm64-apple-macosx/release/macparakeet-cli"
```

Never invoke a bare `macparakeet-cli`. Always `--no-history`.

## Diarization commands

For each selected WAV, both binaries:

```text
transcribe $wav --engine parakeet --format json --no-history
transcribe $wav --engine parakeet --format json --no-history --speaker-count 1
```

Plus on 3-speaker files:

```text
transcribe $wav --engine parakeet --format json --no-history --speaker-min 1 --speaker-max 2
```

`scripts/run_speaker_count_ab.sh` does this. Roster = `len(speakers)` in the JSON,
and unique `wordTimestamps[].speakerId` (must not be a silent extra cluster).

## Pass / stay on 0.15.6

Ship 0.15.7 only if all hold:

1. Every **exact1_bind** file: 0.15.7 `--speaker-count 1` roster is 1. If 0.15.6
   was already 1 on that file, the file did not reproduce #891; keep it as a
   non-repro and do not treat it as proof the bug is gone.
2. **overseg_control** unconstrained stays 1 on both arms (or a written
   explanation).
3. **max2_ceiling** `--speaker-max 2` is ≤ 2 on 0.15.7.
4. Unconstrained 2-spk and 3-spk counts are identical across arms or explained
   in the ADR (upstream says unconstrained clustering does not move).
5. ASR: a LibriSpeech slice (at least 200 `test-clean` utterances, Parakeet v3)
   does not worsen `avg_wer` by more than **+0.5** absolute vs the 0.15.6 CLI on
   the same machine. Use `BIN=...` with `scripts/dev/benchmark_stt_engines.sh`
   or `benchmarks/asr/run_macparakeet.py --limit 200`.
6. Focused tests: `DiarizationServiceTests`, `MeetingSpeakerPriorTests`,
   `CustomVocabularyBoostingTests`, `ModelDeletionTests`. Then one full
   `swift test`.

If (1) fails, the bump does not fix #1023. If (5) fails, stay on 0.15.6 until a
follow-up names an ASR override.

## App edits (after baseline CLI is copied)

1. `Package.swift` `exact: "0.15.6"` → `"0.15.7"`; keep the “bump deliberately”
   sentence; mention #891 / 0.15.7 in the comment.
2. `swift package resolve`; `Package.resolved` should move only FluidAudio
   `revision` / `version`.
3. `DiarizationService.pipelineRevision` → `"fluidaudio-0.15.7"`.
4. Stale “current pin is 0.15.6” comments listed in the 0.15.7 plan, plus ADR-010
   / spec version lines **after** the tables exist.

## Baseline observed (0.15.6 CLI, this slice)

Work tree `macparakeet-fa0157-eval`, CLI copied to
`$HOME/asr-bench/fluidaudio-0.15.7-ab/cli-0.15.6`. JSON under `results/baseline/`.

| File | RTTM | Unconstrained roster | Constraint | Constrained roster |
|------|------|----------------------|------------|--------------------|
| wibky | 1 | 2 | — | — |
| sfdvy | 1 | 1 | — | — |
| bxcfq | 2 | 3 | `--speaker-count 1` | 1 |
| gylzn | 2 | 2 | `--speaker-count 1` | 1 |
| ouvtt | 2 | 4 | `--speaker-count 1` | 1 |
| fyqoe | 3 | 4 | `--speaker-max 2` | 2 |
| ledhe | 3 | 3 | `--speaker-max 2` | 2 |

Exact 1 and max 2 **already bind** on 0.15.6 here. FluidAudio #891’s published
counterexample is a synthetic `gamma`/`pi` assignment, not a labeled WAV; this
slice does not show Exact 1 leaking to 2. Unconstrained over-split (1→2, 2→3/4)
is the pattern that remains in Auto / #944 territory.

The 0.15.7 diarization compare on this slice is therefore: constraints still
hold, unconstrained rosters match 0.15.6 (or get a written explanation), plus
the separate LibriSpeech WER arm.

## Candidate observed (0.15.7)

Same seven files, same commands. Unconstrained and constrained rosters matched
0.15.6 on every run (including wibky 1→2 and ouvtt 2→4).

Follow-up (both pins, same result): `--speaker-count 1` on `wibky`/`sfdvy`
yields 1; `--speaker-count 2` on `bxcfq`/`ouvtt`/`fyqoe` yields 2.

LibriSpeech `test-clean` 200 utterances, stride selection, Parakeet v3,
`score.py --simple`: 0.15.6 **2.56%** WER vs 0.15.7 **2.23%** (192/200 identical
hypotheses). Gate was “do not worsen by more than +0.5 absolute.”

Focused tests: `DiarizationServiceTests`, `MeetingSpeakerPriorTests`,
`CustomVocabularyBoostingTests`, `ModelDeletionTests`,
`NemotronEnglishEngineLoadGatingTests` — 86 passed. Follow-up:
`TranscribeCommandTests`, `RetranscribeCommandTests`,
`ParakeetTDTASRConfigTests`, `STTClientTests`,
`DiarizationServiceEmbeddingTests` — 130 passed. Full `swift test` not run
in this worktree.

## Limits of this slice

- VoxConverse is YouTube debate/news, not MacParakeet system-audio 1:1.
- Exact-1 on a 2-speaker clip tests the cap, not “this meeting had one other
  person.”
- No live-dictation seam files here. That still needs short recorded utterances
  if criterion (streaming truncation/duplication) is in play.
- Custom-vocab Phase 0 audio is regenerated with `say`; not in this directory.
- Full Oxford zips and AMI SDM remain optional follow-ups for DER, not for the
  Exact-1 gate.
