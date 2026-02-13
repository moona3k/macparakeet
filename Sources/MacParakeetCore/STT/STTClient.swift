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
        let transcriptionProgressTask: Task<Void, Never>? = if let onProgress {
            Task {
                do {
                    let progressStream = await manager.transcriptionProgressStream
                    var lastProgress = -1
                    for try await value in progressStream {
                        let percent = min(99, max(0, Int((value * 100).rounded())))
                        guard percent != lastProgress else { continue }
                        lastProgress = percent
                        onProgress(percent, 100)
                    }
                } catch {
                    // Transcription still completes (or fails) independently.
                }
            }
        } else {
            nil
        }
        defer {
            transcriptionProgressTask?.cancel()
        }

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
        let modelDownloadProgressTask: Task<Void, Never>? = if !isCached, let onProgress {
            Task {
                await Self.emitModelDownloadProgress(
                    requiredModelNames: Array(AsrModels.requiredModelNames),
                    cacheDirectory: cacheDir,
                    onProgress: onProgress
                )
            }
        } else {
            nil
        }
        defer {
            modelDownloadProgressTask?.cancel()
        }

        if !isCached {
            onProgress?(Self.modelDownloadProgressMessage(completedCount: 0, totalCount: AsrModels.requiredModelNames.count))
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

    private nonisolated static func emitModelDownloadProgress(
        requiredModelNames: [String],
        cacheDirectory: URL,
        onProgress: @escaping @Sendable (String) -> Void
    ) async {
        let sortedModelNames = requiredModelNames.sorted()
        var lastCompletedCount = -1

        while !Task.isCancelled {
            let completedCount = sortedModelNames.reduce(into: 0) { count, name in
                let modelPath = cacheDirectory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: modelPath.path) {
                    count += 1
                }
            }

            if completedCount != lastCompletedCount {
                lastCompletedCount = completedCount
                onProgress(modelDownloadProgressMessage(completedCount: completedCount, totalCount: sortedModelNames.count))
            }

            if completedCount >= sortedModelNames.count {
                return
            }

            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }

    private nonisolated static func modelDownloadProgressMessage(completedCount: Int, totalCount: Int) -> String {
        guard totalCount > 0 else {
            return "Downloading speech model..."
        }

        let boundedCompleted = max(0, min(completedCount, totalCount))
        let percent = Int((Double(boundedCompleted) / Double(totalCount) * 100.0).rounded())
        return "Downloading speech model... \(percent)% (\(boundedCompleted)/\(totalCount))"
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
