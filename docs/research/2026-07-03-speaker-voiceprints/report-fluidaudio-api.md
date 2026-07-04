# FluidAudio v0.15.4 speaker profiles / recognition report

Source: FluidAudio tag `v0.15.4` (`b9d4372`). Paths below are relative to `/private/tmp/claude-502/-Users-dmoon-code-macparakeet/8bbfded2-f315-45ed-b4c9-8dced5e0ca31/scratchpad/FluidAudio`.

**Bottom line:** FluidAudio v0.15.4 does not provide a turnkey persistent "voiceprint profiles" feature for the consuming `OfflineDiarizerManager(config:).process(url:) -> DiarizationResult` path. It provides 256-d speaker embeddings, serializable `Speaker` profile structs, an in-memory `SpeakerManager` for the legacy WeSpeaker/Pyannote streaming path, and instance-local enrollment for Sortformer/LS-EEND. For offline meeting transcription, app code must persist profiles, run diarization, then post-hoc match `DiarizationResult.speakerDatabase`, `chunkEmbeddings`, or `segments[].embedding` to saved profiles and rewrite display labels.

## 1. SpeakerManager / known profile API

`SpeakerManager` is an "in-memory speaker database" and docs explicitly say it is "not currently supported with `OfflineDiarizerManager`" because offline uses VBx clustering (`Documentation/Diarization/SpeakerManager.md:8-10`). Source confirms `public struct SpeakerManager: Sendable` with `public static let embeddingSize = 256` (`Sources/FluidAudio/Diarizer/Clustering/SpeakerManager.swift:8-12`).

Core signatures:
```swift
public init(speakerThreshold: Float = 0.65, embeddingThreshold: Float = 0.45, minSpeechDuration: Float = 1.0, minEmbeddingUpdateDuration: Float = 2.0)
public mutating func initializeKnownSpeakers(_ speakers: [Speaker], mode: SpeakerInitializationMode = .skip, preserveIfPermanent: Bool = true)
public mutating func assignSpeaker(_ embedding: [Float], speechDuration: Float, confidence: Float = 1.0, speakerThreshold: Float? = nil, newName: String? = nil) -> Speaker?
public func findSpeaker(with embedding: [Float], speakerThreshold: Float? = nil) -> (id: String?, distance: Float)
public func findMatchingSpeakers(with embedding: [Float], speakerThreshold: Float? = nil) -> [(id: String, distance: Float)]
```
(`Sources/FluidAudio/Diarizer/Clustering/SpeakerManager.swift:45-64`, `135-141`, `184-200`)

Other public API: `findSpeakers(where:)`, `makeSpeakerPermanent(_:)`, `revokePermanence(from:)`, `mergeSpeaker(_:into:mergedName:stopIfPermanent:)`, `findMergeablePairs(speakerThreshold:excludeIfBothPermanent:)`, `removeSpeaker(_:keepIfPermanent:)`, `removeSpeakersInactive(since:keepIfPermanent:)`, `removeSpeakersInactive(for:keepIfPermanent:)`, `removeSpeakers(where:keepIfPermanent:)`, `removeSpeakers(where:)`, `hasSpeaker(_:)`, `getAllSpeakers()`, `getSpeakerList()`, `getSpeaker(for:)`, `upsertSpeaker(_:)`, `upsertSpeaker(id:name:currentEmbedding:duration:rawEmbeddings:updateCount:createdAt:updatedAt:isPermanent:)`, `reset(keepIfPermanent:)`, `resetPermanentFlags()`, plus properties `speakerCount`, `speakerIds`, `permanentSpeakerIds` (`SpeakerManager.swift:217-635`). Extension methods: `reassignSegment(segmentId:from:to:)`, `getCurrentSpeakerNames()`, `getGlobalSpeakerStats()` (`Sources/FluidAudio/Diarizer/Clustering/SpeakerOperations.swift:516-592`).

Matching uses cosine **distance**, not similarity: `SpeakerUtilities.cosineDistance(_:_:)` returns `1 - clampedSimilarity`, so `0` is identical and `2` opposite (`SpeakerOperations.swift:59-100`). Standalone defaults are max distance `0.65` for assignment and `0.45` for embedding update; through `DiarizerManager(config: .default)`, defaults become `0.7 * 1.2 = 0.84` and `0.7 * 0.8 = 0.56` (`Sources/FluidAudio/Diarizer/Core/DiarizerManager.swift:24-35`; `Sources/FluidAudio/Diarizer/Core/DiarizerTypes.swift:7-15`). Docs recommend tuning distance thresholds around `0.6-0.7` clean audio and `0.7-0.8` noisy audio, with distance interpretation `<0.3` very high confidence same speaker, `0.5-0.7` medium confidence, `>0.9` different (`SpeakerManager.md:507-526`).

Persistence: `Speaker` and `RawEmbedding` are `Codable`, but `SpeakerManager` has no save/load API (`Sources/FluidAudio/Diarizer/Clustering/SpeakerTypes.swift:6`, `207-217`). Persist `[Speaker]` yourself and reload with `initializeKnownSpeakers` or `upsertSpeaker`. `Speaker` stores `currentEmbedding`, `duration`, `rawEmbeddings`, and `isPermanent`; raw embeddings are capped at 50 and profile embedding can be recalculated from their average (`SpeakerTypes.swift:36-55`, `103-162`). `updateMainEmbedding(duration:embedding:segmentId:alpha: Float = 0.9)` adds a raw embedding and then applies EMA (`SpeakerTypes.swift:68-101`). Caveat: source updates matched speakers only on `distance < embeddingThreshold`; it does **not** check `minEmbeddingUpdateDuration` in `updateExistingSpeaker` despite the doc wording (`SpeakerManager.swift:432-459`).

