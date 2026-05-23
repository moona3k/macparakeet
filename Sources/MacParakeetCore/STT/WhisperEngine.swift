import Foundation
import OSLog

#if canImport(WhisperKit)
import WhisperKit
#endif

final class AsyncPermit: @unchecked Sendable {
    private final class WaitState: @unchecked Sendable {
        var cancelled = false
        var completed = false
    }

    private struct Waiter {
        let state: WaitState
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var permits: Int
    private var waiterOrder: [UUID] = []
    private var waiterHeadIndex = 0
    private var waiters: [UUID: Waiter] = [:]

    init(value: Int = 1) {
        permits = max(0, value)
    }

    func wait() async throws {
        let id = UUID()
        let state = WaitState()
        try await withTaskCancellationHandler {
            let _: Void = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if state.cancelled {
                    state.completed = true
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if permits > 0 {
                    permits -= 1
                    state.completed = true
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiterOrder.append(id)
                    waiters[id] = Waiter(state: state, continuation: continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            cancelWaiter(id: id, state: state)
        }
    }

    private func cancelWaiter(id: UUID, state: WaitState) {
        lock.lock()
        if state.completed {
            lock.unlock()
            return
        }
        guard let waiter = waiters.removeValue(forKey: id) else {
            state.cancelled = true
            lock.unlock()
            return
        }
        state.completed = true
        lock.unlock()
        waiter.continuation.resume(throwing: CancellationError())
    }

    func signal() {
        lock.lock()
        while waiterHeadIndex < waiterOrder.count {
            let id = waiterOrder[waiterHeadIndex]
            waiterHeadIndex += 1
            guard let waiter = waiters.removeValue(forKey: id) else {
                continue
            }
            waiter.state.completed = true
            compactWaiterOrderIfNeeded()
            lock.unlock()
            waiter.continuation.resume()
            return
        }
        permits += 1
        compactWaiterOrderIfNeeded()
        lock.unlock()
    }

    func pendingWaiterCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    private func compactWaiterOrderIfNeeded() {
        guard waiterHeadIndex > 64, waiterHeadIndex * 2 > waiterOrder.count else {
            return
        }
        waiterOrder = Array(waiterOrder.dropFirst(waiterHeadIndex))
        waiterHeadIndex = 0
    }
}

public actor WhisperEngine: STTTranscribing {
    public static let defaultModelVariant = SpeechEnginePreference.defaultWhisperModelVariant

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "WhisperEngine")

    private let modelVariant: String
    private let defaultLanguage: String?
    private let downloadBase: URL
    /// Store the optimized-flag write lands in; defaults to `.standard` to match
    /// every production caller (runtime + CLI). Injected so the write-path and
    /// the VM's read-path are coupled by construction, not by convention.
    private let defaults: UserDefaults
    private let transcriptionPermit = AsyncPermit()

    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    private var isLoaded = false
    #endif

    public init(
        model: String = WhisperEngine.defaultModelVariant,
        language: String? = nil,
        downloadBase: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.modelVariant = Self.normalizeModelVariant(model)
        self.defaultLanguage = SpeechEnginePreference.normalizeLanguage(language)
        self.downloadBase = downloadBase ?? Self.defaultDownloadBase
        self.defaults = defaults
    }

    public static func make(
        model: String = WhisperEngine.defaultModelVariant,
        language: String? = nil
    ) -> WhisperEngine {
        WhisperEngine(model: model, language: language)
    }

    public static var defaultDownloadBase: URL {
        URL(fileURLWithPath: AppPaths.whisperModelsDir, isDirectory: true)
    }

    public static func normalizeModelVariant(_ model: String) -> String {
        // Turbo hyphen/underscore folding now lives in the shared
        // `SpeechEnginePreference.normalizeModelVariant` so the engine, the
        // stored preference, and the optimized-flag key all agree on one id.
        SpeechEnginePreference.normalizeModelVariant(model) ?? defaultModelVariant
    }

    public static func isModelDownloaded(
        model: String = WhisperEngine.defaultModelVariant,
        downloadBase: URL = WhisperEngine.defaultDownloadBase
    ) -> Bool {
        localModelFolder(model: model, downloadBase: downloadBase) != nil
    }

    public static func localModelFolder(
        model: String = WhisperEngine.defaultModelVariant,
        downloadBase: URL = WhisperEngine.defaultDownloadBase
    ) -> URL? {
        let normalized = normalizeModelVariant(model)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: downloadBase.path),
              let enumerator = fileManager.enumerator(
                at: downloadBase,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else {
                continue
            }
            let folderName = url.lastPathComponent
            if folderName.caseInsensitiveCompare(normalized) == .orderedSame {
                return url
            }
            if isTokenBoundaryModelFolder(folderName: folderName, normalizedModel: normalized) {
                candidates.append(url)
            }
        }

        return candidates.max { lhs, rhs in
            lhs.lastPathComponent.count < rhs.lastPathComponent.count
        }
    }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        try await transcribe(
            audioURL: URL(fileURLWithPath: audioPath),
            language: defaultLanguage,
            onProgress: onProgress
        )
    }

