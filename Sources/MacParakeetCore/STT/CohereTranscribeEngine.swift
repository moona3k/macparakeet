import AVFoundation
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

/// Cohere Transcribe remains a batch, record-then-transcribe engine. The model
/// executes through the pinned transcribe.cpp Swift wrapper and a GGUF model.
/// It has no live preview or reliable word timestamps, so `STTResult.words`
/// remains empty and the engine does not conform to `NativeLiveDictating`.
public actor CohereTranscribeEngine: STTTranscribing {

    /// transcribe.cpp compute selection. Legacy Core ML values remain readable
    /// so an existing preference migrates without losing the user's intent.
    public enum ComputePolicy: String, CaseIterable, Sendable {
        case metal
        case cpu

        public static let defaultsKey = "cohereComputePolicy"

        public static func current(defaults: UserDefaults = .standard) -> ComputePolicy {
            switch defaults.string(forKey: defaultsKey) {
            case ComputePolicy.metal.rawValue, "gpu":
                return .metal
            case ComputePolicy.cpu.rawValue, "ane":
                return .cpu
            default:
                return .metal
            }
        }

        public func save(to defaults: UserDefaults = .standard) {
            defaults.set(rawValue, forKey: Self.defaultsKey)
        }
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "CohereTranscribeEngine")
    private let computePolicy: ComputePolicy
    private let backend: any CohereTranscribeBackend
    private let modelURLProvider: @Sendable () throws -> URL
    private let transcriptionPermit = AsyncPermit()
    private var nativeCapabilities: CohereNativeCapabilities?
    private var initializationTask: Task<Void, Error>?
    private var activeLoadID: UUID?
    private var loadedGeneration: UUID?
    private var backendNeedsUnload = false

    public init(
        computePolicy: ComputePolicy = .metal
    ) {
        self.computePolicy = computePolicy
        backend = CohereTranscribeBackendFactory.makeDefault()
        modelURLProvider = {
            try CohereTranscribeModelCatalog.requireVerifiedModel()
        }
    }

    /// The CLI keeps accepting its existing language option for compatibility.
    /// The transcribe.cpp backend now detects the language, so the value is not
    /// passed to the model.
    public init(
        computePolicy: ComputePolicy = .metal,
        defaultLanguageCode _: String?
    ) {
        self.computePolicy = computePolicy
        backend = CohereTranscribeBackendFactory.makeDefault()
        modelURLProvider = {
            try CohereTranscribeModelCatalog.requireVerifiedModel()
        }
    }

    init(
        computePolicy: ComputePolicy = .metal,
        backend: any CohereTranscribeBackend,
        modelURLProvider: @escaping @Sendable () throws -> URL
    ) {
        self.computePolicy = computePolicy
        self.backend = backend
        self.modelURLProvider = modelURLProvider
    }

    // MARK: - Languages

    public static let supportedLanguages: [(code: String, name: String)] = [
        ("ar", "Arabic"),
        ("de", "German"),
        ("el", "Greek"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("it", "Italian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("pt", "Portuguese"),
        ("vi", "Vietnamese"),
        ("zh", "Chinese"),
    ]

    /// Language values accepted by the pre-transcribe.cpp CLI/settings
    /// contract. They are ignored by this backend, but existing Hindi and
    /// Russian preferences must continue to parse and round-trip.
    public static let legacyCompatibleLanguageCodes = [
        "ar", "de", "el", "en", "es", "fr", "hi", "it",
        "ja", "ko", "nl", "pl", "pt", "ru", "vi", "zh",
    ]

    public nonisolated static var isNativeFrameworkAvailable: Bool {
        CohereTranscribeBackendFactory.isNativeFrameworkAvailable
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
        job _: STTJobKind,
        language: String?,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        try await transcriptionPermit.wait()
        defer { transcriptionPermit.signal() }

        do {
            try await prepare(onProgress: { [logger] message in
                logger.notice("cohere_prepare \(message, privacy: .public)")
            })
            guard nativeCapabilities != nil, let generation = loadedGeneration else {
                throw STTError.modelNotLoaded
            }

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

            let native = try await transcribeGuardingTruncation(
                samples: samples,
                generation: generation,
                onProgress: onProgress
            )
            onProgress?(100, 100)

            if language != nil {
                logger.debug("cohere_language_hint_ignored mode=automatic")
            }
            return STTResult(
                text: native.text,
                words: [],
                language: native.detectedLanguage,
                engine: .cohere,
                engineVariant: nativeCapabilities?.computeBackend ?? computePolicy.rawValue
            )
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
    }

    func transcribeSamplesForTesting(
        _ samples: [Float],
        language: String? = nil
    ) async throws -> STTResult {
        try await transcriptionPermit.wait()
        defer { transcriptionPermit.signal() }

        do {
            try await prepare()
            guard let generation = loadedGeneration else {
                throw STTError.modelNotLoaded
            }
            let native = try await transcribeGuardingTruncation(
                samples: samples,
                generation: generation,
                onProgress: nil
            )
            if language != nil {
                logger.debug("cohere_language_hint_ignored mode=automatic")
            }
            return STTResult(
                text: native.text,
                words: [],
                language: native.detectedLanguage,
                engine: .cohere,
                engineVariant: nativeCapabilities?.computeBackend ?? computePolicy.rawValue
            )
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
    }

    // MARK: - Truncation guard (chunk + stitch)

    private func transcribeGuardingTruncation(
        samples: [Float],
        generation: UUID,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> CohereNativeTranscript {
        guard let capabilities = nativeCapabilities else {
            throw STTError.modelNotLoaded
        }
        let sampleRate = capabilities.nativeSampleRate
        let reportedMaximum =
            capabilities.maxAudioMilliseconds > 0
            ? Int(capabilities.maxAudioMilliseconds) * sampleRate / 1000
            : 300 * sampleRate
        let safetyMargin = min(5 * sampleRate, max(1, reportedMaximum / 10))
        let window = min(300 * sampleRate, max(1, reportedMaximum - safetyMargin))

        if samples.count <= window {
            let result = try await transcribeOne(samples: samples, generation: generation)
            if !result.wasTruncated {
                return result
            }
            logger.notice("cohere_truncation_guard action=rechunk")
        }

        let overlap = min(5 * sampleRate, max(sampleRate / 4, window / 20))
        let minimumWindow = max(sampleRate / 4, min(10 * sampleRate, window / 4))
        return try await chunkAndStitch(
            samples: samples,
            generation: generation,
            window: window,
            overlap: overlap,
            minimumWindow: minimumWindow,
            onProgress: onProgress
        )
    }

    private func chunkAndStitch(
        samples: [Float],
        generation: UUID,
        window: Int,
        overlap: Int,
        minimumWindow: Int,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> CohereNativeTranscript {
        let hop = max(1, window - overlap)
        let estimatedChunks =
            samples.count <= window
            ? 1
            : 1 + Int(ceil(Double(samples.count - window) / Double(hop)))

        var merged = ""
        var detectedLanguages = Set<String>()
        var start = 0
        var completedChunks = 0
        while start < samples.count {
            try Task.checkCancellation()
            let end = min(start + window, samples.count)
            let chunk = Array(samples[start..<end])
            let result = try await transcribeOne(samples: chunk, generation: generation)
            let resolved: CohereNativeTranscript
            if result.wasTruncated, window > minimumWindow {
                let nextWindow = max(minimumWindow, window * 3 / 5)
                let nextOverlap = min(overlap, max(1, nextWindow / 5))
                logger.notice(
                    "cohere_chunk_truncation_guard window=\(window, privacy: .public) action=rechunk next_window=\(nextWindow, privacy: .public)"
                )
                resolved = try await chunkAndStitch(
                    samples: chunk,
                    generation: generation,
                    window: nextWindow,
                    overlap: nextOverlap,
                    minimumWindow: minimumWindow,
                    onProgress: nil
                )
            } else {
                if result.wasTruncated {
                    throw CohereNativeBackendError.outputTruncatedAtMinimum(
                        chunk.count
                    )
                }
                resolved = result
            }

            merged =
                merged.isEmpty
                ? resolved.text
                : Self.mergeOnOverlap(merged, resolved.text)
            if let language = resolved.detectedLanguage {
                detectedLanguages.insert(language)
            }
            completedChunks += 1
            let progress =
                40
                + Int(
                    (Double(completedChunks) / Double(max(estimatedChunks, 1))) * 55
                )
            onProgress?(min(progress, 95), 100)
            if end >= samples.count { break }
            start += hop
        }

        return CohereNativeTranscript(
            text: merged,
            detectedLanguage: detectedLanguages.count == 1 ? detectedLanguages.first : nil,
            wasTruncated: false
        )
    }

    private func transcribeOne(
        samples: [Float],
        generation: UUID
    ) async throws -> CohereNativeTranscript {
        try Task.checkCancellation()
        guard loadedGeneration == generation else {
            throw CancellationError()
        }
        let result = try await backend.transcribe(samples: samples, language: nil)
        try Task.checkCancellation()
        guard loadedGeneration == generation else {
            throw CancellationError()
        }
        return CohereNativeTranscript(
            text: result.text,
            detectedLanguage: Self.cohereLanguage(result.detectedLanguage),
            wasTruncated: result.wasTruncated
        )
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
                separator: "",
                allowApproximateCharacterOverlap: !containsWhitespace(a) && !containsWhitespace(b)
            )
        }

        return mergeUnits(
            a: a.split(whereSeparator: { $0.isWhitespace }).map(String.init),
            b: b.split(whereSeparator: { $0.isWhitespace }).map(String.init),
            maxOverlap: maxOverlap,
            separator: " ",
            allowApproximateCharacterOverlap: false
        )
    }

    private static func mergeUnits(
        a: [String],
        b: [String],
        maxOverlap: Int,
        separator: String,
        allowApproximateCharacterOverlap: Bool
    ) -> String {
        guard !a.isEmpty else { return b.joined(separator: separator) }
        guard !b.isEmpty else { return a.joined(separator: separator) }

        let limit = min(maxOverlap, a.count, b.count)
        var bestK = 0
        var k = limit
        while k >= 1 {
            let aSuffix = Array(a.suffix(k))
            let bPrefix = Array(b.prefix(k))
            if overlapMatches(a: aSuffix, b: bPrefix)
                || (allowApproximateCharacterOverlap
                    && approximateCharacterOverlapMatches(a: aSuffix, b: bPrefix))
            {
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

    private static func approximateCharacterOverlapMatches(a: [String], b: [String]) -> Bool {
        let rawA = a.joined()
        let rawB = b.joined()
        guard containsCJK(rawA) || containsCJK(rawB) || containsHangul(rawA) || containsHangul(rawB)
        else {
            return false
        }

        let aNormalized = normalizedOverlapSequence(a)
        let bNormalized = normalizedOverlapSequence(b)
        let minimumLength = min(aNormalized.count, bNormalized.count)
        guard minimumLength >= 8 else { return false }
        guard hasStableApproximateOverlapAnchor(aNormalized, bNormalized) else { return false }

        let aTrailingMarker = trailingNumberMarker(aNormalized)
        let bTrailingMarker = trailingNumberMarker(bNormalized)
        if aTrailingMarker != bTrailingMarker {
            return false
        }

        let maximumLength = max(aNormalized.count, bNormalized.count)
        let allowedDistance = max(2, Int((Double(maximumLength) * 0.25).rounded(.down)))
        return boundedEditDistance(aNormalized, bNormalized, maxDistance: allowedDistance) <= allowedDistance
    }

    private static func normalizedOverlapSequence(_ units: [String]) -> String {
        units.compactMap { normalizedOverlapUnit($0) }.joined()
    }

    private static func hasStableApproximateOverlapAnchor(_ a: String, _ b: String) -> Bool {
        if let aMarker = leadingNumberMarker(a), let bMarker = leadingNumberMarker(b) {
            return aMarker == bMarker
        }
        if leadingNumberMarker(a) != nil || leadingNumberMarker(b) != nil {
            return false
        }
        return commonPrefixLength(a, b) >= 3
    }

    private static func leadingNumberMarker(_ string: String) -> String? {
        var marker = ""
        for scalar in string.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                marker.unicodeScalars.append(scalar)
            } else {
                break
            }
        }
        return marker.isEmpty ? nil : marker
    }

    private static func trailingNumberMarker(_ string: String) -> String? {
        var markerScalars: [UnicodeScalar] = []
        for scalar in string.unicodeScalars.reversed() {
            if CharacterSet.decimalDigits.contains(scalar) {
                markerScalars.append(scalar)
            } else {
                break
            }
        }
        guard !markerScalars.isEmpty else { return nil }
        return String(String.UnicodeScalarView(markerScalars.reversed()))
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        var aIndex = a.startIndex
        var bIndex = b.startIndex
        while aIndex < a.endIndex && bIndex < b.endIndex {
            guard a[aIndex] == b[bIndex] else { break }
            count += 1
            aIndex = a.index(after: aIndex)
            bIndex = b.index(after: bIndex)
        }
        return count
    }

    private static func boundedEditDistance(_ a: String, _ b: String, maxDistance: Int) -> Int {
        let aCharacters = Array(a)
        let bCharacters = Array(b)
        guard abs(aCharacters.count - bCharacters.count) <= maxDistance else {
            return maxDistance + 1
        }
        if aCharacters.isEmpty { return bCharacters.count }
        if bCharacters.isEmpty { return aCharacters.count }

        var previous = Array(0...bCharacters.count)
        var current = Array(repeating: 0, count: bCharacters.count + 1)

        for (aOffset, aCharacter) in aCharacters.enumerated() {
            current[0] = aOffset + 1
            var rowMinimum = current[0]

            for (bOffset, bCharacter) in bCharacters.enumerated() {
                let substitutionCost = aCharacter == bCharacter ? 0 : 1
                current[bOffset + 1] = min(
                    previous[bOffset + 1] + 1,
                    current[bOffset] + 1,
                    previous[bOffset] + substitutionCost
                )
                rowMinimum = min(rowMinimum, current[bOffset + 1])
            }

            if rowMinimum > maxDistance {
                return maxDistance + 1
            }
            swap(&previous, &current)
        }

        return previous[bCharacters.count]
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
        if nativeCapabilities != nil, loadedGeneration != nil { return }

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
        loadedGeneration = nil
        nativeCapabilities = nil
        task?.cancel()
        _ = try? await task?.value
        if backendNeedsUnload {
            backendNeedsUnload = false
            await backend.unload()
        }
    }

    public func isReady() -> Bool {
        nativeCapabilities != nil && loadedGeneration != nil
    }

    private func loadModels(loadID: UUID, onProgress: (@Sendable (String) -> Void)?) async throws {
        defer {
            if activeLoadID == loadID {
                initializationTask = nil
                activeLoadID = nil
            }
        }
        try Task.checkCancellation()
        let modelURL = try modelURLProvider()
        try Task.checkCancellation()
        onProgress?("Loading Cohere Transcribe with transcribe.cpp...")

        do {
            let capabilities = try await backend.load(
                modelURL: modelURL,
                computePolicy: computePolicy
            )
            backendNeedsUnload = true
            try Self.validateNativeCapabilities(capabilities)
            try Task.checkCancellation()
            guard activeLoadID == loadID else { throw CancellationError() }

            nativeCapabilities = capabilities
            loadedGeneration = loadID
            logger.notice(
                "cohere_model_prepare_complete runtime=\(capabilities.runtimeVersion, privacy: .public) backend=\(capabilities.computeBackend, privacy: .public)"
            )
            AudioCaptureDiagnostics.append(
                "cohere_model_prepare_complete runtime=\(capabilities.runtimeVersion) backend=\(capabilities.computeBackend)"
            )
            onProgress?("Ready")
        } catch {
            nativeCapabilities = nil
            loadedGeneration = nil
            if backendNeedsUnload {
                backendNeedsUnload = false
                await backend.unload()
            }
            throw error
        }
    }

    // MARK: - Model files

    nonisolated static func modelsBaseDirectory() -> URL {
        CohereTranscribeModelCatalog.cacheBaseDirectory()
    }

    public nonisolated static func defaultCacheRoot() -> URL {
        CohereTranscribeModelCatalog.modelDirectory()
    }

    public nonisolated static func isModelCached() -> Bool {
        isModelCached(cacheRoot: defaultCacheRoot())
    }

    public nonisolated static func hasModelCacheDirectory() -> Bool {
        hasModelCacheDirectory(cacheRoot: defaultCacheRoot())
    }

    nonisolated static func isModelCached(cacheRoot: URL) -> Bool {
        CohereTranscribeModelCatalog.isVerified(directory: cacheRoot)
    }

    nonisolated static func hasModelCacheDirectory(cacheRoot: URL) -> Bool {
        CohereTranscribeModelCatalog.hasArtifacts(directory: cacheRoot)
    }

    nonisolated static func requireModelCached(cacheRoot: URL = defaultCacheRoot()) throws {
        _ = try CohereTranscribeModelCatalog.requireVerifiedModel(directory: cacheRoot)
    }

    @discardableResult
    public nonisolated static func downloadModel(
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let cacheRoot = defaultCacheRoot()
        guard !isModelCached(cacheRoot: cacheRoot) else { return cacheRoot }
        onProgress?("Preparing Cohere model download...")
        let downloader = CohereTranscribeModelCatalog.makeDownloader()
        return try await downloader.downloadDefaultModel { progress in
            guard let onProgress else { return }
            let percent = max(0, min(100, Int(progress.fractionCompleted * 100)))
            onProgress(
                "Downloading Cohere model... \(percent)% (\(progress.completedFiles)/\(progress.totalFiles))"
            )
        }
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

    static func cohereLanguage(_ code: String?) -> String? {
        SpeechEnginePreference.normalizeCohereLanguage(code)
    }

    nonisolated static func validateNativeCapabilities(
        _ capabilities: CohereNativeCapabilities
    ) throws {
        guard capabilities.runtimeVersion == CohereTranscribePins.swiftWrapperVersion else {
            throw CohereNativeBackendError.incompatibleRuntime(
                expectedVersion: CohereTranscribePins.swiftWrapperVersion,
                actualVersion: capabilities.runtimeVersion
            )
        }
        let expectedCommit = CohereTranscribePins.requiredRuntimeCommit.lowercased()
        let actualCommit = capabilities.runtimeCommit.lowercased()
        let minimumRuntimeCommitLength = 7
        guard actualCommit.count >= minimumRuntimeCommitLength,
            expectedCommit.hasPrefix(actualCommit)
        else {
            throw CohereNativeBackendError.incompatibleCommit(
                expectedPrefix: String(expectedCommit.prefix(minimumRuntimeCommitLength)),
                actualCommit: capabilities.runtimeCommit
            )
        }
        guard capabilities.architecture == CohereTranscribePins.modelArchitecture,
            capabilities.variant == CohereTranscribePins.modelVariant
        else {
            throw CohereNativeBackendError.incompatibleModel(
                architecture: capabilities.architecture,
                variant: capabilities.variant
            )
        }
        guard capabilities.supportsLanguageDetection else {
            throw CohereNativeBackendError.languageDetectionUnavailable
        }
        let expectedLanguages = supportedLanguages.map(\.code).sorted()
        let actualLanguages = Set(
            capabilities.supportedLanguages.map {
                $0.lowercased().split(separator: "-").first.map(String.init) ?? ""
            }
        ).filter { !$0.isEmpty }.sorted()
        guard actualLanguages == expectedLanguages else {
            throw CohereNativeBackendError.unsupportedLanguages(
                expected: expectedLanguages,
                actual: actualLanguages
            )
        }
        guard capabilities.nativeSampleRate == 16_000 else {
            throw CohereNativeBackendError.unsupportedSampleRate(
                capabilities.nativeSampleRate
            )
        }
        guard capabilities.maxAudioMilliseconds > 0 else {
            throw CohereNativeBackendError.invalidMaximumAudioMilliseconds(
                capabilities.maxAudioMilliseconds
            )
        }
        guard !capabilities.providesTimestamps else {
            throw CohereNativeBackendError.unexpectedTimestampSupport
        }
    }

    private nonisolated static func mapWarmUpError(_ error: Error) throws -> STTError {
        if error is CancellationError { throw error }
        if let mapped = mapCommonError(error) { return mapped }
        if let backendError = error as? CohereNativeBackendError {
            return .engineStartFailed(backendError.localizedDescription)
        }
        return .engineStartFailed(error.localizedDescription)
    }

    private nonisolated static func mapTranscriptionError(_ error: Error) throws -> STTError {
        if error is CancellationError { throw error }
        if let mapped = mapCommonError(error) { return mapped }
        if let backendError = error as? CohereNativeBackendError {
            return .transcriptionFailed(backendError.localizedDescription)
        }
        return .transcriptionFailed(error.localizedDescription)
    }

    private nonisolated static func mapCommonError(_ error: Error) -> STTError? {
        if let sttError = error as? STTError {
            return sttError
        }
        if error is InProcessModelDownloaderError {
            return .modelDownloadFailed
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
