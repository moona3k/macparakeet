---
title: Current diarization models and Apple Silicon tooling (frontier survey)
status: RESEARCH
date: 2026-09-06
author: Claude (frontier research agent)
---

# Current diarization models and Apple Silicon tooling

Observation date: 2026-09-06 for every web source unless noted. Companion to
`briefs/frontier.md` and `briefs/shared.md`. Evidence excerpts are under
`evidence/frontier-*`. Numbers are attributed reports; conditions are recorded as
stated by the source and marked "unknown" when the source does not state them.

## 1. Verdict

The strongest offline diarization models with open weights are still the pyannote
community-1 family (CC-BY-4.0) and DiariZen (CC BY-NC 4.0, not shippable). Nothing
newer with open, commercial-use weights has displaced community-1 since September
2025. The frontier that matters for MacParakeet moved in two other places:

1. The pinned FluidAudio 0.15.4 offline pipeline carries three confirmed porting
   defects in its clustering stage (inverted AHC threshold, wrong speaker-count
   comparison, missing constrained assignment) plus a non-deterministic K-Means
   fallback. FluidAudio fixed all four in v0.15.5 (2026-07-07) and v0.15.6
   (2026-08-19). MacParakeet ships every one of them today. This is the most likely
   concrete cause of "results are not the best" and the cheapest fix.
2. NVIDIA's Nemotron-3 Diarization preview (8-speaker Sortformer, offline preset)
   has a FluidAudio CoreML port with a reported AMI DER around 9.3, but its license
   is evaluation-only, GPU-only, and no-redistribution until a general release.
   It is the highest-upside successor and is not shippable today.

Ranked shortlist for the async post-processing path: (1) upgrade FluidAudio to
0.15.6 or later and switch the async path to the high-accuracy segmentation
settings; (2) A/B an independent community-1 CoreML port (Argmax SpeakerKit, MIT)
that keeps the embedding model at fp32/W16 and clusters with pyannote parity;
(3) track Nemotron-3 Diarization through FluidAudio PR #883 and adopt it when the
license permits production use. Details and the A/B design are in section 3.

## 2. Findings

### 2.1 pyannote: community-1, precision-2, pyannote.audio 4.x

- pyannote.audio 4.0 shipped 2025-09-29 with `speaker-diarization-community-1`
  (CC-BY-4.0, open weights, gated download) and the API-only `precision-2`.
  Releases since: 4.0.4 (2026-02-07), 4.0.5 (2026-06-22), 4.0.6 (2026-06-29),
  4.0.7 (2026-06-30). The CHANGELOG for those versions lists fixes and tooling
  only; no new pretrained pipeline. The pyannote Hugging Face org lists nothing
  newer than community-1 (2025-09-29) and precision-2 (2025-09-16).
- Community-1 pipeline: powerset segmentation (Plaquet and Bredin 2023), WeSpeaker
  embeddings, VBx clustering (Landini et al. 2022), plus an "exclusive" output that
  keeps one speaker active per frame for word alignment.
- Model-card DER, "fully automatic processing, no forgiveness collar, nor skipping
  overlapping speech": AMI SDM 19.9 (3.1: 22.7; precision-2: 15.6), VoxConverse
  11.2 (11.2; 8.5), DIHARD 3 20.2 (21.4; 14.7), CALLHOME 26.7 (28.5; 16.6).
- precision-2 adds voiceprint identification (enrollment from up to 30 s of clean
  audio), per-segment confidence, and exclusive mode. pyannote's 2026-09-03 tutorial
  recommends starting at a matching threshold of 50/100 and tuning by observed
  false-unknown vs wrong-name outcomes; it publishes no accuracy figure.
- Python only. Not an app dependency for MacParakeet (unchanged from the June doc).

### 2.2 FluidAudio: latest (v0.15.6, 2026-08-19) vs pinned 0.15.4 (2026-06-16)

Diarization changes after the pin, from release notes and PR bodies
(`evidence/frontier-fluidaudio-releases.md`, `evidence/frontier-fluidaudio-prs.md`):