## 2. Embedding extraction and priming/enrollment

Classic WeSpeaker/Pyannote extraction:
```swift
public func extractSpeakerEmbedding<C>(from audio: C) throws -> [Float]
where C: RandomAccessCollection, C.Element == Float, C.Index == Int
```
This builds an all-ones mask from the Pyannote segmentation output frame count, then calls WeSpeaker extraction (`Sources/FluidAudio/Diarizer/Core/DiarizerManager.swift:78-119`). Model constants are `pyannote_segmentation.mlmodelc` and `wespeaker_v2.mlmodelc` (`Sources/FluidAudio/ModelNames.swift:280-291`). Underlying extractor:
```swift
public func getEmbeddings<C>(audio: C, masks: [[Float]], minActivityThreshold: Float = 10.0) throws -> [[Float]]
where C: RandomAccessCollection, C.Element == Float, C.Index == Int
```
It runs the WeSpeaker model and returns 256-d embeddings (`Sources/FluidAudio/Diarizer/Extraction/EmbeddingExtractor.swift:16-32`, `201-205`). It uses 10 s / 160,000-sample waveform buffers and repeat-pads shorter non-empty audio (`EmbeddingExtractor.swift:37`, `117-150`). There is no hard minimum duration inside `extractSpeakerEmbedding`; `validateAudio` separately flags `<1s`, and docs say `<3s` may fail/unreliable, `3-5s` minimum viable, `10s` optimal (`Sources/FluidAudio/Diarizer/Segmentation/AudioValidation.swift:5-28`; `Documentation/Diarization/GettingStarted.md:413-425`).

There is no `primeWithAudio` symbol in v0.15.4. The priming/enrollment APIs are:
```swift
public func enrollSpeaker(withAudio samples: [Float], sourceSampleRate: Double? = nil, named name: String? = nil, overwritingAssignedSpeakerName overwriteAssignedSpeakerName: Bool = true) throws -> DiarizerSpeaker?
public func enrollSpeaker<C: Collection>(withAudio samples: C, sourceSampleRate: Double? = nil, named name: String? = nil, overwritingAssignedSpeakerName overwriteAssignedSpeakerName: Bool = true) throws -> DiarizerSpeaker? where C.Element == Float
```
on `SortformerDiarizer` (`Sources/FluidAudio/Diarizer/Sortformer/SortformerDiarizer.swift:189-216`) and the generic form on `LSEENDDiarizer` (`Sources/FluidAudio/Diarizer/LS-EEND/LSEENDDiarizer.swift:289-294`). Sortformer enrollment warms `spkcache`/FIFO and names the most active slot; default minimum before it can process is `(chunkLen + chunkRightContext) * frameDurationSeconds = (6 + 7) * 0.08 = 1.04s` (`SortformerDiarizer.swift:225-324`; `Sources/FluidAudio/Diarizer/Sortformer/SortformerTypes.swift:27-35`, `107-119`). This is not a persistent embedding/profile store.

## 3. Offline result embeddings and pre-matching

`DiarizationResult` exposes:
```swift
public let segments: [TimedSpeakerSegment]
public let speakerDatabase: [String: [Float]]?
public let chunkEmbeddings: [ChunkEmbedding]?
public let timings: PipelineTimings?
```
and each `TimedSpeakerSegment` has `speakerId`, `embedding`, timestamps, and `qualityScore` (`Sources/FluidAudio/Diarizer/Core/DiarizerTypes.swift:161-185`, `191-212`). `OfflineDiarizerManager.process(_ url: URL, progressCallback: ...) async throws -> DiarizationResult` always builds `speakerDatabase`; `chunkEmbeddings` requires `OfflineDiarizerConfig.exposeChunkEmbeddings = true` (`Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift:112-139`, `341-365`; `Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerTypes.swift:219-240`). Offline embeddings are generated by the Community-1-style pipeline: 10 s Pyannote segmentation, audio+weights embedding extraction, L2-normalized 256-d embeddings, PLDA/VBx clustering (`Documentation/Diarization/GettingStarted.md:252-270`; `Sources/FluidAudio/ModelNames.swift:294-318`).

Known-speaker profiles cannot be passed into `OfflineDiarizerManager` so output IDs come pre-matched. Offline labels are generated as `"S\(cluster + 1)"` from VBx clusters; `speakerDatabase` is an average of per-segment cluster embeddings (`Sources/FluidAudio/Diarizer/Offline/Utils/OfflineReconstruction.swift:222-276`, `322-350`). Matching saved profiles to offline runs is therefore post-hoc only.

## 4. Streaming support and caveats

Classic `DiarizerManager` can use `initializeKnownSpeakers(_:)` before streaming/chunked diarization, and its returned `speakerId`s can be known IDs when `SpeakerManager` matches them. Sortformer/LS-EEND support instance-local enrollment and `processComplete(..., keepingEnrolledSpeakers:)`, but not persistent voiceprints (`SortformerDiarizer.swift:568-626`; `LSEENDDiarizer.swift:161-188`). Sortformer docs explicitly say no persistent speaker embeddings and max 4 speakers (`Documentation/Diarization/Sortformer.md:14-18`, `496-500`). LS-EEND docs warn enrollment can collide for similar voices, scores are bounded around `0.2-0.8`, and there is no per-slot similarity or explicit slot-lock API (`Documentation/Diarization/LS-EEND.md:276-289`).

## 5. Newer release notes

Checked GitHub releases on July 4, 2026: `v0.15.4` is marked `Latest`, and the release list contains no releases newer than `v0.15.4` (`https://github.com/FluidInference/FluidAudio/releases`, `https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.4`). Therefore there are no newer release-note speaker-recognition features to account for.
