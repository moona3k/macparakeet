import AVFoundation
import CoreML
import FluidAudio
import Foundation
import os

/// Wraps FluidAudio's `CoherePipeline` (Cohere Transcribe 03-2026, a 2B
/// Conformer encoder + lightweight Transformer decoder converted to Core ML by
/// Fluid Inference). Cohere is a **batch, record-then-transcribe** engine: it
/// has no streaming/partial path and emits no word timestamps, so it does not
/// conform to ``NativeLiveDictating`` and `STTResult.words` is always empty.
///
/// ## Compute policy
/// The big INT8 encoder behaves very differently per Core ML backend. Defaults
/// to **`.gpu`** — the fast path that makes the engine feel instant:
/// - **`.gpu`** (`.all`, default): warm ~0.4–0.6 s. Core ML specializes the
///   graph on the **first transcribe of every launch (~115 s, not cached)**, so
///   we pay it in the background via a launch warm-up; for a resident app that
///   is once per session, then every dictation is fast.
/// - **`.ane`** (`cpuAndNeuralEngine`): warm ~1.3–1.6 s, but its one-time
///   specialization is **cached across launches** (`com.apple.e5rt.e5bundlecache`)
///   so there is no per-launch stall, and it leaves the GPU free for the LLM
///   formatter. The escape hatch for users who relaunch often.
/// NOTE: most apparent slowness in development is the unoptimized **Debug**
/// build — the per-step decoder + mel hot path runs ~9× slower than release.
/// Always judge latency from a release build.
public actor CohereTranscribeEngine: STTTranscribing {

    /// Core ML compute-unit policy for the Cohere models. See the type doc for
    /// the latency/cold-start tradeoff measured in the Phase-0 spike.
    public enum ComputePolicy: String, CaseIterable, Sendable {
        /// `cpuAndNeuralEngine` — warm ~1.3–1.6 s, one-time specialization cached
        /// across launches (e5bundlecache); no per-launch stall. Escape hatch.
        case ane
        /// `.all` — default. Warm ~0.4–0.6 s; ~115 s graph specialization on the
        /// first transcribe of every launch (not cached), hidden by launch warm-up.
        case gpu

        public static let defaultsKey = "cohereComputePolicy"

        public static func current(defaults: UserDefaults = .standard) -> ComputePolicy {
            guard let raw = defaults.string(forKey: defaultsKey),
                let policy = ComputePolicy(rawValue: raw)
            else {
                return .gpu
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
    /// every job kind (dictation, file, meeting) safely. Cohere is batch-only:
    /// a second job that arrives while one is already in flight is rejected with
    /// `STTError.engineBusy` rather than run concurrently or queued.
    private let pipeline = CoherePipeline()
    private var models: CoherePipeline.LoadedModels?
    private var initializationTask: Task<Void, Error>?
    private var isTranscribing = false

    public init(
        computePolicy: ComputePolicy = .gpu,
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
    public init(computePolicy: ComputePolicy = .gpu, defaultLanguageCode: String?) {
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
        guard !isTranscribing else { throw STTError.engineBusy }
        isTranscribing = true
        defer { isTranscribing = false }

        do {
            // Lazy path (CLI, or first dictation before background warm-up
            // finished): a first-time ~2.1 GB model download would otherwise be
            // silent and read as a hang, so log prepare progress to the console.
            try await prepare(onProgress: { [logger] message in
                logger.notice("cohere_prepare \(message, privacy: .public)")
            })
            guard let models else { throw STTError.modelNotLoaded }

            onProgress?(0, 100)
            try Task.checkCancellation()
            let samples = try await Task.detached(priority: .userInitiated) {
                try AudioConverter().resampleAudioFile(audioURL)
            }.value
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
        let sr = CohereAsrConfig.sampleRate
        let overlap = 4 * sr
        let maxWindow = 20 * sr
        // Audio that fit the encoder window but truncated is dense — shrink the
        // window so it still produces at least two chunks.
        let window = samples.count <= CohereAsrConfig.maxSamples
            ? min(maxWindow, max(8 * sr, samples.count * 3 / 5))
            : maxWindow
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
            merged = merged.isEmpty ? result.text : Self.mergeOnOverlap(merged, result.text)
            if end >= samples.count { break }
            start += hop
        }
        return merged
    }

    /// Joins two transcript fragments produced from overlapping audio windows by
    /// dropping the duplicated words at the seam: compares up to `maxOverlap`
    /// trailing words of `a` against the leading words of `b`
    /// (case/punctuation-insensitive) and removes the longest match from `b`.
    static func mergeOnOverlap(_ a: String, _ b: String, maxOverlap: Int = 30) -> String {
        let aWords = a.split(separator: " ").map(String.init)
        let bWords = b.split(separator: " ").map(String.init)
        guard !aWords.isEmpty else { return b }
        guard !bWords.isEmpty else { return a }

        func norm(_ word: String) -> String {
            word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        }
        let limit = min(maxOverlap, aWords.count, bWords.count)
        var bestK = 0
        var k = limit
        while k >= 1 {
            if zip(aWords.suffix(k), bWords.prefix(k)).allSatisfy({ norm($0) == norm($1) }) {
                bestK = k
                break
            }
            k -= 1
        }
        return (aWords + bWords.dropFirst(bestK)).joined(separator: " ")
    }

    // MARK: - Lifecycle

    public func prepare(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        if models != nil { return }

        if let initializationTask {
            try await initializationTask.value
            return
        }

        let task = Task { try await loadModels(onProgress: onProgress) }
        initializationTask = task

        do {
            try await task.value
            initializationTask = nil
        } catch {
            initializationTask = nil
            throw try Self.mapWarmUpError(error)
        }
    }

    public func unload() async {
        initializationTask?.cancel()
        _ = try? await initializationTask?.value
        initializationTask = nil
        // Dropping `LoadedModels` releases the encoder/decoder `MLModel`s.
        models = nil
    }

    public func isReady() -> Bool {
        models != nil
    }

    private func loadModels(onProgress: (@Sendable (String) -> Void)?) async throws {
        try await Self.downloadModel(onProgress: onProgress)
        onProgress?("Loading Cohere model with Core ML...")
        let dir = Self.defaultCacheRoot()
        let loaded = try await CoherePipeline.loadModels(
            encoderDir: dir,
            decoderDir: dir,
            vocabDir: dir,
            decoderVariant: .v2,
            computeUnits: computePolicy.computeUnits
        )
        // Warm-up inference: pay CoreML's one-time graph/weight specialization
        // now (at load / launch warm-up) instead of on the user's first
        // dictation. On the GPU path this is the heavy ~115s specialization; on
        // ANE it's ~2s. Runs on 1s of silence; the transcript is discarded.
        // After this returns, every real utterance is warm (~0.4s short / ~1.3s
        // long on GPU). `models` is published only once fully warm, so
        // `isReady()` reflecting true readiness gates the live engine swap UI.
        onProgress?("Optimizing Cohere for this Mac...")
        let warmUpSamples = [Float](repeating: 0, count: CohereAsrConfig.sampleRate)
        _ = try? await pipeline.transcribe(
            audio: warmUpSamples, models: loaded, language: defaultLanguage)
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
        guard let children = try? fileManager.contentsOfDirectory(atPath: directory.path),
            children.isEmpty
        else {
            return
        }
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - Helpers

    /// Maps a BCP-47-ish language hint to a Cohere-supported language, falling
    /// back to `nil` (caller substitutes its default) for unknown/empty input.
    static func cohereLanguage(_ code: String?) -> CohereAsrConfig.Language? {
        guard let code else { return nil }
        let primary =
            code.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? code.lowercased()
        return CohereAsrConfig.Language(rawValue: primary)
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
