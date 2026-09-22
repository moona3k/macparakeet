# Speaker attribution for MacParakeet: synthesis and recommendation

Date: 2026-09-06. Orchestrator synthesis of four delegated reports (Anarlog and peers,
MacParakeet baseline, frontier models, production practices). Research only; no code changed.

## Verdict

The model is not the problem. Keep FluidAudio's pyannote community-1 pipeline and fix what
surrounds it. The highest recommendation, in order:

1. **Upgrade FluidAudio from 0.15.4 to 0.15.6 or later and run the async path at the
   high-accuracy settings.** The pinned 0.15.4 clustering stage has three porting defects and
   one source of non-determinism, all fixed upstream in 0.15.5 (2026-07-07) and 0.15.6
   (2026-08-19). MacParakeet ships every one of them today. Verified in the pinned checkout:
   - The AHC threshold is converted with `sqrt(2 - 2t)` although the config documents it as a
     distance, so the community-1 default 0.6 runs as a dendrogram cut of 0.894
     (`AHCClustering.swift:107-115`). Raising the knob splits more instead of merging more.
   - Speaker-count constraints are compared against the AHC warm-start count instead of the
     clusters VBx kept, which routes exact/min constraints into K-Means re-clustering even when
     the automatic path was right (`VBxClustering.swift:685-711`).
   - There is no constrained assignment of local speakers that share a segmentation chunk, so one
     speaker's turns can be absorbed into another's.
   - The K-Means fallback seeds from `UInt64.random` (`KMeansClustering.swift:64`); the upstream
     reporter measured 10.9% versus 32.0% speaker confusion on the same clip from the seed alone.
   Because diarization is async, also switch from `OfflineDiarizerConfig.default` to
   `stepRatio 0.1`, `minSegmentDurationSeconds 0`, zero-vote re-embed on. FluidAudio measures
   that at 1.2 DER points better (VoxConverse, collar 0.25, overlap ignored) for half the
   throughput, which the async path can afford.
2. **Feed the priors MacParakeet already holds into clustering.** Today the meeting finalizer
   diarizes the raw system track with no count, and the calendar attendee snapshot never reaches
   the diarizer. Copy Anarlog's `plan_channel` rules: system track gets bounds derived from the
   participant count minus the user (as a range, never an exact count), a 1:1 call skips
   clustering entirely, and an in-person meeting (two or more expected participants but the
   system track carried almost no speech) diarizes the microphone track instead of labelling
   every mic word "Me". FluidAudio's `withSpeakers(min:max:)` and the finalizer's access to both
   source WAVs make this a small change.
3. **Add engine-agnostic post-passes around the labels.** In priority order:
   - Consolidate over-split clusters by embedding each label's clean spans and merging labels
     that exceed the expected cap or match the same voice (Anarlog's `consolidate.rs`, using the
     WeSpeaker embeddings FluidAudio already exposes).
   - In `SpeakerMerger`, give nil-speaker and sub-second words a defined nearest-turn fallback,
     smooth one-word speaker flips, and snap word boundaries to segment boundaries.
   - Make speaker IDs stable across re-runs and carry user renames over (centroid match or time
     overlap); today every re-run discards corrections.
   - Rename propagates to all turns of that speaker by default.
   - Compute a per-turn confidence proxy from cluster margin and turn length and surface only
     low-confidence turns for review.
4. **Measure before and after.** Build the small harness first: 10 to 20 retained post-AEC
   meeting system tracks with hand-corrected labels, plus FluidAudio's `diarization-benchmark`
   CLI on AMI SDM and VoxConverse scored under both protocols. Arms: 0.15.4 as shipped, 0.15.6
   defaults, 0.15.6 high-accuracy, and Argmax SpeakerKit as an independent community-1 reference.
   Keep DER, speaker-count error, word-level attribution error, and correction count separate.

Steps 1 and 2 are cheap and well evidenced; do them under a flag and confirm on the harness.
Step 3 is where Anarlog's actual advantage lives. Step 4 is what turns "not the best" into a
number.

## How Anarlog handles speaker separation

Anarlog does not have a better diarizer. It has a more complete attribution system around a
comparable or older model, almost all of it landed between 2026-08-11 and 2026-09-05.

- Live transcript: no diarization. Mic channel renders as "You", system channel as one unnamed
  speaker. A 1:1 session assigns the single remote participant from the calendar without audio
  analysis.
- Post-stop refinement runs only when the session lists at least two other participants and the
  632 MB Parakeet Batch model is downloaded. A user who records without a participant list keeps
  "You" and "Speaker 1" permanently. Most default local users therefore never get diarization.
- When it runs: Soniqo's community-1 CoreML pipeline with an exact count, only for recordings
  under ten minutes per channel. Otherwise Anarlog's own `pyannote-local` Rust crate, which
  re-implements the pyannote 3.1 recipe (segmentation-3.0 plus WeSpeaker ResNet34 via ONNX
  Runtime with a CoreML provider, agglomerative clustering cut at 0.7045, 12 s minimum cluster).
  That is an older recipe than MacParakeet's community-1 plus VBx.
- Its reported numbers (DER 1.8% to 4.7%) are agreement with pyannote.ai precision-2 on two
  in-repo clips, not accuracy against human references.