| Version | Change | Why it matters |
|---|---|---|
| v0.15.5 | PR #735: deterministic VBx re-clustering (seeded K-Means, n_init 10) | Reporter measured 10.9% vs 32.0% speaker confusion on identical audio depending only on the random seed when a speaker-count constraint triggers re-clustering. |
| v0.15.5 | Re-embed zero-vote spans instead of cluster-0 tie-break; `computeUnits` honored; progress handler; Sortformer v3 CoreML models; LS-EEND enrollment fixes | Zero-vote fix is opt-in (`ZeroVoteReembed.disabled` default). |
| v0.15.6 | PR #802: "pyannote-parity clustering" | Three porting bugs, see below. |
| v0.15.6 | PR #789: `process()` split into `prepare()`/`cluster()` | Segmentation and embeddings become cacheable; re-clustering with a new speaker count or threshold is cheap. |
| v0.15.6 | PR #652: CAM++ speaker-embedding backend (beta), `FluidInference/campplus-coreml` | Alternative 192-d embedder (AISHELL-1 EER 0.48%). Not wired into `OfflineDiarizerConfig` on main; no diarization DER published with it. |

PR #802 (merged 2026-08-19, fixes issue #801) documents, and I confirmed in the pinned
checkout (`evidence/frontier-pinned-0.15.4-clustering-defects.md`):

1. The AHC threshold was treated as a cosine similarity and converted with
   `sqrt(2 - 2t)` before the dendrogram cut, while pyannote applies it directly as a
   distance. The community-1 default 0.6 therefore behaved as a cut at 0.894, and
   raising the knob split more instead of merging more.
2. Speaker-count constraints were compared against the AHC warm-start count rather
   than the clusters VBx actually kept, so `numSpeakers`/`minSpeakers` routinely
   diverted into K-Means re-clustering even when the automatic path had the right
   count. The reporter's 2-speaker clip went from 69% to 92% correctly attributed
   speech depending only on that path.
3. Local speakers that share a segmentation chunk were not forced into distinct
   clusters (pyannote's `constrained_argmax`), which lets one speaker's turns be
   absorbed into another's.

FluidAudio's maintainers state that the AMI-SDM offline table "predates #801 and
uses `--threshold 0.7` under the old (inverted) threshold semantics" and should be
re-benchmarked. Open issues after the fix: #879 (2026-08-29) argues VBx still lacks
an HMM transition prior, so rapid turn-taking merges short turns and Fa/Fb cannot
compensate; #878 (2026-08-28) is a deterministic BNNS crash of the offline diarizer on
macOS 14 only. PR #883 (open, 2026-09-04) adds Nemotron-3 Diarization (8-speaker
Sortformer) as code-only, with weights deferred to NVIDIA's public release.

Reported numbers in the pinned documentation (`Documentation/Benchmarks.md` at
b9d43724): VoxConverse, collar 0.25 s, overlap ignored, 232 clips: 15.07% average
DER at the shipped defaults (stepRatio 0.2, minSegmentDuration 1.0 s, RTFx 122) and
13.89% at stepRatio 0.1 / minSegmentDuration 0 (RTFx 65); the PyTorch reference is
"~11%" and the gap is attributed to fp16 on the Neural Engine. AMI SDM 16-meeting
test set: 10.6% average DER, 12/16 correct speaker counts, RTFx about 70; collar and
overlap handling are not stated for that table. MacParakeet's `DiarizationService`
starts from `OfflineDiarizerConfig.default`, so the shipped app runs the faster,
less accurate setting even in the async path.

### 2.3 NVIDIA NeMo: Sortformer, Nemotron-3 Diarization, cascaded diarizer

- `diar_sortformer_4spk-v1` (offline, 2024-09): CC-BY-NC-4.0, so not shippable.
  DIHARD3-Eval (<=4 spk, collar 0, overlap scored) 14.76; CALLHOME 2/3/4 spk (collar
  0.25) 5.85/8.46/12.59.
- `diar_streaming_sortformer_4spk-v2.1` (last modified 2025-12-31): NVIDIA Open Model
  License; 4 speakers max, "performance degrades on recordings with 5 and more
  speakers"; 1.04 s latency config DIHARD III <=4 spk 15.09, AMI IHM 16.67, CALLHOME
  2 spk 6.65 (collar 0 except CALLHOME/CH109 at 0.25; overlap scored). A 30.4 s
  "very high latency" config approximates offline use. CoreML ports exist from
  FluidInference, aufklarer, and others; FluidAudio measures 31.7% on AMI SDM with the
  high-latency config, and the 2509.26177 benchmark notes Sortformer's errors are
  dominated by speaker confusion rather than missed speech.
