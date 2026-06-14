---
title: Speaker Diarization and Speaker Identification Frontier
status: RESEARCH
date: 2026-06-14
authors: Codex/GPT, Daniel Moon
---

# Speaker Diarization and Speaker Identification Frontier

> Status: **RESEARCH** - current-state survey and MacParakeet recommendation.
> Evidence date: 2026-06-14.
> Related: `spec/adr/010-speaker-diarization.md`,
> `docs/research/meeting-dual-stream-transcription-pipeline.md`,
> `Sources/MacParakeetCore/Services/Diarization/`.

## TL;DR

MacParakeet does not need "diarization support" from a blank slate. It already
has the right local-first spine:

- offline FluidAudio diarization for file/URL transcription
- stable chronological speaker IDs (`S1`, `S2`, ...)
- word-level speaker assignment by segment overlap
- meeting capture that keeps microphone and system audio as separate source
  files
- optional post-stop diarization of the isolated system track, while preserving
  microphone as `Me`

The next product step should **not** be replacing Parakeet/Nemotron/WhisperKit
ASR. It should be a speaker identity layer on top of source attribution and
diarization:

1. Persist local speaker profiles and embeddings only after explicit user
   action.
2. Convert user speaker renames into opt-in profile/enrollment signals.
3. Run post-stop speaker matching against local profiles as a suggestion, not
   an automatic claim.
4. Keep final diarization offline/batch and non-fatal.
5. Treat live streaming diarization as tentative UI only.

For models, the current recommendation is:

- **Default final diarization:** keep FluidAudio's offline CoreML pipeline
  based on the pyannote/community-1 style segmentation, WeSpeaker embeddings,
  and VBx clustering.
- **Speaker identity substrate:** use the embeddings FluidAudio already emits
  or exposes through enrollment APIs before adding another Python stack.
- **Live preview experiment:** evaluate FluidAudio LS-EEND before Sortformer.
  LS-EEND avoids Sortformer's fixed 4-speaker ceiling and has better AMI SDM
  numbers in FluidAudio's current docs.
- **Do not integrate WhisperX/pyannote Python directly into the app core.**
  They are useful references and CLI/prototype tools, but they work against
  MacParakeet's Swift/CoreML/local-app shape.
- **Do not use cloud diarization as the product architecture.** Commercial APIs
  are useful benchmark references, not the default privacy model.

## Terms That Must Stay Separate

These are frequently collapsed in product conversations, but they have
different failure modes and UX contracts.

| Concept | Meaning | MacParakeet stance |
| --- | --- | --- |
| Source/channel attribution | Which capture source produced the audio, such as microphone vs system. | Strongest signal. Preserve it whenever available. |
| Speaker diarization | Anonymous "who spoke when" within an audio stream. | Useful, approximate, non-fatal. |
| Speaker verification | 1:1 check: is this voice the same as an enrolled voice? | Needs explicit enrollment and thresholding. |
| Speaker identification | 1:N match: which enrolled profile is closest? | Should produce suggestions, not silent names. |
| Speaker naming | Displaying "Alice" instead of `S1`. | Trustworthy only from user confirmation, source metadata, or explicit enrollment. |

The important product rule: diarization can say "same/different speaker
cluster"; it cannot know a person's real name without another source of truth.

## Current MacParakeet State

Current code already implements a substantial subset of the target
architecture:

- `DiarizationService` wraps FluidAudio `OfflineDiarizerManager`, accepts exact
  or bounded speaker-count constraints, and normalizes FluidAudio labels to
  chronological stable IDs.
- `SpeakerMerger` assigns each ASR word the diarization speaker segment with
  the largest time overlap.
- `Transcription` persists `speakerCount`, `speakers`, `diarizationSegments`,
  and per-word `speakerId`.
- `TranscriptionService` treats diarization as optional and non-fatal for file
  transcription.
- Meeting finalization transcribes `microphone.m4a` and `system.m4a`
  separately, merges by persisted source alignment, and optionally diarizes the
  isolated system track additively. The microphone remains the user-facing `Me`
  speaker.

