# FluidAudio 0.15.7 — Exact Speaker Counts Are Not Honoured

- **Date:** 2026-09-13
- **Status:** TODO — OWNER GATE (audio corpus). The plan is verified against the
  upstream diff and this repo's call sites, but execution needs a real audio
  corpus and human judgement on the WER numbers, so it is not
  `EXECUTOR-READY`.
- **Priority:** P1 — a reproduced user-facing defect.
- **Trigger:** issue #1023. A 1:1 meeting retranscribed with *Other speakers = 1*
  returns 2 system speakers.

## 1. Problem and upstream cause

An exact speaker count requested at retranscription is not held. Upstream cause
is FluidAudio #891: the constraint check counts clusters that win an argmax,
while centroid construction keeps every cluster with `pi > 1e-7`. A cluster that
wins no argmax makes the detected count look already compliant, so no
re-clustering runs, and constrained assignment (pyannote parity: two speakers
sharing a segmentation chunk must land on distinct clusters) then revives the
cluster the constraint had excluded.

The same gate governs `maxSpeakers`, so `MeetingSpeakerPrior`'s ceiling
(`max = n + 1`) can be exceeded too. Fixed upstream by PR #891, shipped in
0.15.7. This repo pins 0.15.6.

## 2. Exposure analysis (verified against tag v0.15.7)

**No compile break is expected.** The only `ASRConfig` construction here is
`ASRConfig(parallelChunkConcurrency: 1)`
(`Sources/MacParakeetCore/STT/ParakeetTDTASRConfig.swift:15`); that parameter
survives. Nothing in this repo references `melChunkContext` (now
`melChunkContextOverride`, with a deprecated shim) or `ParakeetEncoderPrecision`
(which gains an `int8V2` case) — the unified engine uses
`UnifiedEncoderPrecision.int8`, a different enum. There is no exhaustive
`switch` over any changed enum. `OfflineDiarizerConfig` is untouched upstream,
so `DiarizationService.highAccuracyConfig` compiles unchanged.

**Behavioural exposure is real, and it is the actual risk:**

- `Sources/MacParakeetCore/STT/CustomVocabularyBoosting.swift` binds directly to
  the CTC surface that #866/#898/#900 rewrote (`CtcModels.downloadAndLoad`,
  `CtcKeywordSpotter`, `VocabularyRescorer.create`, `CustomVocabularyTerm`,
  `ContextBiasingConstants.rescorerConfig`). Every signature survives — new
  parameters are defaulted — but the `.default` config now carries spotter
  rescue bounding, so boosting behaviour moves under our defaults.
- #869: Parakeet v3 long-form now defaults to the no-mel path.
- #895/#903: the final streaming window is re-decoded with a fresh decoder
  state, and its seam reconciled.

**Voiceprints.** Bumping `pipelineRevision` changes `aggregationProfileId` for
every new embedding. Stored exemplars keep theirs — no migration rewrites it, by
design — and match at `tau - crossAggregationPenalty` (0.20 instead of 0.25).
No test hard-codes a real digest; tests use symbolic ids or recompute via
`DiarizationService.modelIdentity(for:)`. `AppFeatures.voiceProfilesEnabled` is
`false`, so there is no user-facing impact today. No boundary contract moves:
`spec/contracts/speaker-voiceprints.md` already documents that the aggregation
id is not frozen.

**Toolchain asymmetry.** 0.15.6 is already `swift-tools-version: 6.0`; only
`Package@swift-6.2.swift` (a `NemoTextProcessing` trait, enabled by default) is
new. A local Swift 6.3 toolchain resolves the 6.2 manifest while CI
(`macos-14`, Swift 6.0) resolves the 6.0 one. Both link the same xcframework,
but anything trait-related would break only in CI. Push early and read the CI
log rather than treating a green local run as the gate.

**Measurement trap.** `Sources/CLI/Commands/RetranscribeCommand.swift:490-505`
takes the meeting branch only when `archivedMeetingRecording(for:)` resolves;
otherwise it falls back to diarizing the *mixed* track, which measures something
else. The decisive test must therefore go through
`transcribe --speaker-count 1` on an isolated system-track WAV.

## 3. Capture the baseline before editing anything

The before/after comparison ADR-010 mandates is impossible once the dependency
is resolved, so build and set aside the 0.15.6 CLI first, and name both arms as
explicit paths:

```bash
WORK_DIR=<a directory outside the repo>
swift build -c release --product macparakeet-cli
cp .build/arm64-apple-macosx/release/macparakeet-cli "$WORK_DIR/cli-0.15.6"
export BASELINE_CLI="$WORK_DIR/cli-0.15.6"
export CANDIDATE_CLI="$PWD/.build/arm64-apple-macosx/release/macparakeet-cli"
```