- `nvidia/Nemotron-3-Diarization-preview` (created 2026-08-24, modified 2026-09-05,
  gated): the FluidInference CoreML card describes it as a 31-layer RoPE Transformer,
  100M parameters, 8 speakers, 10 ms output, streaming and offline presets, with AMI
  test DER 9.28 (offline preset) against NVIDIA's 9.30 reference and about 1000x
  real time on an M5 Pro. License is the "NVIDIA Software and Model Evaluation
  License": internal testing only, no production use, NVIDIA GPUs only, no
  redistribution. Protocol for the 9.28 figure is not visible without gated access.
- Cascaded NeMo diarizer (MarbleNet VAD + TitaNet embeddings + spectral clustering,
  with MSDD refinement) remains documented but has no reported gains over
  community-1 and no CoreML port; `.nemo` checkpoints only.
- `multitalker-parakeet-streaming-0.6b-v1` consumes Sortformer speaker activity and
  reports cpWER 21.26 (AMI IHM) and 37.44 (AMI SDM); `.nemo` only.

### 2.4 DiariZen and WavLM-based segmentation

- DiariZen (BUT) pairs a structurally pruned WavLM-Large + Conformer powerset
  segmenter with VBx. Latest model `diarizen-wavlm-large-s80-md-v2` (2025-12-09,
  card touched 2026-08-31; 63.3M params after 80% pruning). DER "without applying a
  collar": AMI-SDM 13.9, AISHELL-4 10.1, AliMeeting far 10.8, DIHARD3 14.5,
  VoxConverse 9.1. The independent 2509.26177 benchmark (collar 0.25, overlap scored)
  averages DiariZen at 13.3 vs pyannoteAI at 11.2 across four datasets, at about 20x
  real time on GPU.
- Weights are CC BY-NC 4.0; the April 2026 tutorial paper explains the restriction
  is inherited from RAMC, MSDWild, and DIHARD-3 training data. Code is MIT. No CoreML
  conversion exists on Hugging Face; community ONNX and MLX repos do. Not shippable
  in MacParakeet; useful as the open-weights accuracy ceiling in a research harness.

### 2.5 Apple Silicon ports: sherpa-onnx, senko, MLX, Argmax SpeakerKit, speech-swift, Apple SpeechAnalyzer

- sherpa-onnx: pyannote segmentation-3.0 (not community-1) plus 3D-Speaker or NeMo
  embeddings, C API with Swift examples (`speaker-diarization.swift`). No accuracy
  numbers published. Older segmentation model than what MacParakeet already runs.
- senko (MIT, Python, 3D-Speaker lineage): pyannote segmentation-3.0 or Silero VAD,
  CAM++ embeddings via CoreML on Mac, spectral or UMAP+HDBSCAN clustering. On the
  OpenBench protocol (collar 0, overlap scored) an M3 scores AMI-SDM 32.8, VoxConverse
  13.9, AISHELL-4 13.6, at 275x to 393x real time. Fast, but worse than community-1
  on meetings, and Python.
- MLX: `mlx-community/pyannote-segmentation-3.0-mlx` and aufklarer's segmentation
  ports exist; no full MLX community-1 pipeline with published DER was found.
- Argmax SpeakerKit (part of `argmax-oss-swift`, MIT; SpeakerKit introduced
  v0.17.0 on 2026-03-13, v1.1.0 on 2026-08-06 exposes speaker centroid embeddings):
  "runs Pyannote v4 (community-1) on Apple silicon", macOS 13+, models from
  `argmaxinc/speakerkit-coreml` (pyannote-v3 WeSpeaker embedder at W16A16/W8A16 and a
  pyannote-v4 PLDA projector; the HF repo declares no license). OpenBench (collar 0,
  overlap scored, M2 Ultra, run 2025-09-29): AMI-SDM 0.21, VoxConverse 0.11,
  DIHARD-III 0.22, CALLHOME 0.30, AISHELL-4 0.12, with 69% speaker-count accuracy on
  AMI-SDM versus 6% for pyannote 3.1. The "Real-time transcription with speakers"
  feature is Pro-only; batch diarization is in the MIT package.
- soniqo/speech-swift (Apache 2.0, macOS 15+, MLX + CoreML): community-1 with
  FP32 CoreML segmentation/embeddings and native VBx, Sortformer v2.1, an 8-speaker
  "Ultra-Sortformer" fine-tune (Apache-2.0, no corpus numbers), ReDimNet2 identity
  embeddings, and MOSS Transcribe Diarize. Its published accuracy is a parity check on
  a 1,057 s VoxConverse subset (4.66% DER, collar 0.25, overlap included) and is
  explicitly "not a dataset-wide quality claim".
