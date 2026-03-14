import FluidAudio
import Foundation
import os

/// STT client backed by FluidAudio CoreML/ANE runtime.
public actor STTClient: STTClientProtocol {
    private var manager: AsrManager?
    private var models: AsrModels?
    private var initializationTask: Task<Void, Error>?
    private var warmUpProgressHandler: (@Sendable (String) -> Void)?
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
            try Task.checkCancellation()
            let result = try await manager.transcribe(audioURL, source: .system)
            let words = Self.mergeTokenTimingsIntoWords(result.tokenTimings)
            onProgress?(100, 100)
            return STTResult(text: result.text, words: words)
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
    }

    public func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        warmUpProgressHandler = onProgress
        defer {
            warmUpProgressHandler = nil
        }

        onProgress?("Loading model into memory...")

        do {
            try await ensureInitialized()
            onProgress?("Ready")
        } catch {
            throw try Self.mapWarmUpError(error)
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
        warmUpProgressHandler = nil
    }

    public func clearModelCache() async {
        await shutdown()
        DownloadUtils.clearAllModelCaches()
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
        let warmUpProgressHandler = self.warmUpProgressHandler
        let task = Task {
            let lastProgressUpdate = OSAllocatedUnfairLock(initialState: Date.distantPast)
            let lastProgressMessage = OSAllocatedUnfairLock(initialState: "")
            let progressHandler: DownloadUtils.ProgressHandler?
            if let warmUpProgressHandler {
                let progressCallback: @Sendable (String) -> Void = warmUpProgressHandler
                progressHandler = { progress in
                    guard let message = Self.warmUpProgressMessage(from: progress) else { return }
                    let now = Date()
                    let shouldEmit = lastProgressUpdate.withLock { lastUpdate in
                        guard now.timeIntervalSince(lastUpdate) >= 0.25 else {
                            return false
                        }
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

                    progressCallback(message)
                }
            } else {
                progressHandler = nil
            }

            let downloadedModels = try await AsrModels.downloadAndLoad(
                version: version,
                progressHandler: progressHandler
            )
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

    private nonisolated static func mapWarmUpError(_ error: Error) throws -> STTError {
        if error is CancellationError {
            throw error
        }
        if let mapped = mapCommonError(error) {
            return mapped
        }
        return .engineStartFailed(error.localizedDescription)
    }

    private nonisolated static func mapTranscriptionError(_ error: Error) throws -> STTError {
        if error is CancellationError {
            throw error
        }
        if let mapped = mapCommonError(error) {
            return mapped
        }
        return .transcriptionFailed(error.localizedDescription)
    }

    private nonisolated static func mapCommonError(_ error: Error) -> STTError? {
        if error is CancellationError {
            return nil
        }

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

    private nonisolated static func warmUpProgressMessage(from progress: DownloadUtils.DownloadProgress) -> String? {
        switch progress.phase {
        case .listing:
            return "Preparing speech model download..."
        case .downloading(let completedFiles, let totalFiles):
            guard totalFiles > 0 else { return nil }
            let percent = max(0, min(100, Int(progress.fractionCompleted * 100.0)))
            return "Downloading speech model... \(percent)% (\(completedFiles)/\(totalFiles))"
        case .compiling:
            return "Compiling speech model..."
        }
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
