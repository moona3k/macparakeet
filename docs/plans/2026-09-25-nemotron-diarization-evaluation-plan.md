---
title: Evaluate Nemotron 3 for MacParakeet speaker diarization
date: 2026-09-25
type: plan
execution: knowledge-work
---

# Nemotron diarization: evaluation and conditional adoption

## Objective and settled scope

Determine whether Nemotron 3 materially improves the speaker attribution problems in [#1046](https://github.com/moona3k/macparakeet/issues/1046), then prepare a small, reversible integration if the evidence supports it. This document began as an approach-level handoff. The user subsequently authorized the SDK upgrade, full comparison and tests, and a PR, preferring Nemotron unless testing discovers a material red flag. Execution results and remaining limits are recorded in `benchmarks/diarization/2026-09-25-nemotron-evaluation.md`.

The user has settled these product choices:

- Keep microphone audio labelled **Me**. Do not add microphone diarization or a shared-microphone feature.
- Evaluate diarization after recording on retained **system audio**, and on ordinary imported recordings. Preserve current live transcription behavior.
- Prioritize Nemotron's eight-speaker model. Eight identities per diarized source is an acceptable target for the main use case; do not pretend this supports an unlimited roster.
- Compare published evidence and actual matched runs before shipping. The authorized candidate default is Nemotron, subject to review of regressions; an upgrade is not a claim of superiority on every domain.

Read the [research and source pins](../research/2026-09-25-nemotron-diarization-evaluation.md) first, then the [Omarchy review](../research/2026-09-25-omarchy-meeting-recorder-diarization-review.md). The key discovery is that **FluidAudio v0.17.4 already provides Nemotron 3 in Swift/CoreML**. Start with that route. A replacement of the entire SDK or a new Rust/C++ runtime is unnecessary unless this route fails a measured requirement.

## Invariants

Preserve separate retained sources, original timestamps, ASR words, user corrections, recovery artifacts, local processing, and non-fatal diarization failure handling. A model failure must not destroy a usable transcript. Keep speaker identity matching separate from acoustic clustering. No audio, transcripts, or embeddings leave the device for this evaluation.

The first comparison changes only diarization. Do not simultaneously change ASR, source reconciliation, sentence grouping, or speaker smoothing. Collect outputs before and after those existing stages so their effects remain visible.

## 1. Establish a reproducible experiment

Start from fresh repository state and an isolated worktree based on fetched `origin/main`; the reviewed checkout contains unrelated changes. Verify the dependency pin and current service configuration again. The researched baseline is FluidAudio **0.15.7**, using `DiarizationService.highAccuracyConfig`, including its zero-vote re-embedding setting, exclusive intervals, and default clustering threshold.

Check available storage before installing anything. During this review the Mac had less than 0.5 GiB free, insufficient for the models, corpus audio, and Swift build. Select adequate existing storage or arrange a scoped cleanup separately; do not delete recordings, caches, or other work automatically. Record hardware, OS, toolchain, and available memory.

Extend `benchmarks/diarization/` with a bounded local runner and result manifest. The existing seven-file #1046 harness and frozen JSON remain useful regression evidence, but are not a raw acoustic comparison. The runner must execute both actual diarizers and retain their intervals. Keep downloaded audio and large outputs outside Git; commit manifests, small score tables, and the decision report.

Freeze before the final evaluation: model/export revision and file hashes, SDK revision, audio hashes and channel selection, reference RTTM and UEM hashes, scorer revision, configuration, precision, compute-unit routing, postprocessing, and aggregation. RTTM records who spoke when; UEM defines the regions included in scoring. Preserve full recording time, including silence. Fail the run on missing expected audio or references; do not inherit the upstream CLI's partial-file enumeration or reference fallback.

## 2. Fix the corpus and scoring protocol

Use **AMI test** as the initial meeting corpus, then **AliMeeting Test** as the second primary corpus. Use development recordings for harness debugging and parameter selection; freeze the configuration before examining the held-out results. These are established public test partitions, not newly collected private holdouts: audit the training disclosures for both model families and record any uncertainty.

| Set | Role and boundary |
| --- | --- |
| AMI, 16 test sessions | Evaluate the mixed-headset recording and true single distant microphone separately. Start with the pinned manual `only_words` references; rescore the same outputs with the published forced-alignment references to understand the vendor comparison. Do not mix reference conventions in a headline score. |
| AliMeeting, official 20-session Test | Evaluate near and far conditions with a fixed, documented mono recipe. The 8-session Eval set is development, not the final Test set. Do not feed one backend multichannel audio and the other mono. |
| Existing seven VoxConverse files | #1046 regression and debugging only. Nemotron trained on VoxConverse development **and test**; these cannot establish held-out superiority. |
| Small local meeting scenarios | Test interruptions, real one-word replies, minority speakers, echo during double-talk, silence, and late speaker re-entry. Synthetic fixtures verify behavior; real speech determines quality. |
| Optional later expansion | NOTSOFAR1 evaluation for harder rooms; DIHARD/CALLHOME only if licensed data is already available. No paid access is required for the first decision. |

Score all outputs through **one pinned external scorer**, such as `nryant/dscore`, rather than comparing the two SDK CLI summaries. Primary DER includes overlap and uses a zero-second collar. Report missed speech, false alarm, and speaker confusion separately. A secondary 0.25-second collar/overlap-excluded score can connect to legacy Fluid reports; label it separately and record the scorer's collar semantics.

Before trusting the runner, verify perfect, empty, missing-file, shuffled-label, silence-only, overlapping, duplicated, and shifted hypotheses. Empty output over reference speech must be penalized. An empty prediction must never cause the recording or its UEM to disappear from aggregation.

Use automatic speaker count for the primary model comparison. Oracle count experiments are diagnostic only. Evaluate MacParakeet's actual calendar/count hints in a separate product pass; do not silently give the baseline a known count or suppress Nemotron channels to fit the answer.

## 3. Compare a small number of meaningful candidates

Run these arms with identical decoded PCM and original timebase:

1. **Production-equivalent baseline:** pinned 0.15.7 with the app's exact configuration.
2. **Native candidate:** pinned 0.17.4 Nemotron with final GA weights. Begin with `offline` to connect to NVIDIA's report and `fast128` as the second bounded candidate suggested by Fluid's native results. `offline` is GPU-only because of ANE compiler limits; record `.all`, `.cpuAndGPU`, or `.cpuAndNeuralEngine` routing explicitly and do not equate CoreML with ANE. Select the final preset on development evidence. Evaluate the smaller split/quantized export only if storage, energy, or runtime measurements justify it.
3. **Upgrade control, when integrating:** the old offline diarizer on the new SDK, to distinguish dependency changes from the algorithm switch. Do not assume unchanged source proves unchanged runtime behavior.

Set interval filtering explicitly. Fluid's Nemotron helper defaults to removing runs shorter than 200 ms, while its benchmark sets the minimum to zero. Preserve short activity for the diagnostic comparison. Do not copy Omarchy's 300 ms cutoff, gap bridging, minority absorption, or whole-sentence reassignment. Any postprocessing optimization is a separate, development-tuned arm.

Keep baseline exclusive output as the product baseline. An overlap-preserving baseline variant can diagnose whether an improvement comes from the model or the existing exclusivity policy; it must not replace the labelled baseline silently. Save overlapping acoustic intervals even when the transcript can display only one speaker per word.

Check the selected CoreML export against the final checkpoint in upstream NeMo on a small subset where feasible, particularly first chunk, partial final chunk, cache rollover, and speaker re-entry. A mismatch should trigger numerical/runtime investigation, not threshold tuning against the test set. NVIDIA's native GGUF runtime is an additional cross-check with its own conversion/quantization assumptions; agreement between two converted runtimes does not establish parity with the original. Its whole-file API and chunked `v3-offline` mode are different experiments.

Include at least one long recording exercising cache reuse well beyond 20 minutes. Measure end-to-end diarization time and peak memory, both cold and warm, on the available Mac. Keep model loading, feature extraction, inference, and segmentation timings distinct where practical. Vendor throughput is not a substitute for this measurement.

## 4. Measure both the model and the transcript

For each run retain raw activity/intervals, direct word assignment, assignment after current smoothing, and final meeting/file projection. Reuse the same ASR words and timestamps across candidates. File transcription and meeting finalization have different roster behavior; test both.

| Decision question | Required evidence |
| --- | --- |
| Is acoustic attribution better? | DER and all three components; pooled and per-recording results, reported separately by corpus and microphone condition. |
| Are quieter participants preserved? | Count error, participant recall, genuine short-turn recall by duration bucket, and speakers contributing fewer than four seconds or 4% of speech. |
| Are false speaker changes reduced? | Fragmentation and false singleton switches, together with real singleton turns retained. A smaller roster alone is not success. |
| Is final text better attributed? | Attribution on aligned recognized words plus manual listening of a small preselected sample. Report text coverage/WER separately so deleted speech cannot improve the result. Use a documented speaker-aware word metric where reference words permit it. |
| Does it survive real meeting length? | Long gaps, late re-entry, overlapping remote speakers, cache resets, timing drift, cancellation, and memory growth. |
| Is the eight-speaker boundary honest? | Cases at 7–8 speakers and one documented >8 stress case. Eight predicted channels do not prove there were only eight people. |

Use paired per-meeting differences and inspect regressions, rather than reporting one pooled winner. When estimating uncertainty, resample independent meeting groups; alternate microphones and repeated sessions with the same participants are correlated, not extra independent evidence.

The existing A/B/A smoothing can erase a correctly detected real “Yes.” Report this explicitly if Nemotron improves the raw timeline but the saved transcript loses the benefit. Any correction to smoothing should be evaluated as a separate change against both diarizers.

## 5. Make an explicit adoption decision

Before opening final test results, record numerical acceptance margins for DER, short-turn retention, and practical Mac runtime based on the development baseline. Do not choose margins after seeing which model wins. Avoid an unsupported universal target such as “half the DER” from unrelated vendor tables.

Recommend adoption only when the candidate improves the relevant speaker errors across the primary meeting conditions, preserves brief participants and speech coverage within those frozen margins, and has acceptable Mac resource use. Explain whether a failure is model quality, export/runtime parity, annotation disagreement, or transcript postprocessing.

Possible outcomes:

- **Go:** repeatable acoustic and product gains; proceed to the bounded adapter and regression qualification below.
- **Narrower go:** a useful win for a documented subset, with explicit fallback for unsupported contracts. Keep complexity proportional to the demonstrated benefit.
- **Inconclusive:** mixed or small gains, poor statistical coverage, or unresolved runtime differences. State the one next experiment that can settle it.
- **No-go:** losses on real brief speakers, lack of a meaningful gain, or unacceptable runtime cost. Retain the evidence and existing default.

The deliverable is a concise benchmark report with reproducible commands, per-file results, failures included, and a clear recommendation. Do not turn the research score into an automatic public release decision.

## 6. If it wins, integrate through the current boundary

Use `DiarizationServiceProtocol` and its existing factory; avoid introducing a general plugin architecture. Keep the current backend available during qualification and for contracts Nemotron cannot satisfy.

Resolve these concrete boundaries before changing the default:

- **Speaker constraints:** current retranscription supports exact counts 1–100 and the CLI accepts constraints. An eight-output neural model does not automatically satisfy exact/ranged counts, even within eight. Preserve the old backend for unsupported explicit constraints or deliberately revise the contract and UI together. Never clamp or fabricate a successful count. Calendar hints must remain distinct from explicit choices.
- **Embeddings and identity:** Nemotron activity channels are not WeSpeaker embeddings. Do not relabel them with the existing embedding model ID. Keep the baseline for experimental voice-profile flows until an independently evaluated compatible embedding path exists; the ordinary candidate can omit identity embeddings honestly.
- **Concurrency and cancellation:** Nemotron model objects contain mutable buffers. Give each active run isolated state or serialize ownership; do not reuse the old read-only model-sharing assumption. The synchronous complete-file helper needs a cancellation-aware integration, potentially driving chunks between checks.
- **Overlap and durations:** audit consumers that assume exclusive intervals, including per-speaker durations and word assignment. Keep raw overlap evidence separate from an explicitly defined display projection.
- **Model delivery:** pin final GA assets and hashes, provide local cache/readiness/progress behavior, preserve interrupted-download recovery, and account for the converted weights' license/attribution in packaging.
- **SDK upgrade:** 0.15.7 to 0.17.4 also changes other speech code and dependencies. Confirm ASR output, model loading, dictation, file transcription, and meeting finalization regressions; unchanged platform minimums do not establish compatibility.

Introduce the candidate behind a reversible internal selection during validation. Existing recordings, IDs, corrections, and user artifacts must remain readable without migration merely to test a model. Explicit retranscription may produce a new automatic result under the existing correction rules.

Run focused tests for `DiarizationServiceTests`, `DiarizationServiceEmbeddingTests`, `SpeakerMergerTests`, relevant `TranscriptionServiceTests`, and meeting assembly/source reconciliation, adding meaningful contract tests for the new adapter. Complete the repository's full final code gate at most once after the implementation settles. Physical capture/device tests remain separate from Swift unit tests. Update ADR-010 and any affected contracts only when the implementation decision is supported, and prepare reviewable changes before a public release action.

## Entry points for the next agent

- `Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift`: protocol, factory, configuration, constraints, inference ownership, embedding identity.
- `Sources/MacParakeetCore/Services/Diarization/SpeakerMerger.swift`: acoustic-to-word assignment and smoothing.
- `Sources/MacParakeetCore/Services/MeetingRecording/MeetingTranscriptFinalizer.swift`: source attribution, roster filtering, and saved intervals.
- `Sources/MacParakeetCore/Services/TranscriptionService.swift`: file path, system-only meeting diarization, retranscription, and persistence.
- `benchmarks/diarization/2026-09-15-issue-1046-baseline.md`: prior experiment and frozen regression slice.
- `plans/active/2026-09-15-issue-1046-speaker-over-split.md`: existing #1046 work; centroid-only consolidation was rejected, not a proven repair.
- `spec/adr/010-speaker-diarization.md` and `spec/contracts/speaker-voiceprints.md`: decisions and identity boundary to preserve or amend deliberately.

Start with the resource preflight, frozen protocol, and two-backend audio runner. The immediate deliverable is matched evidence; production adoption follows only if it passes. No microphone diarization, ASR replacement, cloud evaluation, or live speaker-identification project is part of this plan.
