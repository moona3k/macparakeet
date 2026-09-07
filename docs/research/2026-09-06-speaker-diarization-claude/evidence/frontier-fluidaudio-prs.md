### PR #802
fix(offline-diarizer): pyannote-parity clustering — threshold semantics, constraint count, constrained assignment
merged: 2026-08-19T02:48:02Z

### Why is this change needed?

Fixes #801: `OfflineDiarizerManager` with `.default` config and with `clustering.numSpeakers = 2` returned the **same speaker count (2) but materially different partitions** (69% vs 92% correctly-attributed speech on the reporter's 2-speaker clip). Every observation in the reporter's 20-config sweep decodes exactly to three porting bugs against pyannote community-1's `VBxClustering`:

**1. AHC threshold was inverted (issue Q2 — confirmed).** The config value is documented as a "Euclidean distance threshold for unit-normalized embeddings", and pyannote applies it directly as the dendrogram cut: `fcluster(dendrogram, threshold, criterion="distance")`. Our port reinterpreted it as a cosine similarity and cut at `sqrt(2 − 2t)`, which inverts the knob (raising it split more instead of merging more) and shifted the default 0.6 to an effective cut of 0.894. The reporter's sweep maps perfectly through this formula: 0.3/0.4/0.45 → cuts 1.18/1.10/1.05 (merged to 1 speaker), while 0.6–1.1 → cuts 0.894–0.0 (byte-identical near-singleton AHC output). The value is now applied directly, clamped/validated to (0, 2].