- Apple SpeechAnalyzer / SpeechTranscriber (macOS 26): the documentation JSON
  exposes no speaker attribute, option, or result. No diarization.

### 2.6 Joint ASR + diarization

- MOSS-Transcribe-Diarize 0.9B (OpenMOSS, Apache-2.0, open-sourced 2026-07-09):
  end-to-end speaker-attributed, time-stamped transcription, up to 90 min, 50+
  languages, MLC-SLM 2026 winner. Reports CER/cpCER (AISHELL-4 14.84/15.83, AliMeeting
  24.86/22.17), not DER. Runs in speech-swift (CoreML/MLX) and MLX. English WER
  against Parakeet is unreported, and speaker labels are "relative labels within the
  input audio".
- VibeVoice-ASR 9B (Microsoft, MIT, 2026-01-21): DER/cpWER AMI-SDM 13.43/28.82,
  AMI-IHM 11.92/20.41, AISHELL-4 6.77/24.99; conditions unstated; 60 min max; sized
  for NVIDIA containers. Not practical as a default on consumer Macs.
- DiCoW / TS-ASR-Whisper (BUT, 2025-2026): Whisper conditioned on diarization
  masks for target-speaker ASR; needs an upstream diarizer and PyTorch.
- WhisperX: still community-1 plus word assignment; README repeats "Diarization is
  far from perfect" and "Overlapping speech is not handled particularly well".
- Voxtral Transcribe 2 (2026-02-04): diarization only in the API batch model; the
  Apache-2.0 Realtime 4B model has none.
- TagSpeech (2026-01), DM-ASR (2026-04), SpeakerLM (2025-08): paper-only or
  GPU-scale LLM systems; no Apple Silicon path.

### 2.7 Text and LLM post-correction

- DiarizationLM (Google, 2024): fine-tuned PaLM 2-S cut WDER by 55.5% (Fisher) and
  44.9% (Callhome) relative. The open `DiarizationLM-8b-Fisher-v2` (Llama-3-8B,
  llama3 license) moves Fisher WDER 5.32 to 3.28 and Callhome 7.72 to 6.66; it needs a
  CUDA GPU per its card and is trained on English telephone speech.
- SEAL (Amazon, 2025-01): acoustic-confidence tokens plus constrained decoding on a
  fine-tuned LLM, 24% to 43% speaker error reduction on Fisher/Callhome/RT03.
- Efstathiadis et al. (Speech Communication 2025): fine-tuned correctors are
  "constrained to transcripts produced using the same ASR tool"; a weight-merged
  ensemble generalizes better.
- SpeakerLM (2025-08) reports that zero-shot Qwen2.5-7B-Instruct and ChatGPT-4.5
  "perform poorly ... even degrading overall performance due to LLM hallucination".
- Net: every positive result uses a fine-tuned model with constrained decoding, on
  two-speaker telephone data. No evidence supports a small local zero-shot LLM
  fixing speaker boundaries, and no fine-tuned meeting-domain corrector with open
  weights was found.

### 2.8 Overlap-aware approaches and two-channel priors

- Overlap: community-1 powerset segmentation models up to three simultaneous
  speakers per frame; DiariZen v2 up to four; Sortformer/LS-EEND output per-slot
  activity natively. All exclusive/word-alignment modes collapse overlap to one
  speaker on purpose. Precision-2's gains over community-1 are largest on
  overlap-heavy sets (AliMeeting 20.3 to 15.2, CALLHOME 26.7 to 16.6).
- Target-speaker methods: TS-VAD and Personal VAD condition on enrolled embeddings,
  and pyannote sells exactly that as voiceprint identification. FluidAudio exposes
  enrollment only on LS-EEND (documented as less reliable than embedding matching)
  and centroid embeddings on the offline pipeline (`embeddingsPath`, per-chunk
  embeddings since v0.14.8); Argmax exposes centroid embeddings since v1.1.0.
- Two-channel prior: no paper or product doc evidences using a known "self" channel
  to constrain a far-end diarizer beyond the industry rule that channel identity
  outranks diarization (Deepgram, AWS multichannel docs cited in the June doc).
  The evidenced building block is the same embedding-matching step: extract a "Me"
  centroid from the microphone track, then flag any system-track cluster whose
  centroid matches it as residual echo rather than a new participant.