    public func transcribe(
        audioURL: URL,
        language: String?,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        try await transcriptionPermit.wait()
        defer { transcriptionPermit.signal() }
        try Task.checkCancellation()
        return try await transcribeLocked(
            audioURL: audioURL,
            language: language,
            onProgress: onProgress
        )
    }

    private func transcribeLocked(
        audioURL: URL,
        language: String?,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        #if canImport(WhisperKit)
        do {
            try await prepareLocked(onProgress: nil)
            guard let whisperKit else {
                throw STTError.modelNotLoaded
            }

            let requestedLanguage = SpeechEnginePreference.normalizeLanguage(language)

            onProgress?(0, 100)
            let callback: TranscriptionCallback = { _ in
                onProgress?(50, 100)
                return true
            }
            let result = try await Self.transcribeWithLanguageFallback(
                whisperKit,
                audioPath: audioURL.path,
                requestedLanguage: requestedLanguage,
                callback: callback
            )

            onProgress?(100, 100)
            return Self.makeResult(from: result, modelVariant: modelVariant)
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
        #else
        throw STTError.engineStartFailed("WhisperKit is not available in this build.")
        #endif
    }

    public func prepare(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await transcriptionPermit.wait()
        defer { transcriptionPermit.signal() }
        try Task.checkCancellation()
        try await prepareLocked(onProgress: onProgress)
    }

    private func prepareLocked(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        #if canImport(WhisperKit)
        if isLoaded, whisperKit != nil { return }
        guard let modelFolder = Self.localModelFolder(model: modelVariant, downloadBase: downloadBase) else {
            throw STTError.engineStartFailed(
                "Whisper model is not downloaded. Run `macparakeet-cli models download whisper-\(modelVariant)` first."
            )
        }

        do {
            try AppPaths.ensureDirectories()
            let startedAt = Date()
            let variant = modelVariant
            let folderName = modelFolder.lastPathComponent
            let watchdog = Self.makePrepareWatchdog(
                modelVariant: variant,
                folderName: folderName,
                onProgress: onProgress
            )
            defer { watchdog.cancel() }

            logger.notice("whisper_model_prepare_start model=\(variant, privacy: .public) folder=\(folderName, privacy: .public)")
            AudioCaptureDiagnostics.append(
                "whisper_model_prepare_start model=\(variant) folder=\(folderName)"
            )
            onProgress?("Optimizing Whisper for this Mac...")
            whisperKit = try await WhisperKit(WhisperKitConfig(
                model: modelVariant,
                downloadBase: downloadBase,
                modelFolder: modelFolder.path,
                verbose: false,
                load: true,
                download: false
            ))
            isLoaded = true
            // Single chokepoint for "this variant compiled successfully on this
            // Mac" — fires for every caller (Settings switch, onboarding,
            // first meeting use, CLI). The UI reads this to show cold vs warm
            // status. Only reached on a real compile, so it never fires in
            // unit tests (which lack a downloaded model + WhisperKit).
            SpeechEnginePreference.markWhisperOptimized(variant: variant, defaults: defaults)
            let duration = Observability.durationSeconds(since: startedAt)
            logger.notice("whisper_model_prepare_complete model=\(variant, privacy: .public) duration_s=\(duration, privacy: .public)")
            AudioCaptureDiagnostics.append(
                "whisper_model_prepare_complete model=\(variant) duration_s=\(Self.formatSeconds(duration))"
            )
            onProgress?("Ready")
        } catch {
            isLoaded = false
            whisperKit = nil
            let variant = modelVariant
            logger.error("whisper_model_prepare_failed model=\(variant, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
            AudioCaptureDiagnostics.append(
                "whisper_model_prepare_failed model=\(variant) \(AudioCaptureDiagnostics.errorFields(error))"
            )
            throw try Self.mapWarmUpError(error)
        }
        #else
        throw STTError.engineStartFailed("WhisperKit is not available in this build.")
        #endif
    }

    public func unload() async {
        do {
            try await transcriptionPermit.wait()
        } catch {
            return
        }
        defer { transcriptionPermit.signal() }
        guard !Task.isCancelled else { return }

        #if canImport(WhisperKit)
        await whisperKit?.unloadModels()
        whisperKit = nil
        isLoaded = false
        #endif
    }

    public func isReady() -> Bool {
        #if canImport(WhisperKit)
        isLoaded && whisperKit != nil
        #else
        false
        #endif
    }

    public static func downloadModel(
        model: String = WhisperEngine.defaultModelVariant,
        downloadBase: URL = WhisperEngine.defaultDownloadBase,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> URL {
        #if canImport(WhisperKit)
        try AppPaths.ensureDirectories()
        return try await WhisperKit.download(
            variant: normalizeModelVariant(model),
            downloadBase: downloadBase,
            progressCallback: { progress in
                let total = max(Int(progress.totalUnitCount), 1)
                let completed = max(0, Int(progress.completedUnitCount))
                onProgress?(completed, total)
            }
        )
        #else
        throw STTError.engineStartFailed("WhisperKit is not available in this build.")
        #endif
    }

    public static func makeTimestampedWord(
        word: String,
        startSeconds: Float,
        endSeconds: Float,
        probability: Float
    ) -> TimestampedWord {
        let startMs = Int((max(0, startSeconds) * 1_000).rounded())
        let endMs = Int((max(0, endSeconds) * 1_000).rounded())
        return TimestampedWord(
            word: word,
            startMs: startMs,
            endMs: max(startMs, endMs),
            confidence: min(1, max(0, Double(probability)))
        )
    }

    #if canImport(WhisperKit)
    static func makeDecodingOptions(language: String?) -> DecodingOptions {
        let resolvedLanguage = SpeechEnginePreference.normalizeLanguage(language)
        return DecodingOptions(
            language: resolvedLanguage,
            usePrefillPrompt: resolvedLanguage != nil,
            detectLanguage: resolvedLanguage == nil,
            wordTimestamps: true
        )
    }

    private static func transcribeWithLanguageFallback(
        _ whisperKit: WhisperKit,
        audioPath: String,
        requestedLanguage: String?,
        callback: TranscriptionCallback
    ) async throws -> TranscriptionResult {
        let result = try await transcribeWithWhisperKit(
            whisperKit,
            audioPaths: [audioPath],
            decodeOptions: makeDecodingOptions(language: requestedLanguage),
            callback: callback
        )

        guard requestedLanguage != nil, shouldRetryWithoutForcedLanguage(result) else {
            return result
        }

        return try await transcribeWithWhisperKit(
            whisperKit,
            audioPaths: [audioPath],
            decodeOptions: makeDecodingOptions(language: nil),
            callback: callback
        )
    }

    private static func transcribeWithWhisperKit(
        _ whisperKit: WhisperKit,
        audioPaths: [String],
        decodeOptions: DecodingOptions,
        callback: TranscriptionCallback
    ) async throws -> TranscriptionResult {
        let results = await whisperKit.transcribeWithResults(
            audioPaths: audioPaths,
            decodeOptions: decodeOptions,
            callback: callback
        )

        guard let first = results.first else {
            throw STTError.invalidResponse
        }

        let partialResults = try first.get()
        return TranscriptionUtilities.mergeTranscriptionResults(partialResults)
    }

    private static func makeResult(from merged: TranscriptionResult, modelVariant: String) -> STTResult {
        STTResult(
            text: merged.text,
            words: Self.mapWordTimings(merged.allWords),
            language: merged.language,
            engine: .whisper,
            engineVariant: modelVariant
        )
    }

    static func shouldRetryWithoutForcedLanguage(_ result: TranscriptionResult) -> Bool {
        result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && result.allWords.isEmpty
    }

    static func mapWordTimings(_ words: [WordTiming]) -> [TimestampedWord] {
        words.map {
            makeTimestampedWord(
                word: $0.word,
                startSeconds: $0.start,
                endSeconds: $0.end,
                probability: $0.probability
            )
        }
    }
    #endif

    private static func isTokenBoundaryModelFolder(folderName: String, normalizedModel: String) -> Bool {
        let folder = folderName.lowercased()
        let model = normalizedModel.lowercased()
        guard !model.isEmpty else { return false }

        var searchRange: Range<String.Index>? = folder.startIndex..<folder.endIndex
        while let range = folder.range(of: model, range: searchRange) {
            let before = range.lowerBound == folder.startIndex
                ? nil
                : folder[folder.index(before: range.lowerBound)]
            let after = range.upperBound == folder.endIndex
                ? nil
                : folder[range.upperBound]

            if isModelNameBoundary(before) && isModelNameBoundary(after) {
                return true
            }
            searchRange = range.upperBound..<folder.endIndex
        }

        return false
    }

    private static func isModelNameBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        return character == "-" || character == "_" || character == "/" || character == "."
    }

    private nonisolated static func makePrepareWatchdog(
        modelVariant: String,
        folderName: String,
        onProgress: (@Sendable (String) -> Void)?
    ) -> Task<Void, Never> {
        Task.detached(priority: .background) {
            let milestones: [(elapsedSeconds: Int, message: String)] = [
                (15, "Optimizing Whisper for this Mac..."),
                (60, "Still optimizing Whisper with Core ML. The first load can take a few minutes..."),
                (180, "Still preparing Whisper. This one-time optimization should be faster next time..."),
                (300, "Whisper is still optimizing. Leave MacParakeet open until Core ML finishes...")
            ]

            var previousElapsedSeconds = 0
            for milestone in milestones {
                try? await Task.sleep(for: .seconds(milestone.elapsedSeconds - previousElapsedSeconds))
                guard !Task.isCancelled else { return }
                previousElapsedSeconds = milestone.elapsedSeconds
                onProgress?(milestone.message)
                AudioCaptureDiagnostics.append(
                    "whisper_model_prepare_still_loading elapsed_s=\(milestone.elapsedSeconds) model=\(modelVariant) folder=\(folderName)"
                )
            }
        }
    }

    private nonisolated static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private nonisolated static func mapWarmUpError(_ error: Error) throws -> STTError {
        if error is CancellationError {
            throw error
        }
        if let sttError = error as? STTError {
            return sttError
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
        return .engineStartFailed(error.localizedDescription)
    }

    private nonisolated static func mapTranscriptionError(_ error: Error) throws -> STTError {
        if error is CancellationError {
            throw error
        }
        if let sttError = error as? STTError {
            return sttError
        }
        return .transcriptionFailed(error.localizedDescription)
    }
}