That last point is important. Meeting support should not run blind diarization
over a mixed `meeting.m4a` when it has stronger source artifacts. The current
dual-stream pipeline already follows the best practice that commercial STT
docs also recommend: keep channel/source separation when it exists, then use
diarization inside a channel only when needed.

The spec is now a little behind the code and dependency surface. ADR-010 still
frames diarization as offline only and rejects Sortformer/streaming. The pinned
FluidAudio checkout now documents:

- `OfflineDiarizerManager` for batch pyannote-style diarization
- `SortformerDiarizer` for streaming diarization with 4 fixed speaker slots
- `LSEENDDiarizer` for streaming diarization with variable speaker slots
- speaker enrollment APIs
- timeline segments with finalized vs tentative state

That does not mean MacParakeet should flip to streaming diarization as truth.
It means the research/experiment surface is available in Swift/CoreML if we
want a tentative live layer.

## Model Landscape

### Offline Diarization

**pyannote community-1 / precision-2.** pyannote's `community-1` is currently
the strongest widely adopted open-source baseline. Its model card says it
accepts 16 kHz mono input, improves speaker assignment/counting over 3.1, adds
an exclusive diarization output intended to make ASR word alignment easier, and
can run offline after model download. The public benchmark table shows
community-1 improving over 3.1 across many datasets, with pyannoteAI
`precision-2` better still as a cloud/commercial model.

MacParakeet implication: community-1 style diarization is the right final-pass
baseline, but the Python package itself is not the right app integration.
FluidAudio's CoreML port is the local Swift path.

**FluidAudio offline diarization.** FluidAudio documents a full batch pipeline
mirroring the pyannote/CoreML exporter:

```text
segmentation -> binarization -> interpolation -> embedding extraction -> VBx
clustering -> timeline reconstruction
```

The docs state that the embedding runner emits 256-dimensional L2-normalized
embeddings, and the current API includes disk-backed streaming audio sources so
large meetings do not have to be loaded entirely into memory.

MacParakeet implication: keep this as the canonical post-stop diarizer. The
implementation already matches local-first and SwiftPM packaging constraints.

**DiariZen.** DiariZen is research-frontier strong. Its README reports DER
improvements over pyannote 3.1 on AMI-SDM, AliMeeting far, DIHARD3, RAMC,
VoxConverse, and other datasets. Its v2 large model reports, for example,
13.9 DER on AMI-SDM and 10.8 on AliMeeting far, versus pyannote 3.1 at 22.4
and 24.4 respectively in the same table.

MacParakeet implication: track this for offline benchmark comparison, but do
not ship it now. The toolkit is Python/Jupyter-heavy and its pretrained weights
are CC BY-NC 4.0, which is not product-compatible for a general GPL app
release.

**WhisperX and Whisper diarization wrappers.** WhisperX remains the practical
open-source glue stack: Whisper/faster-whisper ASR, wav2vec forced alignment,
pyannote diarization, word-speaker assignment. Its README also calls out the
core limitation: overlapping speech is not handled particularly well and
diarization is far from perfect.

MacParakeet implication: use as reference for alignment UX and failure
language, not as an app dependency.

### Streaming/Live Diarization

**NVIDIA Sortformer.** Sortformer is a serious streaming diarization model,
and NVIDIA's v2.1 Hugging Face card publishes both low-latency and high-latency
configurations. The low-latency configuration has 1.04 s input-buffer latency;
the high-latency configuration has 30.4 s. It is explicitly optimized for up to
four speakers, and benchmark rows show degradation on >=5 speaker subsets.

FluidAudio's CoreML benchmark for Sortformer on AMI SDM reports 31.7 average
DER with the NVIDIA high-latency config.

MacParakeet implication: Sortformer may be useful when the meeting is known to
have <=4 speakers and the UX wants fast tentative turns. It should not be the
canonical final diarizer.

**LS-EEND / FS-EEND.** The Westlake FS-EEND repository covers frame-wise
streaming EEND and LS-EEND, with the LS-EEND paper accepted in IEEE TASLP
2025. The README says LS-EEND targets long-form streaming diarization with a
high and flexible number of speakers, up to 8, and very long recordings such as
one hour. FluidAudio exposes `LSEENDDiarizer` and reports 20.7 average DER on
AMI SDM for the `.ami` CoreML bundle with 500 ms step size.