**2. Speaker-count constraints compared against the wrong count (issue Q1 — it's a bug).** pyannote decides whether to fall back to K-Means by comparing the requested count against `auto_num_clusters` — the clusters VBx actually kept (`pi > 1e-7`). We compared against the AHC warm-start count, which on this audio was far above 2 (AHC produced near-singletons, VBx collapsed them to 2). So `numSpeakers=2` always triggered K-Means re-clustering — a completely different algorithm — even though auto had already detected 2. Hence same N, different partition. The check now uses the new `VBxOutput.activeClusterCount`. This also explains the reporter's side observations: `minSpeakers=2` never bound (compared against the inflated count), and `numSpeakers=2 + threshold=0.5` "cancelling the win" (cut 1.0 made AHC itself return 2, so the constraint stopped binding).

**3. Missing constrained assignment (the actual quality gap).** Fixing (2) alone would regress the reporter's clip to the bad 69% partition — the K-Means path was accidentally winning. pyannote assigns embeddings with `constrained_argmax`: local speakers sharing a segmentation chunk must map to **distinct** clusters (Hungarian matching per chunk, maximizing total similarity). Our plain per-embedding argmax let two co-chunk speakers snap to the same centroid, silently absorbing one speaker's turns into another's — the mechanism behind the bad 82s-boundary partition. Ported it behind `Clustering.constrainedAssignment` (default true), auto-disabled when the count is forced via K-Means, matching pyannote. The Hungarian solver moved from `DiarizationDER.swift` into an internal `HungarianAssignment` enum with a rectangular max-score wrapper.

### Behavior change / migration

The `threshold` knob keeps its numeric default (0.6, the community-1 value) but its **meaning changes to pyannote's**: larger = more merging = fewer speakers. Old values map to new ones via `sqrt(2 − 2·old)` — old 0.6 behaved like 0.894, and the old AMI advice of `--threshold 0.7` corresponds to `0.775` today. `Benchmarks.md` and CLI help are updated; the AMI-SDM offline table should be re-benchmarked on this branch since it was measured under the old semantics.

### Validation

- Unit tests for the threshold direction/extremes, `activeClusterCount`, the Hungarian solver, and the constrained assigner (including the exact #801 failure mode: two co-chunk embeddings both nearest to the same centroid).
- `swift build` + swift-format clean; XCTest runs in CI (unavailable locally).
- The reporter offered to re-run patches against their private audio — a build of this branch with stock `.default` config is the ideal check; the prediction is the auto path now finds the 62s boundary on its own.
- Caveat: pyannote community-1's `config.yaml` is gated on HF, so the shipped `ahc_threshold` (assumed 0.6-as-distance, within the code's `Uniform(0.5, 0.8)` prior) is inferred from source semantics, not read from the config.

### PR #652
feat(speaker): CAM++ speaker-embedding backend (CoreML) [beta]
merged: 2026-08-18T23:54:48Z

> [!NOTE]
> **Beta launch** — this backend ships as a beta: the public API surface and hosted model assets may still change in response to feedback before it is declared stable.

## Summary

Adds **CAM++** (FunASR, ~7.2M) as a CoreML speaker-embedding extractor for speaker verification / diarization clustering. Model: [`FluidInference/campplus-coreml`](https://huggingface.co/FluidInference/campplus-coreml).

## Pipeline

```
waveform → [Preprocessor fp32/CPU] → fbank [1,T,80]
        → [CAM++ fp16, RangeDim] → [1,192] → L2 normalize
        → cosine similarity for verification / clustering
```

CAM++ uses a **dynamic time dim (RangeDim)** so it runs on variable-length audio without padding (padding would corrupt the statistics-pooled embedding). The ANE compiler rejects RangeDim, so it runs on CPU/GPU — fine for a 7.2M model.

## Changes

- `ModelNames`: `campPlus` `Repo` + `CampPlus` registry
- `Sources/FluidAudio/Speaker/`: `CampPlusModels` (download/load), `CampPlusEmbedder` (audio → 192-d embedding + cosine)
- CLI: `campplus-embed <a.wav> [b.wav]` (embedding, or speaker-verification cosine)

## Verification

End-to-end on M5 Pro:
- Same speaker: **cosine 0.74** → "same speaker"
- Different speakers: **cosine 0.35** → "different"

Clear separation. CoreML↔torch embedding cosine 0.9997–0.99999.

## Notes

- Overlaps FluidAudio's existing `Diarizer` embedding extractor — lands as an alternative.
- A full speaker-verification EER (CN-Celeb trials) is future work; this PR validates functional speaker discrimination.

### PR #735
fix(diarization): deterministic & robust offline VBx re-clustering (K-Means n_init)
merged: 2026-06-24T13:20:43Z

## Summary

The offline diarization speaker-count adjustment — re-clustering VBx-detected clusters down to the constrained count (`numSpeakers` / `min`–`max`) — calls `KMeansClustering` with a **random seed** and a **single initialization**. This makes the result both **non-deterministic** and **fragile**: small / boundary speakers collapse run-to-run.

## Reproduction

A 4-speaker Japanese meeting clip (~7 min, 16 kHz mono), `process --mode offline --num-speakers 4 --step-ratio 0.1`, repeated runs on **identical audio + config**:

| run | speaker confusion vs hand-corrected reference | smallest speaker (~41 s) recall |
|-----|-----------------------------------------------|----------------------------------|
| 1   | ~10.9%                                        | ~80% (kept)                      |
| 2   | ~32.0%                                        | ~15% (collapsed)                 |
| 3   | ~10.9%                                        | ~80% (kept)                      |

The only thing varying between runs is the K-Means random seed; the smallest speaker flips between kept and merged-away.

## Root cause

- `KMeansClustering.clusterWithCentroids` initializes its RNG as `SeededRNG(seed: seed ?? UInt64.random(in: 0...UInt64.max))` → a random seed whenever the caller doesn't pass one.
- The `VBxClustering` speaker-count re-clustering (`Speaker count N outside bounds […]; re-clustering to K`) calls `KMeansClustering.clusterWithCentroids(...)` **without a seed and with a single init** (no `n_init` / best-of-N inertia selection).

So the final hard assignment of an over-segmented frame set down to `K` speakers depends on one random K-Means initialization, which is unstable for fragile / imbalanced speaker sets.

This re-clustering path was introduced in #236 (which made the `numSpeakers` constraint actually apply the K-Means centroids); it simply never seeded the K-Means or used `n_init`, so the constrained result was left non-deterministic.

## Fix

- `KMeansClustering`:
  - The unseeded fallback now uses a fixed seed (`0`) instead of `UInt64.random` → deterministic by default.
  - Added `clusterWithCentroidsNInit(embeddings:numClusters:maxIterations:nInit:baseSeed:)` which runs `nInit` deterministic initializations (seeds `baseSeed … baseSeed+nInit-1`) and returns the lowest-inertia result (sklearn-style `n_init`).
- `VBxClustering`: the speaker-count re-clustering now calls `clusterWithCentroidsNInit(nInit: 10, baseSeed: 0)`.

No breaking API changes — `clusterWithCentroids` keeps its signature (its unseeded path is just deterministic now); `clusterWithCentroidsNInit` is additive.

## Result

Re-clustering is now fully deterministic and robustly retains fragile speakers. The 4-speaker clip scores **~9.2% consistently across 5+ CLI runs and on-device (CoreML / ANE, sandboxed macOS app)**.

## Related

- **#236** introduced this K-Means re-clustering path (applying the speaker-count constraint via K-Means centroids); this PR makes that path deterministic and robust.
- **#523** fixed a different cause of single-speaker collapse (transpose / mask bugs); this PR is orthogonal — it addresses the run-to-run *non-determinism* of the constrained re-clustering.
- **#393** (closed, not merged) already used a fixed seed to make a Sortformer test reproducible — the same underlying concern (time/random seeds break reproducibility), here applied to the production offline re-clustering.


### PR #789
OfflineDiarizerManager: split process() into prepare()/cluster() for cacheable segmentation+embeddings
merged: 2026-07-15T04:15:01Z

### Why is this change needed?

`OfflineDiarizerManager.process()` bundles segmentation → embedding extraction → clustering into one monolithic call. Segmentation and embedding extraction are **deterministic** and dominate the runtime (CoreML inference over the whole audio), while clustering (AHC + VBx) is the only stage whose outcome callers may want to vary or re-run — e.g. multi-run candidate selection with exact speaker-count constraints, or refiners sweeping clustering thresholds. Today such consumers must repeat the identical inference stages 2–3× just to vary clustering.

### What this PR does

Splits `process()` into two composable phases, with the existing API preserved:

- **`prepare(audio:)` / `prepare(audioSource:audioLoadingSeconds:)`** — runs segmentation + embedding extraction (concurrent, internals unchanged) and returns a cacheable `PreparedDiarization` handle.
- **`cluster(_:)`** — runs AHC + VBx clustering, centroid assignment, reconstruction, and the configured post-passes (zero-vote re-embed, short-segment relabel) over a prepared handle. Callable any number of times per `prepare`.
- **`process()` is now exactly `prepare()` + `cluster()`** — behavior, stage ordering, error surface, and `PipelineTimings` semantics are preserved.

`PreparedDiarization` is an opaque `Sendable` value type: its stored fields are internal implementation types, it retains the `AudioSampleSource` (clustering post-passes re-embed exact audio spans), and it exposes only `embeddingCount` / `segmentationChunkCount`.

```swift
let prepared = try await manager.prepare(audio: samples)
let runA = try manager.cluster(prepared)
let runB = try manager.cluster(prepared)   // no re-segmentation, no re-embedding
```

No changes to segmentation, embedding, or clustering internals.

### Measurements

Same audio, same config, real models:

| Scenario | Wall time |
|---|---|
| Baseline: `process()` × 2 | 1.314 s |
| Two-phase: `prepare()` once (0.588 s) + `cluster()` × 2 (~7–8 ms each) | 0.602 s (**54% saved**) |
| At runCount = 3 | **69% saved** |

All output fingerprints are bit-identical between `process()` and the equivalent `prepare()`+`cluster()` sequence, and across repeated `cluster()` calls on the same prepared handle.

### Testing

- `swift build` clean on current `main`.
- Full test suite green on current `main` (`swift test --parallel`).
- `swift format lint` clean on the changed files.