`CANDIDATE_CLI` only becomes the 0.15.7 binary after §4, so rebuild
`swift build -c release --product macparakeet-cli` before running the candidate
arm. Never invoke a bare `macparakeet-cli` in either arm: `PATH` resolves to
whatever release is installed on the machine, which is neither arm.

## 4. Edits, in this order

Dependency first, so any break surfaces on the first compile.

1. `Package.swift:34` — `exact: "0.15.6"` → `"0.15.7"`. Rewrite the comment at
   lines 29-33, which cites "(0.15.5 and 0.15.6, see ADR-010)", to cover
   0.15.7/#891. Keep the mandate sentence verbatim: *Bump deliberately with an
   STT regression pass and a diarization before/after comparison.*
2. `swift package resolve`, then `git diff -- Package.resolved`. The diff must be
   confined to FluidAudio's `revision` and `version` lines; the trailing
   `"version" : 2` format field must not move.
3. `swift build` — the real compile gate for the ASR and vocabulary surface. Do
   this before touching any comment, so a failure is attributable.
4. `Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift:468` —
   `pipelineRevision` → `"fluidaudio-0.15.7"`.
5. Stale comments citing 0.15.6 as current, in one pass:
   `DiarizationService.swift:437-443`, `ParakeetUnifiedEngine.swift:251`,
   `NemotronEnglishEngine.swift:42`,
   `Tests/MacParakeetTests/STT/ModelDeletionTests.swift:73,86,128`,
   `Tests/MacParakeetTests/Services/Diarization/DiarizationServiceTests.swift:105`,
   `Tests/MacParakeetTests/STT/NemotronEnglishEngineLoadGatingTests.swift:5`.
6. Docs and ADR last, once the measurements exist to cite (§8).

## 5. Corpus and pass criteria

| id | Content | What it proves |
|----|---------|----------------|
| A | isolated system track, 1:1, two real voices, >= 3 min | the decisive #1023 case |
| B | three distinct voices, known turn points, >= 3 min | the `--speaker-max` ceiling |
| C | a single speaker, >= 2 min | no over-segmentation |

Run this block twice, once with `BIN="$BASELINE_CLI"` and once with
`BIN="$CANDIDATE_CLI"`, recording roster size, the speaker ids actually
attributed to words, and wall time:

```bash
"$BIN" transcribe A.wav --speaker-count 1 --format json
"$BIN" transcribe A.wav --format json
"$BIN" transcribe B.wav --speaker-count 2 --format json
"$BIN" transcribe B.wav --speaker-min 1 --speaker-max 2 --format json
"$BIN" transcribe B.wav --format json
"$BIN" transcribe C.wav --speaker-count 1 --format json
"$BIN" transcribe C.wav --format json
```

Every corpus item gets an unconstrained run, because rollback criterion 2 is a
statement about auto-detected counts across items and is unmeasurable on an item
that was only ever run constrained.

Pass criteria on the 0.15.7 arm:

- **A with `--speaker-count 1` returns a roster of 1 and one attributed id**
  (2 on 0.15.6). This single number closes #1023.
- B constrained to 2 returns 2; B capped at 2 returns <= 2 — this is the
  `MeetingSpeakerPrior` ceiling path, same gate per #891.
- C stays at 1.
- The unconstrained runs are identical or defensibly explained. A change there
  means #891 moved more than the constrained path, and the ADR needs a sentence.

Re-run the decisive case twice on the 0.15.7 arm rather than assuming the
determinism ADR-010 records for 0.15.6 transfers unverified.

Secondary, GUI-equivalent confirmation on a real archived meeting:
`retranscribe <id> --update --speaker-count 1 --json` must return exactly one
`system:*` id plus the protected `microphone` id, i.e. the UI's "Other speakers"
chip reads 1. Confirm the row actually took the meeting branch — see the
measurement trap in §2.

## 6. STT regression pass (ADR-010)

| Upstream change | Path here | Required evidence |
|---|---|---|
| #869 v3 no-mel long-form | `STTRuntime` file and meeting jobs | v3 WER on one >= 30 min and one 5-10 min file; one short file as control |
| #895/#903 streaming seam | live dictation (unified, nemotron) | three 10-30 s utterances per engine; inspect the last ten words for truncation or duplication — a one-word seam defect escapes WER |
| #866/#898/#900 vocabulary biasing | `FluidAudioCustomVocabularyRescorer` | OOV recall and clean-WER delta with boosting on, against the committed baselines in `benchmarks/asr/custom-vocab-phase0/` |
| `ModelNames` additions | `ParakeetUnifiedEngine` required set | `ModelDeletionTests` green **and** the required-set contents inspected: a silently grown set means re-downloads on upgrade |