MacParakeet implication: if we experiment with live speaker turns, LS-EEND is
the better first candidate than Sortformer. It has a better speaker-count shape
for meetings and better FluidAudio-reported AMI SDM numbers.

**Live diarization product rule.** Live output must be explicitly tentative.
The final transcript should still be built after stop from durable source
audio, batch ASR, and batch/offline diarization.

### Speaker Identity and Recognition

Speaker identity is an embedding/matching problem, not a diarization problem.
The most relevant open-source families are:

- **WeSpeaker:** production-oriented speaker embedding toolkit with embedding,
  similarity, and diarization command-line tasks. pyannote community-1 cites
  WeSpeaker for its speaker embedding component.
- **SpeechBrain ECAPA-TDNN:** common baseline for speaker verification and
  embedding extraction; trained on VoxCeleb and uses cosine distance between
  speaker embeddings.
- **3D-Speaker:** active speaker verification/recognition/diarization toolkit
  with CAM++, ERes2Net, ECAPA, ResNet, and multimodal recipes.
- **pyannote embedding:** simple pretrained embedding extraction for speaker
  verification workflows.
- **FluidAudio enrollment APIs:** the most relevant MacParakeet-native path
  because it keeps the stack in Swift/CoreML and can reuse loaded diarization
  models.

MacParakeet implication: build a local speaker profile layer before choosing a
new identity model. A better embedding model without a conservative product
contract will still create false-name trust failures.

## Live GitHub Scan

Command run on 2026-06-14:

```bash
gh search repos "speaker diarization" --sort stars --limit 25 \
  --json fullName,description,stargazersCount,updatedAt,url,language,openIssuesCount
```

Top relevant results:

| Stars | Repository | Why it matters |
| ---: | --- | --- |
| 17,975 | `modelscope/FunASR` | Industrial ASR toolkit including diarization, streaming, languages, API surface. |
| 12,981 | `k2-fsa/sherpa-onnx` | Offline ONNX speech stack with diarization and embedded/mobile deployment. |
| 12,725 | `Zackriya-Solutions/meetily` | Local-first meeting assistant advertising Parakeet/Whisper, diarization, Ollama summaries. |
| 10,119 | `pyannote/pyannote-audio` | De facto open-source diarization toolkit. |
| 5,563 | `MahmoudAshraf97/whisper-diarization` | Popular Whisper + diarization wrapper. |
| 2,990 | `modelscope/3D-Speaker` | Speaker verification, recognition, and diarization toolkit. |
| 2,186 | `FluidInference/FluidAudio` | Swift/CoreML STT, VAD, diarization; directly relevant to MacParakeet. |
| 1,872 | `wq2012/awesome-diarization` | Curated paper/resource tracker. |
| 1,274 | `FunAudioLLM/Fun-ASR` | Large ASR model family with timestamps and diarization. |
| 478 | `BUTSpeechFIT/DiariZen` | Strong current research toolkit and benchmarks. |
| 180 | `Audio-WestlakeU/FS-EEND` | LS-EEND / streaming EEND reference implementation. |

Current ecosystem themes:

- Local-first meeting products are converging on **Parakeet or Whisper for ASR
  plus diarization plus local LLM summarization**.
- Python wrapper stacks remain popular, but they carry the exact dependency,
  GPU, model-license, and runtime-shape issues MacParakeet has been avoiding.
- ONNX deployment stacks are growing, especially for embedded/mobile, but
  MacParakeet already has a stronger Apple-platform path through CoreML.
- Swift/CoreML diarization is still much rarer than Python diarization, which
  makes FluidAudio strategically valuable.

Issue scan on `pyannote/pyannote-audio` for community-1 surfaced the current
operational pain points:

- memory spikes on long audio in pyannote 4.x
- overlap handling complaints
- AMD/ROCm runtime issues
- embedding-step performance complaints
- Colab/install/runtime friction

These are good reminders that "just use pyannote" is not a low-risk macOS app
architecture.

## Industry Practice

