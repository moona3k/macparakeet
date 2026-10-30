# Nemotron 3 versus MacParakeet's current diarization

> Research snapshot before implementation. Subsequent matched runs, integration and the adoption decision are recorded in [the evaluation report](../../benchmarks/diarization/2026-09-25-nemotron-evaluation.md). Historical present-tense statements below describe the reviewed baseline.

Date: 2026-09-25. Follow-up to the [Omarchy review](2026-09-25-omarchy-meeting-recorder-diarization-review.md) and [issue #1046](https://github.com/moona3k/macparakeet/issues/1046). Research and source inspection only; no local model inference or matched audio benchmark has been run. The [next-agent plan](../plans/2026-09-25-nemotron-diarization-evaluation-plan.md) defines the experiment and conditional adoption path.

## Recommendation

**Prioritize a controlled Nemotron evaluation.** It is a materially different diarization approach with encouraging published results, and a native Swift/CoreML integration already exists in **FluidAudio v0.17.4**. We can likely replace the algorithm while retaining the SDK. There is no evidence yet that it beats MacParakeet's exact current pipeline on the same recordings and scoring protocol. [Released implementation](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.4).

The user has explicitly narrowed the scope: microphone audio stays **Me**, while saved system audio and imported recordings receive speaker diarization. Eight remote identities is an acceptable target for the main meeting use case. The local microphone does not consume one of those eight slots. This is a product choice, not a measured claim that a particular percentage of users records alone.

The next step is a small matched benchmark, followed by an integration only if it improves both acoustic attribution and the saved transcript. Published numbers justify the investment; they do not yet justify a production default change.

## What FluidAudio is using under the hood

MacParakeet pins FluidAudio **0.15.7** and uses its **offline Community-1 port**, rather than its legacy online diarizer. The main stages are:

1. A pyannote powerset segmentation model finds local speaker activity in overlapping windows.
2. WeSpeaker ResNet34 produces 256-dimensional voice embeddings from speech spans.
3. Agglomerative clustering and PLDA/VBx refinement group those local observations into recording-level speakers.
4. Timeline reconstruction creates intervals; the app assigns those intervals to ASR words and then smooths selected speaker changes.

The embedding/clustering stage is where acoustically different samples of one person can become separate clusters, or similar speakers can merge. Nemotron tests a different hypothesis: predict persistent speaker activity channels directly, carrying speaker context forward. This may reduce particular fragmentation errors; the architecture alone does not prove it will. [Offline implementation](https://github.com/FluidInference/FluidAudio/blob/41540ea237350afe5117a082b5c28eda642d0612/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift), [model provenance](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/df2625ac79a7ac6b65ad868fee6d80f320da4232/PROVENANCE.md).

MacParakeet uses a one-second window hop, allows short embedding/segment spans, enables zero-vote re-embedding, and retains the corrected default clustering threshold. Its default output intervals are exclusive. These details matter more than saying simply “FluidAudio.” The package's VBx implementation also follows pyannote's per-observation mixture update; it is not the original temporal HMM with a speaker-stickiness knob. [App configuration](../../Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift), [pinned settings](https://github.com/FluidInference/FluidAudio/blob/41540ea237350afe5117a082b5c28eda642d0612/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerTypes.swift), [VBx explanation](https://github.com/FluidInference/FluidAudio/blob/41540ea237350afe5117a082b5c28eda642d0612/Documentation/Diarization/GettingStarted.md#why-vbx-has-no-transition-self-loop-prior).

The CoreML bundle documents Community-1 lineage, but some historical conversion provenance was reconstructed afterward. This is not proof that the port numerically matches upstream PyTorch. Also, the SDK resolves model downloads through mutable `main` references: a Swift package pin alone does not pin cached model bytes. The experiment must hash both baseline and candidate assets. [Provenance manifest](https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/df2625ac79a7ac6b65ad868fee6d80f320da4232/provenance.json), [model registry](https://github.com/FluidInference/FluidAudio/blob/41540ea237350afe5117a082b5c28eda642d0612/Sources/FluidAudio/ModelRegistry.swift).

## What the published reports actually establish

DER is diarization error rate: missed speech, false speech, and wrong-speaker time relative to reference speaker time. Lower is better. The scoring collar ignores time near reference boundaries; excluding overlap makes the task easier. Both choices must match before scores can be compared.

### Current model family and historical FluidAudio reports

| Publisher/system | Published condition | DER | Interpretation |
| --- | --- | ---: | --- |
| FluidAudio offline, default | VoxConverse, 232 test clips, 0.25 s collar, overlap excluded | 15.07% mean | Historical configuration, not today's exact app pipeline. |
| FluidAudio offline, finer hop/short spans | Same reported set and protocol | 13.89% mean | Motivated our high-accuracy settings; predates later clustering fixes and was not rerun for the complete app configuration. |
| FluidAudio offline | 16 AMI sessions, labelled “SDM,” 0.25 s collar, overlap excluded | 10.62% average | Inspected runner/downloader loads mixed-headset files; do not treat this as proven distant-microphone SDM. |
| Upstream pyannote Community-1 | AMI IHM / SDM, zero collar, overlap included | 17.0% / 19.9% | Underlying model family, not FluidAudio CoreML or MacParakeet. |
| Upstream pyannote Community-1 | AliMeeting channel 1 / DIHARD 3 full, same strict protocol | 20.3% / 20.2% | Useful context, not a matched comparison with NVIDIA's differently annotated meeting results. |

Sources: [historical Fluid benchmark](https://github.com/FluidInference/FluidAudio/blob/41540ea237350afe5117a082b5c28eda642d0612/Documentation/Benchmarks.md#offline-diarization-pipeline), [Community-1 card](https://huggingface.co/pyannote/speaker-diarization-community-1/blob/3533c8cf8e369892e6b79ff1bf80f7b0286a54ee/README.md).

The AMI naming problem is concrete: `ami-sdm` maps to `Mix-Headset.wav` in the inspected historical code, rather than a distant microphone such as `Array1-01.wav`. The newer Nemotron benchmark distinguishes these conditions. This prevents a misleading “10.62 versus 11.14” comparison. [Historical path selection](https://github.com/FluidInference/FluidAudio/blob/41540ea237350afe5117a082b5c28eda642d0612/Sources/FluidAudioCLI/Commands/DiarizationBenchmark.swift#L1182-L1209), [downloader mapping](https://github.com/FluidInference/FluidAudio/blob/41540ea237350afe5117a082b5c28eda642d0612/Sources/FluidAudioCLI/DatasetParsers/DatasetDownloader.swift#L20-L35), [new channel mapping](https://github.com/FluidInference/FluidAudio/blob/21493f8dac5a97e65742e6ff26f42f164c2fda0f/Sources/FluidAudioCLI/Commands/DiarizationBenchmarkUtils.swift).

Historical Fluid values are per-file averages, not necessarily corpus-duration-weighted DER. The 0.15.6 clustering changes and 0.15.7 cap fixes further limit their relevance to today's adapter. The old paper/table numbers should remain historical evidence; the exact app baseline needs a fresh run. [0.15.6 changes](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.6), [0.15.7 changes](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.7).

### NVIDIA Nemotron 3

NVIDIA's final checkpoint is an eight-speaker Streaming Sortformer. The table below compares it with NVIDIA's previous four-speaker Sortformer, **not FluidAudio**. All rows use the 30.4-second buffered-input configuration; this describes audio context, not compute time.

| Evaluation condition | Previous Sortformer DER | Nemotron 3 DER |
| --- | ---: | ---: |
| DIHARD III Eval | 19.09% | 12.73% |
| CALLHOME Part 2 | 10.32% | 9.10% |
| AliMeeting Near / Far | 11.57% / 13.69% | 6.40% / 10.47% |
| AMI MHM / SDM | 15.81% / 21.42% | 9.25% / 11.14% |
| NOTSOFAR1 MHM / single-channel | 21.77% / 30.49% | 6.77% / 11.00% |

Training explicitly includes **VoxConverse development and test**, all ICSI, and AMI train/development. VoxConverse and ICSI therefore cannot establish held-out quality for Nemotron. [Pinned NVIDIA model card](https://huggingface.co/nvidia/Nemotron-3-Diarization/blob/f667ed73aee57d40cc39428eb768b4fd87a0a29e/README.md).

NVIDIA includes overlapping speech and uses zero collar except CALLHOME's 0.25 seconds. AMI, AliMeeting, and NOTSOFAR use forced-aligned references; the other two use original annotations. DIHARD's full set includes nine-speaker recordings beyond the model's capacity. In particular, NVIDIA's AMI 9.25% cannot be divided by Community-1's 17.0% and presented as a matched improvement. Rescore both outputs against the same references. [Evaluation protocol](https://huggingface.co/nvidia/Nemotron-3-Diarization/blob/f667ed73aee57d40cc39428eb768b4fd87a0a29e/diarization_evaluation.md), [forced-alignment reference project](https://github.com/nttcslab-sp/diar-forced-alignment).

These are strong broad results, not universal dominance: NVIDIA's two-speaker CALLHOME subset slightly regresses against the older model, and GPU throughput claims do not establish Mac performance. [NVIDIA launch analysis](https://huggingface.co/blog/nvidia/nemotron-diarization).

### Native FluidAudio Nemotron reports

Fluid's released CoreML conversion reports the following on **16 AMI mixed-headset test meetings**, using forced-aligned references, zero collar, and overlap included, on an M5 Pro:

| Preset | DER | Exact speaker-count accuracy | Reported wall speed |
| --- | ---: | ---: | ---: |
| `fast128` | 9.36% | 100% | 546× real time |
| `offline` | 9.47% | 87.5% | 904× real time |
| `fast32` | 9.53% | 93.8% | 179× real time |
| `c128-split-w8a8` | 9.63% | 100% | 364× real time |

The first three use approximately 190 MB of weights; the split variant uses 95 MB. These are conversion-author reports, not reproduced measurements. `offline` and `fast128` are the useful initial pair for our post-recording job. The small numeric gap from NVIDIA's report is encouraging, but neither export parity nor the claimed explanation of that gap has been independently verified here. [Pinned CoreML model card](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/blob/1b0b133f6f8820292010afd776d8f9fbc9fca17e/README.md).

Other reports corroborate interest without settling the app decision. Argmax OpenBench reports Nemotron AMI DER around 9%/11%, but uses its own SDK variant, updated AMI annotations, and includes training-exposed VoxConverse in a macro average with missing-dataset exclusions. Its September 22 run should not be assumed identical to our final GA export. Voice Arena's early leaderboard reports 14.72% DER across 139 sessions; it has no matched MacParakeet row. These are supporting signals. [Pinned OpenBench report](https://github.com/argmaxinc/OpenBench/blob/e13108070b9693f2646e4a3e22e4b2d0130d779f/BENCHMARKS.md), [Voice Arena publisher](https://voicearena.com/diarization-bench).

The more direct OpenBench comparison uses Argmax implementations of both model families:

| Condition | Community-1 DER | Nemotron DER |
| --- | ---: | ---: |
| AMI distant microphone | 38% | 11% |
| AliMeeting | 23% | 18% |
| DIHARD III | 22% | 13% |
| Earnings-21 | 10% | 20% |

These support a development upgrade and candidate integration, while identifying earnings calls as a regression class to investigate. They are not measurements of our FluidAudio adapter. AMI uses the report's forced-aligned references. [Same benchmark report](https://github.com/argmaxinc/OpenBench/blob/e13108070b9693f2646e4a3e22e4b2d0130d779f/BENCHMARKS.md#diarization-error-rate-der).

Upgrading the dependency alone will not activate Nemotron: the app explicitly constructs `OfflineDiarizerManager`. The new backend needs an adapter and model loading through the existing service boundary. [Current construction](../../Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift).

## Best public data for the decision

There is no single best corpus. Use two complementary meeting sets first, with explicit channel and reference choices:

| Dataset | Recommended use | Availability and caveat |
| --- | --- | --- |
| **AMI test** | First primary gate: 16 meetings, mixed headset and true distant mic scored separately; natural interruptions and overlap. | Public audio under CC BY 4.0. Pin the full-corpus ASR test partition and `only_words` manual RTTM/UEM; optionally rescore the same outputs against NVIDIA's forced-aligned convention. |
| **AliMeeting Test** | Second primary gate: 20 Mandarin meetings, 10 hours, near/far conditions; checks language and acoustic generalization. | OpenSLR distributes CC BY-SA 4.0 data. The 4-hour, 8-meeting “Eval” set is distinct from Test. Fix a single channel or mono conversion. |
| **NOTSOFAR1 evaluation** | Later harder-room extension, if the first comparison is promising. | Public CC BY 4.0 evaluation releases include ground truth. Multiple devices capture the same meetings; do not count those as independent examples. |
| **VoxConverse seven-file slice** | Preserve existing #1046 regression continuity and recognizable failures. | Training-exposed for Nemotron; no held-out winner claim. |
| **DIHARD III / CALLHOME** | Optional domain diversity and connection to published tables. | Licensed LDC distribution; do not assume free access or purchase it for this initial experiment. |

Sources: [AMI corpus](https://groups.inf.ed.ac.uk/ami/corpus/), [AMI license](https://groups.inf.ed.ac.uk/ami/corpus/license.shtml), [pinned AMI annotation setup](https://github.com/pyannote/AMI-diarization-setup/tree/67c2d539286e89f68952d5dcf83912bd9f01dfae), [AliMeeting official distribution](https://www.openslr.org/119/), [NOTSOFAR release guide](https://github.com/microsoft/NOTSOFAR1-CHALLENGE/tree/6f58e08b008f7530ba4141f0aeb02447c70b6fd7), [DIHARD evaluation catalog](https://catalog.ldc.upenn.edu/LDC2022S14).

Public test partitions have already informed model development and published preset selection. Audit both families' training disclosures and label remaining uncertainty; do not describe this as a blind evaluation on never-seen private audio. Keep local development selection separate from the final test. The outcome should also survive a small preselected real meeting sample and long-session checks.

“Meeting fixtures” means repeatable recordings with known expected events: a real one-word “Yes,” an interruption, delayed loudspeaker echo entering the mic, or a remote speaker returning after a long silence. Echo/double-talk fixtures still matter with mic diarization disabled because source reconciliation can remove genuine user speech. Shared-microphone speaker separation is excluded by the user's decision. Synthetic fixtures test deterministic behavior; they cannot establish general model accuracy.

## Why the native SDK route is the first choice

The new SDK exposes `Nemotron3Models`, `Nemotron3Diarizer`, and chunk/full-file processing. Its tagged release includes an M3 ANE compilation fix, but the larger `offline` preset remains GPU-only because of ANE compiler limits. Freeze compute-unit routing when comparing presets; CoreML does not imply ANE execution. Both the old and new package manifests require the same minimum platform/tool version, but the upgrade includes other ASR and binary dependency changes. Compilation and functional regressions remain necessary. [Native documentation](https://github.com/FluidInference/FluidAudio/blob/21493f8dac5a97e65742e6ff26f42f164c2fda0f/Documentation/Diarization/Nemotron3.md), [package manifest](https://github.com/FluidInference/FluidAudio/blob/21493f8dac5a97e65742e6ff26f42f164c2fda0f/Package.swift), [SDK comparison](https://github.com/FluidInference/FluidAudio/compare/41540ea237350afe5117a082b5c28eda642d0612...21493f8dac5a97e65742e6ff26f42f164c2fda0f).

Source inspection found several manageable integration requirements:

- Mutable preallocated model buffers require isolated or serialized ownership. The current adapter's read-only model-sharing assumption cannot simply carry over.
- Complete-file processing is synchronous without inspected cancellation checks. Preserve off-main execution and cancellation, potentially by driving bounded chunks.
- The interval helper defaults to dropping activity shorter than 200 ms; the published benchmark explicitly sets this to zero. Freeze this setting so short replies do not disappear unnoticed.
- The Nemotron benchmark can enumerate only locally available files and fall back to different reference annotations. A comparison manifest must reject missing expected audio or references rather than silently score a smaller/different set.

Sources: [runtime and filtering](https://github.com/FluidInference/FluidAudio/blob/21493f8dac5a97e65742e6ff26f42f164c2fda0f/Sources/FluidAudio/Diarizer/Nemotron3/Nemotron3Diarizer.swift), [model ownership](https://github.com/FluidInference/FluidAudio/blob/21493f8dac5a97e65742e6ff26f42f164c2fda0f/Sources/FluidAudio/Diarizer/Nemotron3/Nemotron3Models.swift), [benchmark implementation](https://github.com/FluidInference/FluidAudio/blob/21493f8dac5a97e65742e6ff26f42f164c2fda0f/Sources/FluidAudioCLI/Commands/Nemotron3DiarizeCommand.swift).

Use final GA weights and pin the actual export directory. The SDK distinguishes them with `ga-2026-09-23`; a preview model or older cached conversion is a different candidate. The public model repository was observed ungated, despite a stale gating note in SDK documentation. [GA asset identity](https://github.com/FluidInference/FluidAudio/blob/21493f8dac5a97e65742e6ff26f42f164c2fda0f/Sources/FluidAudio/ModelNames.swift#L834-L852).

NVIDIA's **NeMo-Speech.cpp** supplies a native ggml/Metal alternative if the Swift path fails a concrete need. Its whole-file offline API differs from chunked `v3-offline`; long streams also compact probability history using default segmentation settings. Those distinctions matter when reproducing scores. Do not adopt an additional runtime merely because Omarchy uses ONNX. [Pinned native runtime](https://github.com/NVIDIA/NeMo-Speech.cpp/tree/97a15afa5caa9bce5baaa86c1184103877af4101), [diarization API](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/97a15afa5caa9bce5baaa86c1184103877af4101/include/nemo_speech/diar.h).

## Product boundaries the benchmark must preserve

Nemotron diarization is separate from Nemotron ASR. It labels speaker activity; it does not separate overlapping waveforms or recover words missed by the recognizer. Existing ASR should remain fixed during the model comparison.

Current MacParakeet contracts include exact counts up to 100, ranged constraints, and a separate WeSpeaker-based identity layer. The new model does not automatically honor those count controls or produce compatible identity embeddings. Keep an honest fallback for unsupported explicit constraints and experimental voice profiles during evaluation. Eight active output channels cannot establish that a ninth person never spoke. [Service/count contract](../../Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift), [voice-profile contract](../../spec/contracts/speaker-voiceprints.md).

The [earlier review](2026-09-25-omarchy-meeting-recorder-diarization-review.md#5-reconcile-the-findings-with-our-existing-1046-work) also verified that current one-word smoothing can erase a correctly diarized acknowledgement. Final meeting rosters and intervals are then rebuilt from the resulting words. Therefore score raw acoustic output and the final transcript separately. A better model can be obscured by current postprocessing; cleaner-looking bubbles can also hide worse recall.

## Reproduction anchors and verification boundary

| Component | Inspected revision |
| --- | --- |
| MacParakeet local / fetched main | `779e9b30fa084e9f56c9a68b2e69ab9e3fdd62b3` / `7ad569afae560266b37a0003e9e2b9f17a2dfa47` |
| FluidAudio baseline 0.15.7 | `41540ea237350afe5117a082b5c28eda642d0612` |
| FluidAudio candidate 0.17.4 | `21493f8dac5a97e65742e6ff26f42f164c2fda0f` |
| NVIDIA final model repository | `f667ed73aee57d40cc39428eb768b4fd87a0a29e` |
| Fluid Nemotron CoreML repository | `1b0b133f6f8820292010afd776d8f9fbc9fca17e` |
| Baseline CoreML provenance documentation | `df2625ac79a7ac6b65ad868fee6d80f320da4232` |
| AMI manual annotation setup | `67c2d539286e89f68952d5dcf83912bd9f01dfae` |
| Candidate common scorer, dscore | [`e02f949ac6592279300a2c33d03daf9e0c12fd27`](https://github.com/nryant/dscore/tree/e02f949ac6592279300a2c33d03daf9e0c12fd27) |

Model-repository revisions identify inspected metadata, not proof of downloaded bytes or successful execution. The runner must add exact asset hashes and reference manifests. Relevant local diarization implementation files match fetched main; unrelated dirty work was preserved.

This review verified primary-source claims, current release availability, source-level integration behavior, and existing app boundaries. It did not download models/datasets, run model inference, reproduce DER, build the app, or qualify hardware. No production code, accepted ADR, user data, or GitHub publication changed. Jev was not used: this was research and planning, with no bounded semantic product behavior implemented.