Harness: `scripts/dev/benchmark_stt_engines.sh <corpus.tsv>`, cold and warm
phases, same machine and corpus on both arms. It defaults `BIN` to the release
binary in `.build`, which the candidate build overwrites, so pass each arm
explicitly and separate their outputs:

```bash
BIN="$BASELINE_CLI" OUT_DIR="$WORK_DIR/bench-0.15.6" scripts/dev/benchmark_stt_engines.sh <corpus.tsv>
BIN="$CANDIDATE_CLI" OUT_DIR="$WORK_DIR/bench-0.15.7" scripts/dev/benchmark_stt_engines.sh <corpus.tsv>
```

Record `avg_wer`, `realtime_factor` and `peak_memory_gb` per engine and
sample. WhisperKit is not FluidAudio-backed and serves only as an unchanged
control.

## 7. Test filters, in order

After the `pipelineRevision` bump:

```bash
swift test --filter DiarizationServiceTests
swift test --filter DiarizationServiceEmbeddingTests
swift test --filter SpeakerVoiceprintMatcherTests
swift test --filter SpeakerParityRegressionTests
swift test --filter MeetingSpeakerPriorTests
```

After the ASR compile:

```bash
swift test --filter CustomVocabularyBoostingTests
swift test --filter ParakeetTDTASRConfigTests
swift test --filter ModelDeletionTests
swift test --filter NemotronEnglishEngineLoadGatingTests
```

CLI surface: `RetranscribeCommandTests`, `STTClientTests`.

Then **one** full `swift test` as the final gate, once the measurements are done
and the working tree is final. Not per iteration: the suite is 4,300+ tests.

## 8. Documentation updates

- `spec/adr/010-speaker-diarization.md:200` states *the app now pins
  `exact: "0.15.6"`*. Add a dated amendment (2026-09-13, issue #1023) in the
  file's existing amendment style: the argmax-versus-retained-cluster census
  divergence, that #891 holds the cap against both censuses, that
  `highAccuracyConfig` is unchanged, that `pipelineRevision` moved and what that
  means for stored exemplars, and the before/after plus WER tables from §5-6
  with machine and toolchain. Close with one paragraph on the ASR-side
  behaviour taken with the bump and what was measured.
- `spec/06-stt-engine.md:650`, `spec/03-architecture.md:298`,
  `spec/02-features.md:1446` — version swap.
- `spec/contracts/speaker-voiceprints.md` — verify unchanged, do not edit. Say so
  in the PR body so a reviewer does not assume the contract rule was skipped.

Commit split (Conventional Commits): one `fix(diarization):` for the pin,
revision and comments; one `docs(diarization):` for the ADR and spec lines.

## 9. Rollback criteria — do not ship if any hold

1. A with `--speaker-count 1` still returns a roster > 1. The bump then does not
   fix #1023 and the issue belongs back upstream.
2. C regresses above 1, or auto-detected counts change on more than one corpus
   item without an explanation — trading one miscount for another.
3. Parakeet v3 long-form `avg_wer` degrades by more than +0.5 points absolute on
   the >= 30 min sample.
4. Streaming dictation shows truncated or duplicated words at the final seam.
5. Custom-vocabulary OOV recall drops below the committed Phase 0 baseline.
6. `Package.resolved` changes beyond the two FluidAudio lines, or `swift test`
   fails anywhere.
7. `ModelDeletionTests` passes only after loosening an assertion.

Criteria 3, 4 and 5 are ASR regressions rather than diarization ones, so a
revert would also drop the #1023 fix. They are still blocking: the release stays
pinned to 0.15.6 until a follow-up PR defines the override, names the ASR path
it overrides, and lands an acceptance test for that path, with an ADR-010 note
recording the split. Which override is needed is not decidable in advance — 3
points at the v3 long-form/no-mel path, 4 at the streaming seam, 5 at the CTC
vocabulary rescorer — so it gets defined when a criterion actually fires, not
here.

## 10. Risks worth holding in view

- The vocabulary and CTC surface is the largest untested behavioural delta in
  this bump. `CustomVocabularyBoostingTests` is mandatory, not optional.
- Local and CI resolve different package manifests (§2), so trait-related
  breakage appears only in CI.
- CI runs on `macos-14`, the OS targeted by the new upstream BNNS warning and
  the OS whose ANE non-reentrancy `ANEInferenceGate` exists for. Upstream #886
  propagates cancellation into diarizer workers; a worker that does not release
  cleanly would present as a CI hang, not a failure. Watch the 20-minute
  `Swift Test` timeout on the first CI run.