- What it does well: channel layout as a speaker prior with in-person detection, participant
  count as a clustering bound, embedding-based consolidation of over-split labels, on-device
  voiceprints that steer clustering and name clusters conservatively (mutual best match, 0.62
  floor, 0.08 margin, 45-day expiry, keychain storage), and a correction UI whose every manual
  assignment enrolls a voiceprint. Provider labels, automatic assignment, and user assignment are
  separate overlay layers with fixed precedence, so re-diarization never loses edits.

Peers: Muesli runs FluidAudio's legacy streaming diarizer on system audio only. Vibe runs
Sortformer with a hard four-speaker limit. Meetily has no diarization despite marketing it.
OpenWhispr and Minutes ship sherpa-onnx or pyannote-rs with segmentation-3.0 and CAM++
embeddings plus voice profiles. None runs a newer open model than MacParakeet.

## What MacParakeet does today

One diarizer configuration and no post-processing. `DiarizationService` starts from
`OfflineDiarizerConfig.default` and applies only an optional speaker-count constraint that the
app never passes for meetings. The meeting pipeline diarizes only the raw system track, treats
every microphone word as "Me", and never diarizes the mixed track. That architecture is sound
and is exactly what AssemblyAI, Deepgram, Teams, and Zoom document as the accurate path. Quality
is lost downstream: turns under 1.0 s of clean speech get no segment, the speaker count is a
single unguarded cosine cut, word attribution is a raw overlap vote, renames do not survive
re-runs, and there is no accuracy harness.

## What the frontier offers and why it is not the first move

- pyannote community-1 (CC-BY-4.0) remains the best open, commercially usable offline model.
  Nothing has displaced it since September 2025. precision-2 is cloud only.
- NVIDIA Nemotron-3 Diarization (8-speaker Sortformer) has a FluidAudio CoreML port in an open
  PR with a reported AMI DER around 9.3, but the license is evaluation-only with no
  redistribution. Track it; adopt after a general release under an open license.
- DiariZen is CC BY-NC. Public Sortformer models cap at four speakers. Apple's SpeechAnalyzer on
  macOS 26 exposes no speaker output. sherpa-onnx uses the older segmentation-3.0 model.
- Argmax SpeakerKit (MIT package) runs community-1 with pyannote-parity clustering and publishes
  results under a stated protocol. Useful as the reference arm of an A/B; its model repo declares
  no license, so it is not a drop-in ship candidate.
- LLM post-correction of speaker boundaries (DiarizationLM lineage) only helps with domain
  fine-tuning on telephone corpora; zero-shot degrades. Use an LLM to suggest names at most,
  never to merge or split speakers.

## Production patterns worth adopting

Every reliable product combines a non-acoustic identity source (channel or participant stream),
a caller-supplied speaker-count prior as bounds, word-level assignment against an exclusive
timeline with a nearest fallback, per-turn confidence that drives review, and explicit,
revocable enrollment. MacParakeet already has the first. Anti-patterns to avoid: mixing mic and
system audio before diarization, forcing an exact count, per-paragraph renames that do not
propagate, silent enrollment, and live labels the final pass contradicts.

## Stale claims to amend in ADR-010

- "Same pipeline pyannote's commercial API uses, minus proprietary tuning": unsupported.
  precision-2 is a distinct model, 4 to 10 DER points better on the model card table.
- "~15% VoxConverse, ~17.7% AMI": FluidAudio's AMI table was produced under the inverted
  threshold semantics and is flagged for re-benchmark by its maintainers.
- "Speaker detection ~85% accurate" in Settings copy is not derivable from any DER figure.
- The offline pipeline was not a faithful community-1 port in 0.15.4.

## Risks and uncertainty

- The DER gain from the upgrade on MacParakeet's own meeting audio is unmeasured. FluidAudio has
  not republished its AMI table under the new semantics.
- FluidAudio also owns the STT engines, so the upgrade needs the STT regression pass, and the
  `exact:` pin in Package.swift was deliberate. Issue #878 reports a deterministic offline
  diarizer crash on macOS 14 in current versions; guard it if macOS 14 stays supported.
- Issue #879 argues VBx still lacks an HMM transition prior, so rapid turn-taking may stay weak
  after the upgrade. The short-turn losses in the baseline audit are a separate fix in
  `SpeakerMerger` and in the minimum-segment setting.
- In-person detection can misfire on a call where the far end stayed silent.
- Anarlog's voiceprint thresholds were tuned on WeSpeaker ResNet34 ONNX embeddings; the policy
  transfers, the constants do not. The July Phase 0b calibration remains the local reference.
- Every benchmark number in these reports is an attributed report; none was reproduced here.

## Reports

- [anarlog-and-peers.md](anarlog-and-peers.md): Anarlog's speaker path traced from source, peer matrix.
- [macparakeet-baseline.md](macparakeet-baseline.md): current pipeline, ranked losses, insertion seams, evaluation needs.
- [frontier.md](frontier.md): models, Apple Silicon ports, benchmark table, FluidAudio defect evidence, A/B design.
- [production-practices.md](production-practices.md): documented vendor mechanisms, patterns, anti-patterns.
