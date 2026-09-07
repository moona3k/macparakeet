# Evidence: FluidAudio 0.15.4 offline diarizer defaults and pipeline order

Checkout: /Users/dmoon/code/macparakeet/.build/checkouts/FluidAudio at
b9d43724cbdb5a980e441fd54180964e94d470f7 (tag v0.15.4, commit date 2026-06-16).
Observed 2026-09-06 by reading the Swift source. Nothing was built or run.

## OfflineDiarizerConfig defaults (`OfflineDiarizerTypes.swift`)

| Stage | Field | Default | Lines |
|---|---|---|---|
| Segmentation | windowDurationSeconds | 10.0 | 46-55 |
| Segmentation | sampleRate | 16000 | 46-55 |
| Segmentation | minDurationOn / minDurationOff | 0.0 / 0.0 | 46-55 |
| Segmentation | stepRatio | 0.2 (2 s hop, comment: "~1.4% worse DER but 2x the speed") | 51-52 |
| Segmentation | onset / offset thresholds | 0.5 / 0.5 (ignored by powerset model per comment at 35-36) | 53-54 |
| Embedding | batchSize | 32 | 100-105 |
| Embedding | excludeOverlap | true | 100-105 |
| Embedding | minSegmentDurationSeconds | 1.0 | 100-105 |
| Embedding | skipStrategy | .none | 100-105 |
| Clustering | threshold | 0.6 (doc comment says "Euclidean distance threshold for unit-normalized embeddings") | 121-122, 137-144 |
| Clustering | warmStartFa / warmStartFb | 0.07 / 0.8 | 137-144 |
| Clustering | min/max/numSpeakers | nil | 137-144 |
| VBx | maxIterations / convergenceTolerance | 20 / 1e-4 | 168-171 |
| PostProcessing | minGapDurationSeconds | 0.1 | 191-194 |
| PostProcessing | exclusiveSegments | true | 191-194 |
| Result | exposeChunkEmbeddings | false | 219-223 |

`OfflineDiarizerConfig.default` is `OfflineDiarizerConfig()` (494-496).

Discrepancy: `Documentation/Diarization/BenchmarkAMISubset.md:22` states the default clustering
threshold is 0.7; the code default is 0.6. `DiarizerTypes.swift:9` (the legacy online
`DiarizerConfig`) has `clusteringThreshold: Float = 0.7`, which is likely what the doc refers to.

## Threshold semantics (`AHCClustering.swift`)

`convertThresholdToDistance(_ similarity:)` clamps the value to [-1, 1] and returns
`sqrt(2 - 2*similarity)` (108-115). With 0.6 the cut distance on L2-normalized 256-d WeSpeaker
embeddings is sqrt(0.8) = 0.894. Linkage is fastcluster centroid linkage (39-50). Clusters are
formed by cutting the dendrogram at that distance (118-191).

## Pipeline order (`OfflineDiarizerManager.process(audioSource:...)`, lines 135-366)

1. Segmentation task and embedding task run concurrently over an AsyncThrowingStream of chunks
   (153-218).
2. Segmentation (`OfflineSegmentationProcessor.swift`): powerset with 3 local speaker slots
   (15-24, 63); per frame argmax over 7 classes gives binary 0/1 activations per local speaker
   (327-335, 393-399); soft probabilities are kept only for logging (348-391).
3. Embedding extraction (`OfflineEmbeddingExtractor.swift`): per (chunk, local speaker) mask.
   Overlap frames (more than one active local speaker) are zeroed when excludeOverlap is on
   (361-377, 441-446). A mask whose clean active frames are below 20% of the window
   (`minActiveRatio = 0.2`, hard-coded, 449-454) produces no embedding. If the clean mask has
   fewer frames than minSegmentDuration (1.0 s) the base mask (with overlap) is used instead
   (457-464). Embedding 256-d then PLDA rho 128-d (319-349).
4. Clustering: NaN filter (490-510); AHC on all embeddings with threshold (247-255); VBx warm
   start from AHC labels with speakerCount = number of AHC clusters (`VBxClustering.refine`,
   41-165). VBx can merge (pi collapses to ~0) but never splits. Constraints, if any, trigger
   K-Means re-clustering to the target count (`refineWithConstraints`, 685-723).
5. Centroids from VBx gamma for speakers with pi > 1e-7 (512-590); then every embedding
   (including NaN-filtered ones) is reassigned to the nearest centroid by cosine (687-710).
6. Reconstruction (`OfflineReconstruction.buildSegments`, 19-220): per global frame, the
   expected speaker count is the rounded mean of the binary activation sum across overlapping
   windows (139-150), and the top-k clusters by summed activation are active (161-168). Runs are
   turned into segments; same-speaker gaps <= 0.1 s merge (353-385); segments shorter than 1.0 s
   are dropped (403-411); with exclusiveSegments the later segment start is trimmed to the
   previous end and the trimmed remainder must still be >= 1.0 s (281-320).
7. Segment speaker IDs are "S<cluster+1>" (322-351). `speakerDatabase` (per-speaker averaged
   centroid, 222-279) and optional `chunkEmbeddings` (341-348) are returned but MacParakeet
   ignores both.

## Errors

`OfflineDiarizationError.noSpeechDetected` is thrown when no embedding survived (228-230); the
segmentation processor throws the same for empty audio (32-34, 51-53).

## Offline diarizer history visible in the checkout (`git log -- Sources/FluidAudio/Diarizer/Offline`)

- 30599f9c 2026-04-21 "Fix offline diarization pipeline producing single-speaker output (#523)":
  vDSP_mtrans dimension swap, missing 20% activity ratio filter, soft masks replaced by binary
  argmax masks. Commit message claims 97% F1 vs PyTorch pyannote on one 467 s 3-speaker file.
- fe4b4df2 2026-04-04 opt-in embedding skip strategy (#480).
- d11ef65f 2026-05-16 progress callback (#615).
- 92928c04 2026-05-29 expose per-chunk embeddings (#633).
No changes after v0.15.4 are visible locally.

## FluidAudio-reported benchmark numbers (attributed, from `Documentation/Diarization/BenchmarkAMISubset.md`)

Hardware: 2024 MacBook Pro M4 Pro 48 GB, macOS 26.0. Dataset: AMI SDM 4-meeting subset.
Scoring: collar 0.25 s, overlap ignored. Speaker count not oracle (the table reports detected/true).
Offline VBx: avg DER 12.0% (miss 7.7, FA 1.6, SE 2.7), RTFx 60.4x; TS3003a found 2 of 4 speakers.
Doc also claims full 16-meeting AMI SDM 10.62% DER with 12/16 correct speaker counts, and
VoxConverse 232 clips 15.07% DER. `CLAUDE.md:164` in the same checkout still says "17.7% DER on AMI".
Whether these numbers were produced before or after fix #523 is not stated.

## Public DER utility

`Sources/FluidAudio/Diarizer/DiarizationDER.swift` exposes `DiarizationDER.compute(ref:hyp:frameStep:collar:)`
returning DER, confusion, false alarm, miss, and the Hungarian label mapping (26-57). It is usable
from MacParakeet tests without a Python dependency.
