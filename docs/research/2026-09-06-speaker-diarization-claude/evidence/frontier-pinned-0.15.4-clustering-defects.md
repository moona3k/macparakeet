# Evidence: the three clustering defects fixed by FluidAudio PR #802 are present in the pinned 0.15.4 checkout

Observed 2026-09-06 in /Users/dmoon/code/macparakeet/.build/checkouts/FluidAudio at
b9d43724cbdb5a980e441fd54180964e94d470f7 (tag v0.15.4, 2026-06-16). PR #802 merged 2026-08-19
(commit df1417ce, released in v0.15.6). PR body is in frontier-fluidaudio-prs.md.

## Defect 1: AHC threshold interpreted as cosine similarity and converted to a distance

Sources/FluidAudio/Diarizer/Offline/Clustering/AHCClustering.swift:107-115

```swift
    // MARK: - Similarity-to-Distance Conversion
    private func convertThresholdToDistance(_ similarity: Double) -> Double {
        guard !similarity.isNaN else { return Double.infinity }
        if similarity < -1.0 || similarity > 1.0 {
            logger.debug("Clustering threshold \(similarity) outside cosine range; clamping to [-1, 1]")
        }
        let clamped = max(-1.0, min(1.0, similarity))
        return sqrt(max(0, 2.0 - 2.0 * clamped))
    }
```

While the config documents the same field as a distance:
Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerTypes.swift:121-122
```swift
        /// Euclidean distance threshold for unit-normalized embeddings.
        public var threshold: Double
```
Effect (per PR #802): the community-1 default 0.6 behaves as a dendrogram cut of 0.894 instead of 0.6,
and raising the knob splits more instead of merging more.

## Defect 2: speaker-count constraint compared against the wrong count, then K-Means re-clustering

Sources/FluidAudio/Diarizer/Offline/Clustering/VBxClustering.swift:685-711

```swift
        var output = refine(rhoFeatures: rhoFeatures, initialClusters: initialClusters)
        ...
        let detectedCount = output.numClusters
        guard constraints.needsAdjustment(detectedCount: detectedCount) else {
            return output
        }
        let targetCount = constraints.targetCount(detectedCount: detectedCount)
        ...
        let (kmeansClusters, centroids) = KMeansClustering.clusterWithCentroids(
            embeddings: trainingEmbeddings,
            numClusters: targetCount,
            maxIterations: 100
        )
```
PR #802 states pyannote compares against the clusters VBx actually kept (pi > 1e-7), not the
warm-start count, so exact/min constraints in 0.15.4 can trigger a different algorithm even when the
automatic path already found the right count. No `activeClusterCount` exists in the pinned tree.

## Defect 3: no constrained (Hungarian) assignment of co-chunk local speakers

`grep -rn "constrainedAssignment|constrained_argmax|Hungarian" Sources/FluidAudio/Diarizer/Offline`
returns nothing in the pinned tree. PR #802 adds `Clustering.constrainedAssignment` (default true).

## Related: non-deterministic K-Means fallback (fixed by PR #735, released in v0.15.5)

Sources/FluidAudio/Diarizer/Offline/Clustering/KMeansClustering.swift:64
```swift
        var rng = SeededRNG(seed: seed ?? UInt64.random(in: 0...UInt64.max))
```
and the VBx call above passes no seed and no n_init. PR #735 reports run-to-run speaker confusion of
~10.9% vs ~32.0% on the same 4-speaker clip depending only on the random seed.

## MacParakeet call site

Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift:205 starts from
`OfflineDiarizerConfig.default` and only applies the speaker-count constraint, so every default above
(threshold 0.6 as mis-interpreted, stepRatio 0.2, minSegmentDurationSeconds 1.0) is what ships.