### 2.9 Comparable benchmark table

DER in percent. Protocol columns matter more than the numbers; cells from
different protocols are not comparable and are marked.

| System (weights) | License / deployable on Mac | Protocol | AMI SDM | VoxConverse | DIHARD 3 | CALLHOME | Speed |
|---|---|---|---|---|---|---|---|
| pyannote community-1 (PyTorch) | CC-BY-4.0 / Python | collar 0, overlap scored, auto count | 19.9 | 11.2 | 20.2 | 26.7 | 1.5-2x CPU, 20-25x MPS (FluidAudio) |
| pyannoteAI precision-2 (API) | cloud only | same | 15.6 | 8.5 | 14.7 | 16.6 | n/a |
| Argmax SpeakerKit c-1 (CoreML) | MIT pkg; HF model license undeclared | OpenBench: collar 0, overlap scored | 21 | 11 | 22 | 30 | up to 496x (M2 Ultra) |
| pyannote 3.1 (OpenBench) | CC-BY-4.0 | same as above | 23 | 11 | 24 | 29 | - |
| senko (CoreML+Python, M3) | MIT | same as above | 32.8 | 13.9 | - | - | 275-393x |
| DiariZen Large-s80-v2 | CC BY-NC / no CoreML | collar 0 (overlap scored in 2509.26177) | 13.9 | 9.1 | 14.5 | - | ~20x GPU |
| FluidAudio 0.15.4 c-1 defaults | CC-BY-4.0 / Swift | collar 0.25, overlap ignored (VoxConverse); AMI protocol unstated, old threshold semantics | 10.6* | 15.07 | - | - | 122x / ~70x |
| FluidAudio c-1 stepRatio 0.1 | same | collar 0.25, overlap ignored | - | 13.89 | - | - | 65x |
| Sortformer v2.1 streaming 1.04 s | NVIDIA OML / CoreML ports | collar 0 (0.25 CALLHOME), overlap scored, <=4 spk subsets | 16.67 (IHM) | - | 15.09 | 6.65 (2 spk) | 214x GPU |
| Sortformer v1 offline | CC-BY-NC | as above | - | - | 14.76 | 5.85 (2 spk) | - |
| FluidAudio Sortformer CoreML | NVIDIA OML | AMI SDM, protocol unstated | 31.7 | - | - | - | 127x |
| FluidAudio LS-EEND .ami | research / CoreML | AMI, protocol unstated, 4 spk max | 20.7 | - | - | - | 75x |
| Nemotron-3 Diarization CoreML (gated) | eval-only license | AMI "MHM", protocol unstated | 9.28** | - | - | - | ~1000x (M5 Pro) |
| VibeVoice-ASR 9B | MIT / not practical on Mac | unstated | 13.43 | - | - | - | GPU |

\* Not comparable: AMI table run with `--threshold 0.7` under the inverted semantics,
collar/overlap unstated. \*\* Not comparable: gated card, protocol not visible.

## 3. Implications for MacParakeet

### 3.1 Stale claims in ADR-010 and the June frontier doc

| Claim | Status on 2026-09-06 |
|---|---|
| ADR-010: offline pipeline "~15% (VoxConverse), ~17.7% (AMI)" | FluidAudio's own docs now report 15.07/13.89 (VoxConverse, collar 0.25, overlap ignored) and 10.6 (AMI SDM, protocol unstated). The AMI figure was measured under the inverted threshold semantics and is flagged for re-benchmark. |
| ADR-010: "This is the same pipeline that pyannote's own commercial API uses, minus proprietary tuning" | Unsupported. precision-2 is a distinct model ("28% more accurate", voiceprints, confidence) and is 4 to 10 DER points better than community-1 on the card table. |
| ADR-010: Sortformer "4 max (hard limit)" as a family property | Still true for public NVIDIA models. Nemotron-3 Diarization (8 speakers) and community 8-speaker fine-tunes exist, but none is shippable under an open license today. |
| ADR-010: "DiariZen: 13.3% DER ... no CoreML/ANE port" | Port status unchanged. 13.3 is the four-dataset average from 2509.26177; per-dataset AMI-SDM is 13.9. Weights remain CC BY-NC. |
| ADR-010 and June doc: FluidAudio offline pipeline is a faithful community-1 port | False for the pinned 0.15.4: three clustering defects and a random-seed K-Means fallback, fixed upstream in 0.15.5/0.15.6. |
| June doc: "LS-EEND avoids Sortformer's fixed 4-speaker ceiling" | Only for the `.callhome` (7), `.dihard2`/`.dihard3` (10) variants. The `.ami` variant that scored 20.7 is capped at 4 speakers. |
| June doc: FluidAudio is the only Swift/CoreML community-1 path | Argmax SpeakerKit (MIT, March 2026) and speech-swift / aufklarer FP32 CoreML export (Apache 2.0 / CC-BY-4.0) are alternatives. |
| June doc: identity substrate should reuse FluidAudio embeddings | Still valid; CAM++ (beta) and Argmax centroid embeddings widen the options. |
| June doc: "Track DiariZen, do not ship" | Unchanged. |
| ADR-010: "Speaker detection ~85% accurate" Settings copy | Not derivable from any DER figure; DER is not an accuracy percentage. |

