import FluidAudio
import Foundation

/// STT client backed by FluidAudio CoreML/ANE runtime.
public actor STTClient: STTClientProtocol {
    private var manager: AsrManager?
    private var models: AsrModels?
    private var initializationTask: Task<Void, Error>?
    private let modelVersion: AsrModelVersion

    public init(modelVersion: AsrModelVersion = .v3) {
        self.modelVersion = modelVersion
    }

    public func transcribe(audioPath: String, onProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> STTResult {
        try await ensureInitialized()

        guard let manager else {
            throw STTError.modelNotLoaded
        }

        let audioURL = URL(fileURLWithPath: audioPath)

        onProgress?(0, 100)

        do {
            let result = try await manager.transcribe(audioURL, source: .system)
            let words = Self.mergeTokenTimingsIntoWords(result.tokenTimings)
            onProgress?(100, 100)
            return STTResult(text: result.text, words: words)
        } catch {
            throw Self.mapTranscriptionError(error)
        }
    }

    public func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        let cacheDir = AsrModels.defaultCacheDirectory(for: modelVersion)
        let isCached = AsrModels.modelsExist(at: cacheDir, version: modelVersion)

        if !isCached {
            onProgress?("Downloading speech model...")
        }
        onProgress?("Loading model into memory...")

        do {
            try await ensureInitialized()
            onProgress?("Ready")
        } catch {
            throw Self.mapWarmUpError(error)
        }
    }

    public func isReady() async -> Bool {
        guard let manager else { return false }
        return manager.isAvailable
    }

    public func shutdown() async {
        initializationTask?.cancel()
        initializationTask = nil
        manager?.cleanup()
        manager = nil
        models = nil
    }

    public nonisolated static func isModelCached(version: AsrModelVersion = .v3) -> Bool {
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        return AsrModels.modelsExist(at: cacheDir, version: version)
    }

    // MARK: - Private

    private func ensureInitialized() async throws {
        if let manager, manager.isAvailable {
            return
        }

        if let initializationTask {
            try await initializationTask.value
            return
        }

        let version = modelVersion
        let task = Task {
            let downloadedModels = try await AsrModels.downloadAndLoad(version: version)
            let asrManager = AsrManager(config: .default)
            try await asrManager.initialize(models: downloadedModels)
            completeInitialization(models: downloadedModels, manager: asrManager)
        }

        initializationTask = task

        do {
            try await task.value
        } catch {
            initializationTask = nil
            throw error
        }
    }

    private func completeInitialization(models: AsrModels, manager: AsrManager) {
        self.models = models
        self.manager = manager
        self.initializationTask = nil
    }

    private nonisolated static func mapWarmUpError(_ error: Error) -> STTError {
        if let mapped = mapCommonError(error) {
            return mapped
        }
        return .engineStartFailed(error.localizedDescription)
    }

    private nonisolated static func mapTranscriptionError(_ error: Error) -> STTError {
        if let mapped = mapCommonError(error) {
            return mapped
        }
        return .transcriptionFailed(error.localizedDescription)
    }

    private nonisolated static func mapCommonError(_ error: Error) -> STTError? {
        if let sttError = error as? STTError {
            return sttError
        }

        if let asrError = error as? ASRError {
            switch asrError {
            case .notInitialized:
                return .modelNotLoaded
            case .invalidAudioData:
                return .transcriptionFailed(asrError.localizedDescription)
            case .modelLoadFailed, .modelCompilationFailed:
                return .engineStartFailed(asrError.localizedDescription)
            case .processingFailed(let message):
                return .transcriptionFailed(message)
            case .unsupportedPlatform(let message):
                return .engineStartFailed(message)
            case .streamingConversionFailed, .fileAccessFailed:
                return .transcriptionFailed(asrError.localizedDescription)
            }
        }

        if let modelError = error as? AsrModelsError {
            return .engineStartFailed(modelError.localizedDescription)
        }

        return nil
    }

    private nonisolated static func mergeTokenTimingsIntoWords(_ tokenTimings: [TokenTiming]?) -> [TimestampedWord] {
        guard let tokenTimings, !tokenTimings.isEmpty else { return [] }

        var words: [TimestampedWord] = []
        var currentWord = ""
        var currentStartTime: TimeInterval?
        var currentEndTime: TimeInterval = 0
        var currentConfidences: [Float] = []

        func flushCurrentWord() {
            guard !currentWord.isEmpty, let startTime = currentStartTime else { return }
            let averageConfidence = currentConfidences.isEmpty
                ? 0.0
                : (currentConfidences.reduce(0, +) / Float(currentConfidences.count))

            words.append(
                TimestampedWord(
                    word: currentWord,
                    startMs: Int((startTime * 1_000).rounded()),
                    endMs: Int((currentEndTime * 1_000).rounded()),
                    confidence: Double(averageConfidence)
                ))

            currentWord = ""
            currentStartTime = nil
            currentEndTime = 0
            currentConfidences.removeAll(keepingCapacity: true)
        }

        for timing in tokenTimings {
            let normalizedToken = timing.token.replacingOccurrences(of: "▁", with: " ")
            let trimmedToken = normalizedToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedToken.isEmpty else { continue }

            if normalizedToken.hasPrefix(" ") || normalizedToken.hasPrefix("\n") || normalizedToken.hasPrefix("\t") {
                flushCurrentWord()
                currentWord = trimmedToken
                currentStartTime = timing.startTime
                currentEndTime = timing.endTime
                currentConfidences = [timing.confidence]
            } else {
                if currentStartTime == nil {
                    currentStartTime = timing.startTime
                }
                currentWord += trimmedToken
                currentEndTime = timing.endTime
                currentConfidences.append(timing.confidence)
            }
        }

        flushCurrentWord()
        return words
    }
}