The best industry practice is not "always diarize everything." It is:

1. **Preserve channels/sources when available.** Deepgram's docs distinguish
   multichannel audio from diarization and explain that multichannel
   transcription processes distinct channels separately, while diarization
   labels unique speakers regardless of channel.
2. **Use diarization inside a source/channel when multiple people may be
   present there.** This matches MacParakeet's meeting approach: `Me` from
   microphone source attribution; anonymous `Others N` from system-side
   diarization.
3. **Use speaker count hints when known.** pyannote supports exact, min, and
   max speaker constraints; MacParakeet already exposes the equivalent shape in
   `SpeakerDiarizationConstraint`.
4. **Treat channel labels and speaker labels independently.** AssemblyAI's docs
   note that speaker options are applied per channel when multichannel and
   speaker labels are combined. AWS likewise separates channel identification
   from speaker partitioning.
5. **Expect overlap to be lossy.** Exclusive diarization is useful for word
   assignment, but it intentionally collapses overlap to one active speaker.
   User-facing language should reflect this.
6. **Keep reprocessing possible.** Durable audio, diarization segments, and
   word timestamps should be retained so better diarizers can be rerun later.
7. **Do not silently name people from voiceprints.** Identity requires consent,
   deletion controls, confidence thresholds, and UI for correction.

## Recommended MacParakeet Plan

### Phase 0: Reconcile Docs

Update specs after this research lands:

- ADR-010 should remain valid for final/offline diarization, but acknowledge
  that the current FluidAudio dependency now exposes LS-EEND, Sortformer, and
  enrollment APIs.
- `spec/06-stt-engine.md` should stop saying streaming diarization is entirely
  out of scope if we intend to experiment with tentative live labels.
- Meeting docs should keep emphasizing that `meeting.m4a` is playback/export;
  final correctness comes from source files.

### Phase 1: Add a Speaker Profile Substrate

Add local-only speaker identity tables and model types before changing the
diarizer:

```text
SpeakerProfile
  id
  displayName
  createdAt
  updatedAt
  deletedAt
  enrollmentState
  consentSource

SpeakerEmbedding
  id
  speakerProfileId
  modelIdentifier
  vector
  vectorDimension
  sourceTranscriptionId
  sourceSpeakerId
  qualityScore
  createdAt

SpeakerAssignment
  id
  transcriptionId
  diarizedSpeakerId
  speakerProfileId?
  displayLabel
  confidence
  assignmentSource   # channel | diarization | userRename | enrollmentSuggestion
  userConfirmedAt?
```

UX contract:

- Renaming `S1` to "Alice" changes the transcript label.
- "Remember this speaker" creates or updates a local profile.
- Future meetings show "Looks like Alice" until confirmed.
- Users can delete a profile and its embeddings.
- Exports distinguish `speakerId`, `label`, and `profileId`.

### Phase 2: Post-Stop Identity Suggestions

After final diarization:

1. Aggregate clean speech spans per anonymous diarized speaker.
2. Extract embeddings for each diarized speaker.
3. Compare against local profiles with a conservative threshold.
4. Emit pending suggestions, not automatic permanent labels.
5. Learn only from explicit confirmation or enrollment.

This keeps the local-first trust model intact and makes false positives
recoverable.

### Phase 3: Live Tentative Speaker Turns

Experiment behind a feature flag:

- Prefer `LSEENDDiarizer` for meeting-like, variable-speaker live output.
- Use `SortformerDiarizer` only for known <=4-speaker, low-latency scenarios.
- Render live labels as tentative.
- Never let live diarization overwrite final post-stop speakers without
  reprocessing.

The likely first target is the isolated system stream, not the microphone.
Microphone is already source-attributed to `Me`, and diarizing it can make the
product feel less reliable unless there is a real use case for multiple people
near the user's mic.

### Phase 4: External Benchmark Harness

Add an offline benchmark harness before changing defaults:

- local fixtures with known speaker labels
- synthetic two-speaker overlap samples
- meeting-like samples with microphone/system separation
- DER, speaker-count error, word-speaker assignment accuracy, and runtime
- "user trust" checks: wrong-name rate, unknown-speaker handling, correction
  persistence