### 3.2 Ranked shortlist

**1. Upgrade FluidAudio to v0.15.6 or later and re-tune the async path.**
Causal argument: the pinned clustering applies an AHC cut of 0.894 instead of
0.6, skips constrained assignment, and mishandles speaker-count constraints, all of
which produce the exact symptom reported ("same speaker count, wrong partition",
merged or absorbed speakers). Those are code defects, not model limits, and the fix
is upstream and released. Second-order gains from the same upgrade: deterministic
constrained re-clustering (#735), optional zero-vote re-embedding, and the
`prepare()`/`cluster()` split, which makes "re-run with N speakers" or "re-run with a
stricter threshold" a clustering-only operation on cached embeddings. Because the
async path tolerates about 1x real time, also switch it to `stepRatio 0.1`,
`minSegmentDurationSeconds 0`, which FluidAudio measures at 1.2 DER points better
for half the throughput. Risk: threshold semantics flip, so any tuned value must be
remapped (`sqrt(2 - 2*old)`); macOS 14 BNNS crash (#878) needs a guard.

**2. A/B an independent community-1 CoreML port (Argmax SpeakerKit).**
Causal argument: it is the same model family with pyannote-parity clustering and a
W16A16 embedder, and its accuracy is published on 12 datasets under a stated protocol
(OpenBench). FluidAudio attributes its 3 to 4 point VoxConverse gap to fp16 on the
Neural Engine; SpeakerKit's OpenBench VoxConverse 0.11 matches the PyTorch reference
while FluidAudio reports 13.9 to 15.1 on a friendlier protocol. It also reports 69%
speaker-count accuracy on AMI-SDM. Risks: second Swift dependency overlapping
FluidAudio's models, an undeclared license on the model repo, and Argmax's commercial
Pro tier shaping the open package. Use it first as the reference arm of the A/B; adopt
only if it wins on MacParakeet's own meeting corpus.

**3. Nemotron-3 Diarization via FluidAudio PR #883 (blocked, track).**
Causal argument: an end-to-end 8-speaker Sortformer with reported AMI DER around
9.3 on the FluidInference card, offline preset, about 1000x real time on ANE, and
per-slot activity that natively models overlap. It is the only candidate whose
reported number is clearly below every community-1 figure, but the protocol is
unverified and the license forbids production use and redistribution. Adopt only
after NVIDIA's general release under an open model license and a local re-benchmark.

Excluded with reasons: DiariZen (non-commercial weights); Sortformer v1 offline
(non-commercial); senko (worse on meetings, Python); MOSS/VibeVoice joint models
(no comparable DER, English WER unknown vs Parakeet, 9B is impractical); LLM
post-correction (no evidence without domain fine-tuning; zero-shot degrades).

### 3.3 Minimal A/B evaluation

Arms: (A) FluidAudio 0.15.4 defaults as shipped; (B) FluidAudio 0.15.6 defaults;
(C) FluidAudio 0.15.6 with stepRatio 0.1, minSegmentDuration 0, zero-vote re-embed
on; (D) Argmax SpeakerKit community-1 defaults. Same 16 kHz mono input for all arms.

Data: (1) AMI SDM 16-meeting test set and VoxConverse, both already supported by
FluidAudio's `diarization-benchmark` CLI, scored twice: collar 0.25 with overlap
ignored (FluidAudio's convention) and collar 0 with overlap scored (pyannote and
OpenBench convention), so results can be placed against sections 2.1 and 2.5.
(2) Ten to twenty of the product owner's own retained meeting system-audio tracks
with speaker labels hand-corrected in the app; this is the only set that reflects
post-AEC system audio and the "Me vs others" split.

Metrics, kept separate: DER with the two protocols; speaker-count accuracy; word-level
speaker attribution error after `SpeakerMerger`; number of user corrections needed
to reach the corrected transcript; wall-clock and peak memory on an M1-class machine.

Decision rule: adopt B or C if DER and speaker-count accuracy improve on both the
public sets and the local set with no regression on 2-speaker calls; adopt D only if
it beats C on the local set. Report the protocol beside every number.

## 4. Failure scenarios and uncertainty

- The 0.15.4 defect story is confirmed in code and by FluidAudio's own PR, but the
  size of the DER gain on MacParakeet's meeting audio is unmeasured. FluidAudio has
  not yet republished its AMI table under the new semantics.
- The FluidAudio AMI SDM 10.6 figure has no stated collar or overlap policy and was
  produced with a non-default threshold under inverted semantics; do not treat it as
  comparable to the model-card 19.9.
- Nemotron-3 Diarization numbers come from a gated card summarized by a fetch tool,
  with no protocol visible. The license blocks shipping regardless of accuracy.
  Timing of NVIDIA's general release is unknown.
- SpeakerKit's OpenBench run is dated 2025-09-29 on an M2 Ultra; the current
  package (v1.1.0) may differ. Its HF model repo carries no license tag; community-1
  weights are CC-BY-4.0 upstream, but the redistribution terms need confirmation.
- Issue #879 (no VBx transition prior) may cap gains on rapid turn-taking even after
  the 0.15.6 upgrade; the reporter's 8-speaker staff meeting held at DER 0.162 across
  Fa/Fb sweeps.
- Two-channel echo suppression via "Me" centroid matching is a design inference
  from evidenced components, not an evidenced system. Post-AEC leakage levels in
  MacParakeet's system track are unknown to this survey.
- LLM post-correction results are all from English telephone corpora with
  fine-tuned models; transfer to meetings and to Parakeet transcripts is unproven.
- Gated or JS-rendered pages (NVIDIA cards, ScienceDirect, ACM) were read through
  summaries or abstracts; verbatim benchmark tables from those could not be saved.

## 5. Sources

Observed 2026-09-06 unless noted.

pyannote
- https://github.com/pyannote/pyannote-audio/releases (dates via GitHub API)
- https://raw.githubusercontent.com/pyannote/pyannote-audio/main/CHANGELOG.md
- https://huggingface.co/pyannote/speaker-diarization-community-1 (modified 2025-09-29)
- https://huggingface.co/pyannote (org listing)
- https://www.pyannote.ai/changelog and https://docs.pyannote.ai/models
- https://www.pyannote.ai/blog/speaker-identification-system-recurring-meetings (2026-09-03)

FluidAudio
- Pinned checkout b9d43724cbdb5a980e441fd54180964e94d470f7 (v0.15.4): `Documentation/Benchmarks.md`, `Documentation/Diarization/{LS-EEND,Sortformer}.md`, `Sources/FluidAudio/Diarizer/Offline/Clustering/{AHCClustering,VBxClustering,KMeansClustering}.swift`
- https://github.com/FluidInference/FluidAudio/releases (v0.15.5 2026-07-07, v0.15.6 2026-08-19)
- https://github.com/FluidInference/FluidAudio/pull/802 (merged 2026-08-19), /pull/735 (2026-06-24), /pull/789 (2026-07-15), /pull/652 (2026-08-18), /pull/883 (open)
- https://github.com/FluidInference/FluidAudio/issues/801, /issues/879, /issues/878
- https://raw.githubusercontent.com/FluidInference/FluidAudio/main/Documentation/Benchmarks.md
- https://raw.githubusercontent.com/FluidInference/FluidAudio/main/Documentation/Diarization/GettingStarted.md
- https://raw.githubusercontent.com/FluidInference/FluidAudio/main/Documentation/Diarization/LS-EEND.md
- https://raw.githubusercontent.com/FluidInference/FluidAudio/main/Documentation/Models.md
- https://raw.githubusercontent.com/FluidInference/FluidAudio/main/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerTypes.swift
- https://huggingface.co/FluidInference (org), https://huggingface.co/FluidInference/nemotron-3-diarization-coreml (gated), https://huggingface.co/api/models/FluidInference/campplus-coreml

NVIDIA
- https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1
- https://huggingface.co/nvidia/diar_sortformer_4spk-v1
- https://huggingface.co/nvidia/Nemotron-3-Diarization-preview (gated; API metadata 2026-08-24 / 2026-09-05)
- https://huggingface.co/nvidia/multitalker-parakeet-streaming-0.6b-v1
- https://docs.nvidia.com/nemo/speech/nightly/asr/speaker_diarization/models.html
- https://huggingface.co/models?search=sortformer
- https://arxiv.org/abs/2507.18446 (Streaming Sortformer)

DiariZen and benchmarks
- https://github.com/BUTSpeechFIT/DiariZen
- https://huggingface.co/BUT-FIT/diarizen-wavlm-large-s80-md-v2
- https://huggingface.co/models?search=diarizen
- https://arxiv.org/abs/2604.21507 (DiariZen Explained, 2026-04-23)
- https://arxiv.org/abs/2509.26177 and https://arxiv.org/html/2509.26177v1 (Benchmarking Diarization Models)

Apple Silicon ports
- https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/index.html and https://github.com/k2-fsa/sherpa-onnx/tree/master/swift-api-examples
- https://github.com/narcotic-sh/senko and https://github.com/narcotic-sh/senko/tree/main/evaluation
- https://github.com/argmaxinc/argmax-oss-swift (README, releases via GitHub API)
- https://huggingface.co/api/models/argmaxinc/speakerkit-coreml
- https://www.argmaxinc.com/blog/speakerkit and https://arxiv.org/abs/2507.16136v2 (SDBench)
- https://raw.githubusercontent.com/argmaxinc/OpenBench/main/BENCHMARKS.md
- https://github.com/soniqo/speech-swift and https://raw.githubusercontent.com/soniqo/speech-swift/main/docs/inference/speaker-diarization.md
- https://huggingface.co/aufklarer/Pyannote-Community-1-CoreML, https://huggingface.co/aufklarer/Ultra-Sortformer-Diarization-CoreML, https://huggingface.co/Alkd/Sortformer-Diarization-CoreML
- https://huggingface.co/mlx-community/pyannote-segmentation-3.0-mlx
- https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber.json
- https://github.com/yrocaz/mac-transcriber/blob/main/docs/research/2026-07-27-apple-speechanalyzer-docs.md

Joint ASR + diarization
- https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize, https://github.com/OpenMOSS/MOSS-Transcribe-Diarize, https://arxiv.org/abs/2601.01554
- https://huggingface.co/microsoft/VibeVoice-ASR and https://raw.githubusercontent.com/microsoft/VibeVoice/main/docs/vibevoice-asr.md
- https://github.com/BUTSpeechFIT/DiCoW and https://huggingface.co/BUT-FIT/SE_DiCoW
- https://github.com/m-bain/whisperX
- https://arxiv.org/abs/2601.06896 (TagSpeech), https://arxiv.org/pdf/2604.22467 (DM-ASR), https://arxiv.org/abs/2508.06372 (SpeakerLM)
- Voxtral Transcribe 2 coverage (2026-02-04): https://www.marktechpost.com/2026/02/04/mistral-ai-launches-voxtral-transcribe-2-pairing-batch-diarization-and-open-realtime-asr-for-multilingual-production-workloads-at-scale/

LLM post-correction
- https://arxiv.org/abs/2401.03506 and https://huggingface.co/google/DiarizationLM-8b-Fisher-v2
- https://arxiv.org/abs/2501.08421 (SEAL)
- https://arxiv.org/abs/2406.04927 and https://github.com/GeorgeEfstathiadis/LLM-Diarize-ASR-Agnostic
- https://www.sciencedirect.com/science/article/pii/S0167739X26002827 (abstract only, 2026)

Target-speaker and channel priors
- https://arxiv.org/abs/2204.03793 (Personal VAD 2.0), https://arxiv.org/pdf/2208.13085 (TS-VAD with Transformers)
- Deepgram / AssemblyAI / AWS multichannel docs as cited in `docs/research/speaker-diarization-frontier-2026-06.md` (observed 2026-06-14)

Local
- `spec/adr/010-speaker-diarization.md`, `docs/research/speaker-diarization-frontier-2026-06.md`
- `Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift` (config at line 205)
