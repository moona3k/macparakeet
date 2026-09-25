# Nemotron 3 diarization: matched evaluation and integration

Date: 2026-09-25. Related: [#1046](https://github.com/moona3k/macparakeet/issues/1046),
[research](../../docs/research/2026-09-25-nemotron-diarization-evaluation.md),
[Omarchy review](../../docs/research/2026-09-25-omarchy-meeting-recorder-diarization-review.md),
[implementation decision](../../spec/adr/010-speaker-diarization.md#nemotron-default-decision-2026-09-25).

## Decision

Evaluation in progress. The authorized candidate is Nemotron 3 `fast128` for
automatic diarization through FluidAudio 0.17.4. Complete corpus scores and the
final verification receipt will replace this paragraph before the PR opens.

## What changes

- Automatic file/URL and saved system-audio diarization use Nemotron. The
  microphone remains **Me**; it consumes none of Nemotron's eight speaker slots.
- Exact/Range choices, including counts above eight, retain Community-1. The
  experimental voice-profile gate also retains its WeSpeaker embeddings.
- Calendar bounds accept a natural Nemotron count within the bound; otherwise
  they try constrained Community-1. An unavailable advisory fallback preserves
  successful Nemotron attribution. Explicit constraints retain their failure
  behavior. Cancellation is never converted into success.
- Model setup prepares both backends so explicit count choices work offline.
  Readiness covers both, and `models clear` clears both speaker caches. Upgrading
  an old unmarked Community-1 cache requires one connected setup because the new
  SDK pins its model revision. Audio inference remains local.
- ASR selection, live transcription, capture, source reconciliation, word
  timestamps, smoothing, user corrections and persistence schemas are unchanged.
  Overlapping acoustic intervals are retained by the new service, but a word
  still receives one speaker label in the existing merger.

The default weights are approximately 199 MB, plus the existing compatibility
models. The optional `offline` preset is an evaluation arm, not another setting.
No new ML runtime is introduced. The final model uses OpenMDW-1.1; the app bundle
includes attribution and the full license. FluidAudio uses Apache-2.0.

## Experiment

All recordings were public data, processed locally outside the user's library.
Each backend received the same WAV bytes, checked by SHA-256. Thresholds were
not tuned against test results. `fast128` was selected as the candidate before
the corpus run from the upstream speed/count evidence; `offline` remained a
comparison arm. The initial plan's numerical acceptance margins were not
preregistered. This is an engineering adoption decision under the user's
“prefer Nemotron unless testing finds a red flag” instruction, not a statistical
non-inferiority trial.

| Item | Frozen configuration |
| --- | --- |
| Original baseline | FluidAudio 0.15.7, `41540ea237350afe5117a082b5c28eda642d0612`; app configuration at `7ad569afae560266b37a0003e9e2b9f17a2dfa47` |
| Candidate SDK | FluidAudio 0.17.4, `21493f8dac5a97e65742e6ff26f42f164c2fda0f` |
| Nemotron CoreML export | `1b0b133f6f8820292010afd776d8f9fbc9fca17e`; five asset hashes per preset checked before model loading |
| Baseline configuration | Step ratio 0.1, embedding minimum duration 0, zero-vote re-embedding enabled, default clustering threshold, automatic count, exclusive intervals |
| Nemotron configuration | `fast128` / `offline`, threshold 0.5, 10 ms output frames, minimum segment duration 0, one-second audio feeds, original timebase |
| Scoring | dscore `e02f949ac6592279300a2c33d03daf9e0c12fd27` / NIST `md-eval-22.pl`; zero collar, overlap included, original explicit UEM |
| Hardware | M4 Pro, 14 cores, 48 GiB RAM; macOS 26.6.2 (25G83); Swift 6.3.1 |
| Compute | Community-1 `.all` with FBank CPU; Nemotron `fast128` `.all`; `offline` CPU/GPU |

The original baseline is a separate release executable pinned to the old SDK,
not the upgraded SDK's Community-1 path. Its output records every required
model-file hash. All 21 required Community-1 asset files matched the upgraded
cache byte for byte. A 17.5-minute upgrade control produced identical acoustic
segments on 0.15.7 and 0.17.4; that single control is not proof of equivalence on
all recordings.

AMI uses all 16 test meetings, separately on the official mixed headset and
true distant microphone. Both backends are scored first against the pinned
manual `only_words` references and then against the pinned forced-alignment
references, without rerunning inference. AliMeeting uses all 20 official Test
meetings, with far channel one and a fixed 1/N mean of all near headsets.
Shorter headset tails contribute silence; automatic gain changes are disabled.
The acquisition test caught the fact that near TextGrid tiers all use `c1`:
near identities come from participant filenames, not that shared tier label.

Together these are 36 meetings and 72 microphone signals. Conditions share
meetings and cannot be treated as 72 independent examples. Four AMI distant
recordings have tiny tails beyond their original UEM; those tails remain in the
audio and outside scoring. Missing inputs/predictions abort the run. Empty
predictions remain scored as misses. The scorer's behavior was checked with
permuted identities, overlap, silence/false alarms, empty hypotheses and UEM
boundaries.

AMI forced references contain substantially less labeled activity than manual
references. They therefore answer a different timing question. NVIDIA's
published numbers use forced alignment on meeting corpora; neither our manual
score nor a forced score from a different scorer is a direct reproduction of
its table. AliMeeting here uses original official TextGrids. VoxConverse is
used only for regression: NVIDIA discloses training on both its development and
test sets. These results do not prove generalization across every domain.

## Acoustic results

DER is the sum of missed speech, false alarms and speaker confusion, divided
by reference speaker-time. Lower is better. Values below are weighted over
each complete microphone condition, not averages of per-recording percentages.

| Corpus / reference / microphone | Community-1 0.15.7 DER | Nemotron fast128 DER | Nemotron offline DER |
| --- | ---: | ---: | ---: |
| AMI manual / mixed headset | 23.18% | 26.00% | 25.98% |
| AMI manual / distant | 25.18% | 27.55% | 27.28% |
| AMI forced / mixed headset | 37.96% | 9.31% | 9.25% |
| AMI forced / distant | 38.66% | 11.35% | 11.15% |

AMI presents a real tradeoff. On manual mixed-headset labels, fast128 reduces
speaker confusion from **3.46% to 0.73%**, but increases missed activity from
**17.24% to 24.07%**. Its total DER is 2.82 percentage points worse. The distant
condition also worsens, by 2.37 points. Broad manually marked turns include
pauses that a frame-level detector omits, but some missed regions contain audible
activity; annotation convention does not explain away every miss.

Against forced alignment on the same audio, fast128 improves all 16 meetings
in each condition. Mixed-headset misses fall from 10.82% to 4.72%, false alarms
from 20.23% to 3.71%, and confusion from 6.92% to 0.89%. These are different
references: 23,930.54 labeled speaker-seconds versus 30,713.92 for manual AMI,
22.09% less activity. A reference convention can reverse the headline ranking.

| Exact speaker count / AMI condition | Community-1 0.15.7 | fast128 | offline |
| --- | ---: | ---: | ---: |
| Mixed headset, 16 meetings | 75.0% | 100.0% | 87.5% |
| Distant, 16 meetings | 68.75% | 87.5% | 87.5% |

Paired uncertainty is reported in the result receipt. A 10,000-draw bootstrap
resamples AMI's four session families, keeping related meetings together and
microphone conditions separate. The 95% percentile interval for the fast128
minus baseline DER difference is [-0.95, +9.31] points on manual mixed headset
and [-34.36, -22.00] on forced mixed headset. Four groups provide limited
uncertainty resolution; neither interval is a preregistered acceptance test.

AliMeeting results and supplementary activity diagnostics follow when complete.

## Product E2E and ASR control

The opt-in native test used 180 seconds from public AMI ES2004a mixed-headset
audio, starting at 50 seconds, and one public LibriSpeech microphone clip.
It encoded real source files, used real Parakeet v3 and Nemotron inference,
finalized a source-separated meeting with a 500 ms system offset, saved and
reopened a temporary database, checked meeting artifacts, transcribed the file,
and reused the model on silence. Only the system source was diarized.

Observed: all **16 microphone words remained Me**; 256 of 258 system words
received a remote identity, while two retained the **Others** source fallback.
Three remote identities were retained. A subsequent silent input returned zero
speakers, demonstrating that a previous meeting did not leak stream state.
This is real audio through the finalization/persistence code, not a physical
ScreenCaptureKit, microphone, Bluetooth, echo-cancellation or GUI capture test.

A separate product projection passed the same 258 ASR words and the same decoded
system WAV through both diarizers and the existing `SpeakerMerger`. Community-1
on 0.17.4 returned one speaker, with 5 initially unlabeled words; Nemotron
returned three, with 17 initially unlabeled words. The file merger filled those
nil assignments in both arms. No non-nil singleton assignment changed in this
excerpt. The test asserts that text, confidence, timestamps and ordering survive
projection. Coverage is not label accuracy: this sample is not a manually
scored speaker-aware WER benchmark, and existing smoothing can still erase a
real isolated reply in other recordings.

| Parakeet v3 SDK regression control | Files | Word errors / reference words | WER |
| --- | ---: | ---: | ---: |
| Preserved 0.15.7 CLI | 200 | 89 / 3,992 | 2.2295% |
| Candidate 0.17.4 CLI | 200 | 88 / 3,992 | 2.2044% |

The candidate restored one missing final word; the other 199 hypotheses matched.
The rerun baseline reproduced all 200 historical hypotheses. Both arms used
identical LibriSpeech `test-clean` IDs/references and the existing simple
normalizer. Temporary databases retained zero history rows. All 23 corresponding
Parakeet cache files matched. The historical executable's SDK version is
corroborated by its embedded revision and prior report, but no contemporaneous
binary-hash-to-lockfile receipt exists. These WER results cover batch v3 clean
English, not every engine, live streaming seam, vocabulary boosting or language.
Build modes differ, so ASR timings are not compared.

## Runtime, boundaries and verification

Pending completed corpus runtime tables, supplemental CLI/count tests and final suite.

Preparation and inference timings are separate. Backend processes ran
sequentially, but this shared development Mac also ran builds and other work;
wall times are indicative. Peak RSS is a process high-water mark, not total
system/accelerator memory or energy. The native decoder materializes the input
before feeding one-second chunks. Inference cancellation is checked between
feeds; decode-time cancellation and memory are not bounded for arbitrary-length
files. The measured meeting durations do not qualify multi-hour capture on a
lower-memory Mac.

Review addressed advisory-fallback failure, compatibility-model readiness,
revision-marker readiness, pinned PLDA repair and complete speaker-cache clearing.
Experimental profile routing has a deterministic regression test. `no-mistakes`
is not installed here; the documented local/independent review workflow applies.

## Reproduce and continue

Use the [benchmark README](README.md), committed manifests, isolated
[0.15.7 baseline package](Baseline/README.md), and opt-in
[Nemotron E2E test](../../Tests/MacParakeetTests/Services/Diarization/NemotronDiarizationE2ETests.swift).
Large audio, raw predictions and scorer artifacts remain outside Git; the small
results/provenance receipt accompanies this report.

Remaining qualification includes physical capture/echo routes, macOS 14 and M3
hardware, other ASR engines, and longer low-memory recordings. A future change
to smoothing should compare real short replies independently of the diarizer.
The planned audio-speaker timeline remains unimplemented; this upgrade does not
add a new persisted overlap timeline or shared-microphone mode. The PR is a
development change, not a stable release or proof that every attribution error
in #1046 is solved.