Benchmarks should compare:

- current FluidAudio offline pipeline
- FluidAudio LS-EEND offline/complete mode, if practical
- FluidAudio Sortformer complete mode
- external Python references only in a separate research harness

## Decision Matrix

| Option | Accuracy | Local-first fit | Shipping risk | Recommendation |
| --- | --- | --- | --- | --- |
| Current FluidAudio offline diarization | Good baseline | Excellent | Low | Keep as final default. |
| FluidAudio LS-EEND | Promising for live | Excellent | Medium | Prototype tentative live labels. |
| FluidAudio Sortformer | Good for <=4 speakers | Excellent | Medium | Secondary prototype only. |
| pyannote Python community-1 | Strong OSS baseline | Weak for app runtime | High | Reference/harness only. |
| pyannoteAI precision-2 | Strong benchmark | Cloud | Product/privacy mismatch | Benchmark reference only. |
| DiariZen | Strong research numbers | Weak today | High/license issue | Track, do not ship. |
| WhisperX | Practical glue | Weak for app runtime | High | Learn from, do not embed. |
| WeSpeaker/SpeechBrain/3D-Speaker direct | Good identity research | Medium | Medium/high | Use only if FluidAudio enrollment is insufficient. |

## Risks and Product Constraints

- **False identity is worse than anonymous diarization.** `Speaker 2` is
  acceptable; incorrectly naming a person damages trust.
- **Voiceprints are sensitive local data.** They need opt-in, deletion, and
  clear export semantics.
- **Overlap remains hard.** Exclusive diarization makes transcript alignment
  easier by choosing one active speaker, but it loses true simultaneous speech.
- **Speaker-count hints help, but wrong hints hurt.** UI should make hints
  optional and recoverable.
- **Source bleed can confuse identity.** Echo or system audio captured in the
  microphone channel can contaminate embeddings.
- **Benchmarks do not equal user trust.** DER is useful but not sufficient;
  wrong speaker names and unstable labels matter more in the product.

## Bottom Line

The frontier is not "find the one diarization model." The frontier for
MacParakeet is a layered speaker memory system:

```text
source attribution -> anonymous diarization -> local speaker profiles ->
confirmed identity suggestions -> durable correction and reprocessing
```

Keep FluidAudio offline diarization as the canonical final pass. Build speaker
profiles and enrollment around it. Use LS-EEND/Sortformer only for tentative
live UX experiments after the identity substrate exists.

## Sources

- pyannote community-1 model card:
  <https://huggingface.co/pyannote/speaker-diarization-community-1>
- pyannote community-1 release note:
  <https://www.pyannote.ai/blog/community-1>
- pyannote benchmark page:
  <https://www.pyannote.ai/benchmark>
- Benchmarking Diarization Models:
  <https://arxiv.org/html/2509.26177v1>
- NVIDIA Sortformer v2.1 model card:
  <https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1>
- FluidAudio API docs:
  <https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md>
- FluidAudio diarization getting started:
  <https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md>
- FluidAudio benchmarks:
  <https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md>
- DiariZen:
  <https://github.com/BUTSpeechFIT/DiariZen>
- FS-EEND / LS-EEND:
  <https://github.com/Audio-WestlakeU/FS-EEND>
- WeSpeaker:
  <https://github.com/wenet-e2e/wespeaker>
- 3D-Speaker:
  <https://github.com/modelscope/3D-Speaker>
- SpeechBrain ECAPA-TDNN speaker verification:
  <https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb>
- pyannote embedding:
  <https://huggingface.co/pyannote/embedding>
- WhisperX:
  <https://github.com/m-bain/whisperX>
- Deepgram multichannel vs diarization:
  <https://developers.deepgram.com/docs/multichannel-vs-diarization>
- AssemblyAI speaker diarization:
  <https://www.assemblyai.com/docs/pre-recorded-audio/label-speakers>
- AWS Transcribe speaker diarization:
  <https://docs.aws.amazon.com/transcribe/latest/dg/diarization.html>
- AWS Transcribe channel identification:
  <https://docs.aws.amazon.com/transcribe/latest/dg/channel-id.html>
