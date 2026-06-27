import AVFoundation
import CoreML
import FluidAudio
import Foundation
import os

private final class CancellationResponsiveTaskAwaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let pendingResult: Result<Void, Error>?
                lock.lock()
                if let result {
                    pendingResult = result
                } else {
                    self.continuation = continuation
                    pendingResult = nil
                }
                lock.unlock()

                if let pendingResult {
                    continuation.resume(with: pendingResult)
                }
            }
        } onCancel: {
            resume(with: .failure(CancellationError()))
        }
    }

    func resume(with result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }
}

/// Wraps FluidAudio's `CoherePipeline` (Cohere Transcribe 03-2026, a 2B
/// Conformer encoder + lightweight Transformer decoder converted to Core ML by
/// Fluid Inference). Cohere is a **batch, record-then-transcribe** engine: it
/// has no streaming/partial path and emits no word timestamps, so it does not
/// conform to ``NativeLiveDictating`` and `STTResult.words` is always empty.
///
/// ## Compute policy
/// The big INT8 encoder behaves very differently per Core ML backend:
/// - **`.gpu`** (`.all`): warm ~0.4–0.6 s. Core ML specializes the
///   graph on the **first transcribe of every launch (~115 s, not cached)**, so
///   we pay it in the background via a launch warm-up; for a resident app that
///   is once per session, then every dictation is fast.
/// - **`.ane`** (`cpuAndNeuralEngine`, default): warm ~1.3–1.6 s after Core
///   ML preparation. Fresh app processes can still pay a cold preparation
///   cost, but this avoids the GPU path's uncached per-launch specialization
///   and leaves the GPU free for the LLM formatter.
/// NOTE: most apparent slowness in development is the unoptimized **Debug**
/// build — the per-step decoder + mel hot path runs ~9× slower than release.
/// Always judge latency from a release build.
public actor CohereTranscribeEngine: STTTranscribing {

    /// Core ML compute-unit policy for the Cohere models. See the type doc for
    /// the latency/cold-start tradeoff measured in the Phase-0 spike.
    public enum ComputePolicy: String, CaseIterable, Sendable {
        /// `cpuAndNeuralEngine` — default. Warm ~1.3–1.6 s after Core ML
        /// preparation; avoids the GPU path's recurring per-launch specialization.
        case ane
        /// `.all` — warm ~0.4–0.6 s; ~115 s graph specialization on the
        /// first transcribe of every launch (not cached), hidden by launch warm-up.
        case gpu

        public static let defaultsKey = "cohereComputePolicy"

        public static func current(defaults: UserDefaults = .standard) -> ComputePolicy {
            guard let raw = defaults.string(forKey: defaultsKey),
                let policy = ComputePolicy(rawValue: raw)
            else {
                return .ane
            }
            return policy
        }

        var computeUnits: MLComputeUnits {
            switch self {
            case .ane: return .cpuAndNeuralEngine
            case .gpu: return .all
            }
        }
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "CohereTranscribeEngine")

    private let computePolicy: ComputePolicy
    /// Default transcription language. Cohere requires the language up front
    /// (no auto-detect); English is the Phase-1 default. A per-call override is
    /// threaded through ``transcribe(audioURL:job:language:onProgress:)``.
    private let defaultLanguage: CohereAsrConfig.Language

    /// `CoherePipeline` is itself an actor and holds no per-call mutable state
    /// (it takes `LoadedModels` as an argument), so a single instance serves
    /// every job kind (dictation, file, meeting) safely. Cohere is batch-only,
    /// so transcriptions are serialized by ``transcriptionPermit`` rather than
    /// racing multiple `CoherePipeline` calls through the same loaded models.
    private let pipeline = CoherePipeline()
    private let transcriptionPermit = AsyncPermit()
    private var models: CoherePipeline.LoadedModels?
    private var initializationTask: Task<Void, Error>?
    private var activeLoadID: UUID?

    public init(
        computePolicy: ComputePolicy = .ane,
        defaultLanguage: CohereAsrConfig.Language = .english
    ) {
        self.computePolicy = computePolicy
        self.defaultLanguage = defaultLanguage
    }

    /// Convenience initializer for callers that resolve a language as a string
    /// code (e.g. the CLI, which must not import FluidAudio to name
    /// `CohereAsrConfig.Language`). Unknown or empty codes fall back to English,
    /// matching the no-auto-detect Phase-1 default. The code becomes the engine's
    /// default language for the no-`language:` `transcribe(audioPath:job:)` path.
    public init(computePolicy: ComputePolicy = .ane, defaultLanguageCode: String?) {
        self.computePolicy = computePolicy
        self.defaultLanguage = Self.cohereLanguage(defaultLanguageCode) ?? .english
    }

    // MARK: - Languages

    /// The languages Cohere Transcribe supports, as `(code, displayName)` pairs
    /// (e.g. `("en", "English")`). Source of truth is FluidAudio's
    /// `CohereAsrConfig.Language`; exposed here so UI layers can offer a picker
    /// without importing FluidAudio. Cohere has no auto-detect — one must be set.
    public static var supportedLanguages: [(code: String, name: String)] {
        CohereAsrConfig.Language.allCases.map { ($0.rawValue, $0.englishName) }
    }

    // MARK: - Transcription

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        try await transcribe(
            audioURL: URL(fileURLWithPath: audioPath),
            job: job,
            language: nil,
            onProgress: onProgress
        )
    }

    public func transcribe(
        audioURL: URL,
        job: STTJobKind,
        language: String?,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        try await transcriptionPermit.wait()
        defer { transcriptionPermit.signal() }

        do {
            // Lazy path (CLI, or first dictation before background warm-up
            // finished): log model-load progress to the console.
            try await prepare(onProgress: { [logger] message in
                logger.notice("cohere_prepare \(message, privacy: .public)")
            })
            guard let models else { throw STTError.modelNotLoaded }

            onProgress?(0, 100)
            try Task.checkCancellation()
            let resamplingTask = Task.detached(priority: .userInitiated) {
                try AudioConverter().resampleAudioFile(audioURL)
            }
            let samples = try await withTaskCancellationHandler {
                try await resamplingTask.value
            } onCancel: {
                resamplingTask.cancel()
            }
            onProgress?(40, 100)
            try Task.checkCancellation()

            let resolvedLanguage = Self.cohereLanguage(language) ?? defaultLanguage
            let text = try await transcribeGuardingTruncation(
                samples: samples, models: models, language: resolvedLanguage)
            onProgress?(100, 100)

            // Cohere ASR exposes no word timestamps or per-word confidence, so
            // `words` is intentionally empty. Meeting speaker-diarization,
            // word-level timing, and the live preview are all word-driven, so a
            // meeting transcribed by Cohere degrades to a plain-text transcript
            // (same graceful path Nemotron already uses); Parakeet remains the
            // choice when speaker-labeled, timestamped meetings are wanted.
            return STTResult(
                text: text,
                words: [],
                language: resolvedLanguage.rawValue,
                engine: .cohere,
                engineVariant: computePolicy.rawValue
            )
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
    }

    // MARK: - Truncation guard (chunk + stitch)

    /// Cohere's decoder KV cache is baked at `maxSeqLen` (108) positions, so a
    /// single pass can only emit ~98 output tokens — a dense utterance is
    /// silently cut mid-sentence, and the encoder itself can't see past 35 s.
    /// Fast path: one pass; if it neither overran the 35 s window nor hit the
    /// token cap (the overwhelmingly common case) it is returned untouched, with
    /// no added latency. Only when the audio is long OR the pass actually
    /// truncated do we fall back to safe-window chunk-and-stitch (Spokenly takes
    /// the same chunking approach for long input).
    private func transcribeGuardingTruncation(
        samples: [Float],
        models: CoherePipeline.LoadedModels,
        language: CohereAsrConfig.Language
    ) async throws -> String {
        // ~98: the decode-loop ceiling minus the fixed language prompt prefix.
        let outputCap = CohereAsrConfig.maxSeqLen - language.promptSequence.count

        if samples.count <= CohereAsrConfig.maxSamples {
            let result = try await pipeline.transcribe(
                audio: samples, models: models, language: language)
            // Stopped on EOS before the ceiling → complete; return as-is.
            if result.tokenIds.count < outputCap - 1 {
                return result.text
            }
            logger.notice(
                "cohere_truncation_guard tokens=\(result.tokenIds.count, privacy: .public) cap=\(outputCap, privacy: .public) action=chunk"
            )
        }

        return try await chunkAndStitch(samples: samples, models: models, language: language)
    }

    /// Splits audio into overlapping windows short enough to stay under the
    /// ~98-token decode cap, transcribes each, and stitches on the duplicated
    /// overlap. Windows are ≤20 s (well under the cap for normal/fast speech);
    /// for a dense utterance that fit inside 35 s we shrink the window so it
    /// still splits into ≥2 chunks.
    private func chunkAndStitch(
        samples: [Float],
        models: CoherePipeline.LoadedModels,
        language: CohereAsrConfig.Language
    ) async throws -> String {
        let outputCap = CohereAsrConfig.maxSeqLen - language.promptSequence.count
        let sr = CohereAsrConfig.sampleRate
        let overlap = 4 * sr
        let maxWindow = 20 * sr
        let minWindow = 4 * sr
        // Audio that fit the encoder window but truncated is dense — shrink the
        // window so it still produces at least two chunks.
        let window =
            samples.count <= CohereAsrConfig.maxSamples
            ? min(maxWindow, max(8 * sr, samples.count * 3 / 5))
            : maxWindow
        return try await chunkAndStitch(
            samples: samples,
            models: models,
            language: language,
            outputCap: outputCap,
            window: window,
            overlap: overlap,
            minWindow: minWindow
        )
    }

    private func chunkAndStitch(
        samples: [Float],
        models: CoherePipeline.LoadedModels,
        language: CohereAsrConfig.Language,
        outputCap: Int,
        window: Int,
        overlap: Int,
        minWindow: Int
    ) async throws -> String {
        let sr = CohereAsrConfig.sampleRate
        let hop = max(sr, window - overlap)

        var merged = ""
        var start = 0
        // `hop` is at least `sr` (>= 1 s) and `samples` is a finite in-memory
        // buffer, so this loop always terminates — no chunk cap is needed. A
        // hard 64-chunk bound here previously truncated audio past ~17 min
        // (64 * 16 s hop), silently dropping the tail of long file transcripts.
        while start < samples.count {
            try Task.checkCancellation()
            let end = min(start + window, samples.count)
            let chunk = Array(samples[start..<end])
            let result = try await pipeline.transcribe(
                audio: chunk, models: models, language: language)
            let text: String
            if result.tokenIds.count < outputCap - 1 {
                text = result.text
            } else if window > minWindow {
                let nextWindow = max(minWindow, window * 3 / 5)
                let nextOverlap = min(overlap, max(sr, nextWindow / 5))
                logger.notice(
                    "cohere_chunk_truncation_guard tokens=\(result.tokenIds.count, privacy: .public) cap=\(outputCap, privacy: .public) window=\(window, privacy: .public) action=rechunk next_window=\(nextWindow, privacy: .public)"
                )
                text = try await chunkAndStitch(
                    samples: chunk,
                    models: models,
                    language: language,
                    outputCap: outputCap,
                    window: nextWindow,
                    overlap: nextOverlap,
                    minWindow: minWindow
                )
            } else {
                logger.warning(
                    "cohere_chunk_truncation_guard tokens=\(result.tokenIds.count, privacy: .public) cap=\(outputCap, privacy: .public) window=\(window, privacy: .public) action=return_capped"
                )
                text = result.text
            }
            merged = merged.isEmpty ? text : Self.mergeOnOverlap(merged, text)
            if end >= samples.count { break }
            start += hop
        }
        return merged
    }

    /// Joins two transcript fragments produced from overlapping audio windows by
    /// dropping duplicated text at the seam. Space-delimited languages use the
    /// word path; CJK fragments use a character path even when mixed with spaces
    /// so Japanese/Chinese chunks do not duplicate the seam with an inserted
    /// ASCII space. Whitespace-free Hangul uses the character path too; Korean
    /// with spaces stays on the word path.
    static func mergeOnOverlap(_ a: String, _ b: String, maxOverlap: Int = 30) -> String {
        // Only the tail of the accumulated transcript can overlap the next
        // chunk. Keep long-file stitching bounded instead of re-tokenizing the
        // whole transcript on every merge.
        let safeSuffixLength = max(maxOverlap * 40, 1000)
        if let splitIndex = a.index(a.endIndex, offsetBy: -safeSuffixLength, limitedBy: a.startIndex),
            splitIndex > a.startIndex
        {
            return String(a[..<splitIndex])
                + mergeOnOverlap(
                    String(a[splitIndex...]),
                    b,
                    maxOverlap: maxOverlap
                )
        }

        if shouldUseCharacterOverlap(a, b) {
            return mergeUnits(
                a: a.map(String.init),
                b: b.map(String.init),
                maxOverlap: maxOverlap * 3,
                separator: ""
            )
        }

        return mergeUnits(
            a: a.split(whereSeparator: { $0.isWhitespace }).map(String.init),
            b: b.split(whereSeparator: { $0.isWhitespace }).map(String.init),
            maxOverlap: maxOverlap,
            separator: " "
        )
    }

    private static func mergeUnits(
        a: [String],
        b: [String],
        maxOverlap: Int,
        separator: String
    ) -> String {
        guard !a.isEmpty else { return b.joined(separator: separator) }
        guard !b.isEmpty else { return a.joined(separator: separator) }

        let limit = min(maxOverlap, a.count, b.count)
        var bestK = 0
        var k = limit
        while k >= 1 {
            if overlapMatches(a: Array(a.suffix(k)), b: Array(b.prefix(k))) {
                bestK = k
                break
            }
            k -= 1
        }

        var mergedA = a
        if bestK > 0,
            let lastA = mergedA.last,
            isTrailingPartial(unit: lastA, completedBy: b[bestK - 1])
        {
            mergedA[mergedA.count - 1] = b[bestK - 1]
        }
        return (mergedA + b.dropFirst(bestK)).joined(separator: separator)
    }

    private static func overlapMatches(a: [String], b: [String]) -> Bool {
        guard a.count == b.count else { return false }
        let strongOverlap = a.count >= 2
        var matchedLexicalUnit = false

        for index in a.indices {
            let aUnit = normalizedOverlapUnit(a[index])
            let bUnit = normalizedOverlapUnit(b[index])
            if aUnit == nil && bUnit == nil {
                continue
            }
            guard let aUnit, let bUnit else { return false }
            matchedLexicalUnit = true
            if aUnit == bUnit { continue }

            if strongOverlap, index == a.startIndex, isLeadingPartial(unit: bUnit, completedBy: aUnit) {
                continue
            }
            if strongOverlap, index == a.index(before: a.endIndex), isTrailingPartial(unit: aUnit, completedBy: bUnit) {
                continue
            }
            return false
        }
        return matchedLexicalUnit
    }

    private static func isLeadingPartial(unit: String, completedBy fullUnit: String) -> Bool {
        let minimumPartialLength = 2
        guard let unit = normalizedOverlapUnit(unit),
            let fullUnit = normalizedOverlapUnit(fullUnit)
        else { return false }
        return unit.count >= minimumPartialLength
            && fullUnit.count > unit.count
            && fullUnit.hasSuffix(unit)
    }

    private static func isTrailingPartial(unit: String, completedBy fullUnit: String) -> Bool {
        let minimumPartialLength = 2
        guard let unit = normalizedOverlapUnit(unit),
            let fullUnit = normalizedOverlapUnit(fullUnit)
        else { return false }
        return unit.count >= minimumPartialLength
            && fullUnit.count > unit.count
            && fullUnit.hasPrefix(unit)
    }

    private static let nonAlphanumerics = CharacterSet.alphanumerics.inverted

    private static func normalizedOverlapUnit(_ unit: String) -> String? {
        let normalized = unit.lowercased().trimmingCharacters(in: Self.nonAlphanumerics)
        return normalized.isEmpty ? nil : normalized
    }

    private static func shouldUseCharacterOverlap(_ a: String, _ b: String) -> Bool {
        if containsCJK(a) || containsCJK(b) {
            return true
        }
        return !containsWhitespace(a) && !containsWhitespace(b) && (containsHangul(a) || containsHangul(b))
    }

    private static func containsWhitespace(_ string: String) -> Bool {
        string.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func containsCJK(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x309F,  // Hiragana
                0x30A0...0x30FF,  // Katakana
                0x3400...0x4DBF,  // CJK Unified Ideographs Extension A
                0x4E00...0x9FFF,  // CJK Unified Ideographs
                0xF900...0xFAFF,  // CJK Compatibility Ideographs
                0x20000...0x323AF:  // CJK Unified Ideographs Extensions B-H and supplement
                return true
            default:
                return false
            }
        }
    }

    private static func containsHangul(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0xAC00...0xD7AF:  // Hangul syllables
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Lifecycle

    public func prepare(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        if models != nil { return }

        if let initializationTask {
            do {
                try await Self.awaitSharedInitializationTask(initializationTask)
            } catch {
                throw try Self.mapWarmUpError(error)
            }
            return
        }

        // `loadModels` clears `initializationTask` itself (via defer) when it
        // finishes. This task is shared by concurrent prepare() callers, so an
        // individual awaiter cancellation must not cancel shared work for other
        // waiters. Explicit lifecycle paths such as unload() still cancel it.
        let loadID = UUID()
        activeLoadID = loadID
        let task = Task { [loadID] in try await loadModels(loadID: loadID, onProgress: onProgress) }
        initializationTask = task

        do {
            try await Self.awaitSharedInitializationTask(task)
        } catch {
            throw try Self.mapWarmUpError(error)
        }
    }

    nonisolated static func awaitSharedInitializationTask(_ task: Task<Void, Error>) async throws {
        let awaiter = CancellationResponsiveTaskAwaiter()
        let waiter = Task {
            do {
                try await task.value
                awaiter.resume(with: .success(()))
            } catch {
                awaiter.resume(with: .failure(error))
            }
        }
        defer { waiter.cancel() }
        try await awaiter.wait()
    }

    public func unload() async {
        let task = initializationTask
        initializationTask = nil
        activeLoadID = nil
        // Dropping `LoadedModels` releases the encoder/decoder `MLModel`s.
        models = nil
        task?.cancel()
        _ = try? await task?.value
    }

    public func isReady() -> Bool {
        models != nil
    }

    private func loadModels(loadID: UUID, onProgress: (@Sendable (String) -> Void)?) async throws {
        // Clear the shared handle when this work finishes (success or failure),
        // from inside the task — not from a possibly-cancelled awaiting caller —
        // so concurrent prepare() calls coalesce onto this one task.
        defer {
            if activeLoadID == loadID {
                initializationTask = nil
                activeLoadID = nil
            }
        }
        try Task.checkCancellation()
        let dir = Self.defaultCacheRoot()
        try Self.requireModelCached(cacheRoot: dir)
        try Task.checkCancellation()
        onProgress?("Loading Cohere model with Core ML...")
        try Task.checkCancellation()
        let loaded = try await CoherePipeline.loadModels(
            encoderDir: dir,
            decoderDir: dir,
            vocabDir: dir,
            decoderVariant: .v2,
            computeUnits: computePolicy.computeUnits
        )
        try Task.checkCancellation()
        // Warm-up inference: pay CoreML's one-time graph/weight specialization
        // now (at load / launch warm-up) instead of on the user's first
        // dictation. On the GPU path this is the heavy ~115s specialization; on
        // ANE it's ~2s. Runs on 1s of silence; the transcript is discarded.
        // After this returns successfully, every real utterance is warm (~0.4s
        // short / ~1.3s long on GPU). Non-cancellation warm-up failures are
        // logged and treated as non-fatal because the loaded models can still run
        // the first real transcription; cancellation still prevents readiness
        // from being published.
        onProgress?("Optimizing Cohere for this Mac...")
        try Task.checkCancellation()
        let warmUpSamples = [Float](repeating: 0, count: CohereAsrConfig.sampleRate)
        do {
            _ = try await pipeline.transcribe(
                audio: warmUpSamples, models: loaded, language: defaultLanguage)
        } catch {
            if error is CancellationError { throw error }
            logger.error("cohere_warmup_failed error=\(error.localizedDescription, privacy: .public)")
        }
        try Task.checkCancellation()
        guard activeLoadID == loadID else { throw CancellationError() }
        self.models = loaded
        logger.notice("cohere_model_prepare_complete compute=\(self.computePolicy.rawValue, privacy: .public)")
        AudioCaptureDiagnostics.append("cohere_model_prepare_complete compute=\(self.computePolicy.rawValue)")
        onProgress?("Ready")
    }

    // MARK: - Model files

    /// `<Application Support>/FluidAudio/Models` — the base FluidAudio's
    /// download/load resolves against, shared with the Parakeet/Nemotron engines.
    nonisolated static func modelsBaseDirectory() -> URL {
        let appSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return
            appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// `…/Models/cohere-transcribe/q8` — `DownloadUtils.downloadRepo` strips the
    /// repo's `q8` subPath prefix but `Repo.cohereTranscribeCoreml.folderName`
    /// re-adds it, so the encoder, v2 decoder and `vocab.json` all land in this
    /// single directory (which is what `CoherePipeline.loadModels` expects).
    public nonisolated static func defaultCacheRoot() -> URL {
        modelsBaseDirectory()
            .appendingPathComponent(Repo.cohereTranscribeCoreml.folderName, isDirectory: true)
    }

    public nonisolated static func isModelCached() -> Bool {
        isModelCached(cacheRoot: defaultCacheRoot())
    }

    public nonisolated static func hasModelCacheDirectory() -> Bool {
        hasModelCacheDirectory(cacheRoot: defaultCacheRoot())
    }

    /// Cached only when the encoder bundle, the v2 decoder bundle, and the vocab
    /// are all present — the exact inputs `CoherePipeline.loadModels` reads.
    nonisolated static func isModelCached(cacheRoot: URL) -> Bool {
        let fileManager = FileManager.default
        let encoder = cacheRoot.appendingPathComponent(ModelNames.CohereTranscribe.encoderCompiledFile)
        let decoder = cacheRoot.appendingPathComponent(ModelNames.CohereTranscribe.decoderCacheExternalV2CompiledFile)
        let vocab = cacheRoot.appendingPathComponent(ModelNames.CohereTranscribe.vocab)
        return fileManager.fileExists(atPath: encoder.path)
            && fileManager.fileExists(atPath: decoder.path)
            && fileManager.fileExists(atPath: vocab.path)
    }

    nonisolated static func hasModelCacheDirectory(cacheRoot: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: cacheRoot.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    nonisolated static func requireModelCached(cacheRoot: URL = defaultCacheRoot()) throws {
        guard isModelCached(cacheRoot: cacheRoot) else {
            throw missingModelError()
        }
    }

    private nonisolated static func missingModelError() -> STTError {
        .engineStartFailed(
            "Cohere Transcribe is not downloaded. Run `macparakeet-cli models download cohere-transcribe` first."
        )
    }

    /// Pre-fetches the model to its cache without loading it. A cached model is
    /// a cheap no-op, mirroring `NemotronEnglishEngine.downloadModel`.
    @discardableResult
    public nonisolated static func downloadModel(
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let cacheRoot = defaultCacheRoot()
        guard !isModelCached(cacheRoot: cacheRoot) else { return cacheRoot }
        onProgress?("Preparing Cohere model download...")
        let progressHandler = makeDownloadProgressHandler(onProgress)
        try await DownloadUtils.downloadRepo(
            .cohereTranscribeCoreml,
            to: modelsBaseDirectory(),
            progressHandler: progressHandler
        )
        return cacheRoot
    }

    @discardableResult
    public nonisolated static func deleteModel() -> Bool {
        deleteModel(cacheRoot: defaultCacheRoot())
    }

    @discardableResult
    nonisolated static func deleteModel(cacheRoot: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheRoot.path) else { return false }
        do {
            try fileManager.removeItem(at: cacheRoot)
        } catch {
            return false
        }
        // Prune the now-empty `cohere-transcribe` parent if nothing else uses it.
        removeIfEmpty(cacheRoot.deletingLastPathComponent(), fileManager: fileManager)
        return !fileManager.fileExists(atPath: cacheRoot.path)
    }

    private nonisolated static func removeIfEmpty(_ directory: URL, fileManager: FileManager) {
        guard let children = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        guard children.allSatisfy(isFinderMetadataFile) else { return }
        try? fileManager.removeItem(at: directory)
    }

    private nonisolated static func isFinderMetadataFile(_ name: String) -> Bool {
        name == ".DS_Store" || name == ".localized" || name == "Icon\r"
    }

    // MARK: - Helpers

    /// Maps a BCP-47-ish language hint to a Cohere-supported language, falling
    /// back to `nil` (caller substitutes its default) for unknown/empty input.
    static func cohereLanguage(_ code: String?) -> CohereAsrConfig.Language? {
        // Reuse the canonical normalizer (folds to a lowercased primary subtag,
        // rejects "auto"/empty/non-letter) so language handling stays consistent.
        guard let normalized = SpeechEnginePreference.normalizeCohereLanguage(code) else { return nil }
        return CohereAsrConfig.Language(rawValue: normalized)
    }

    private nonisolated static func makeDownloadProgressHandler(
        _ onProgress: (@Sendable (String) -> Void)?
    ) -> DownloadUtils.ProgressHandler? {
        guard let onProgress else { return nil }
        let clock = ContinuousClock()
        let lastProgressUpdate = OSAllocatedUnfairLock(initialState: clock.now - .seconds(1))
        let lastProgressMessage = OSAllocatedUnfairLock(initialState: "")
        return { progress in
            guard let message = Self.progressMessage(from: progress) else { return }
            let now = clock.now
            let shouldEmit = lastProgressUpdate.withLock { lastUpdate in
                guard lastUpdate.duration(to: now) >= .milliseconds(250) else { return false }
                lastUpdate = now
                return true
            }
            guard shouldEmit else { return }

            let isNewMessage = lastProgressMessage.withLock { lastMessage in
                guard lastMessage != message else { return false }
                lastMessage = message
                return true
            }
            guard isNewMessage else { return }

            onProgress(message)
        }
    }

    private nonisolated static func progressMessage(from progress: DownloadUtils.DownloadProgress) -> String? {
        switch progress.phase {
        case .listing:
            return "Preparing Cohere model download..."
        case .downloading(let completedFiles, let totalFiles):
            guard totalFiles > 0 else { return nil }
            let percent = max(0, min(100, Int(progress.fractionCompleted * 100.0)))
            return "Downloading Cohere model... \(percent)% (\(completedFiles)/\(totalFiles))"
        case .compiling:
            return "Compiling Cohere model..."
        }
    }

    private nonisolated static func mapWarmUpError(_ error: Error) throws -> STTError {
        if error is CancellationError { throw error }
        if let mapped = mapCommonError(error) { return mapped }
        return .engineStartFailed(error.localizedDescription)
    }

    private nonisolated static func mapTranscriptionError(_ error: Error) throws -> STTError {
        if error is CancellationError { throw error }
        if let mapped = mapCommonError(error) { return mapped }
        return .transcriptionFailed(error.localizedDescription)
    }

    private nonisolated static func mapCommonError(_ error: Error) -> STTError? {
        if let sttError = error as? STTError {
            return sttError
        }
        if let cohereError = error as? CohereAsrError {
            switch cohereError {
            case .modelNotFound:
                return .modelNotLoaded
            case .invalidInput(let message):
                return .transcriptionFailed(message)
            case .encodingFailed(let message), .decodingFailed(let message), .generationFailed(let message):
                return .transcriptionFailed(message)
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .modelDownloadFailed
            default:
                return .engineStartFailed(urlError.localizedDescription)
            }
        }
        return nil
    }
}
