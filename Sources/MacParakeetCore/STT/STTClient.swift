import FluidAudio
import Foundation
import os

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
        return .daemonStartFailed(error.localizedDescription)
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
                return .daemonStartFailed(asrError.localizedDescription)
            case .processingFailed(let message):
                return .transcriptionFailed(message)
            case .unsupportedPlatform(let message):
                return .daemonStartFailed(message)
            case .streamingConversionFailed, .fileAccessFailed:
                return .transcriptionFailed(asrError.localizedDescription)
            }
        }

        if let modelError = error as? AsrModelsError {
            return .daemonStartFailed(modelError.localizedDescription)
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

    nonisolated static func consumeProgressUpdates(
        from buffer: inout Data,
        appending chunk: Data,
        consumeTrailingLine: Bool = false
    ) -> [(Int, Int)] {
        buffer.append(chunk)
        var updates: [(Int, Int)] = []

        while let newlineIdx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newlineIdx)
            buffer.removeSubrange(..<buffer.index(after: newlineIdx))
            if let update = parseProgressUpdate(lineData: lineData) {
                updates.append(update)
            }
        }

        if consumeTrailingLine, !buffer.isEmpty {
            if let update = parseProgressUpdate(lineData: buffer[...]) {
                updates.append(update)
            }
            buffer.removeAll(keepingCapacity: true)
        }

        return updates
    }

    // MARK: - Setup Progress Parsing

    nonisolated static func consumeSetupProgressUpdates(
        from buffer: inout Data,
        appending chunk: Data,
        consumeTrailingLine: Bool = false
    ) -> [String] {
        buffer.append(chunk)
        var messages: [String] = []

        while let newlineIdx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newlineIdx)
            buffer.removeSubrange(..<buffer.index(after: newlineIdx))
            if let message = parseSetupProgressLine(lineData: lineData[...]) {
                messages.append(message)
            }
        }

        if consumeTrailingLine, !buffer.isEmpty {
            if let message = parseSetupProgressLine(lineData: buffer[...]) {
                messages.append(message)
            }
            buffer.removeAll(keepingCapacity: true)
        }

        return messages
    }

    nonisolated static func parseSetupProgressLine(lineData: Data.SubSequence) -> String? {
        guard let line = String(data: Data(lineData), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            line.hasPrefix("SETUP_PROGRESS:")
        else {
            return nil
        }

        let payload = line.dropFirst("SETUP_PROGRESS:".count)
        let parts = payload.split(separator: ":", maxSplits: 2)
        guard !parts.isEmpty else { return nil }

        let phase = String(parts[0])
        let bytesDone = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let bytesTotal = parts.count > 2 ? Int(parts[2]) ?? 0 : 0

        switch phase {
        case "downloading_config":
            return "Downloading speech model config..."
        case "downloading_model":
            if bytesTotal > 0 && bytesDone > 0 {
                let totalMB = bytesTotal / (1024 * 1024)
                let pct = Int(Double(bytesDone) / Double(bytesTotal) * 100)
                return "Downloading speech model (\(totalMB) MB)... \(pct)%"
            }
            return "Downloading speech model..."
        case "loading_model":
            return "Loading model into memory..."
        case "ready":
            return "Ready"
        default:
            return nil
        }
    }

    private nonisolated static func parseProgressUpdate(lineData: Data.SubSequence) -> (Int, Int)? {
        guard let line = String(data: Data(lineData), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            line.hasPrefix("PROGRESS:")
        else {
            return nil
        }

        let payload = line.dropFirst("PROGRESS:".count)
        let parts = payload.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
            let current = Int(parts[0]),
            let total = Int(parts[1])
        else {
            return nil
        }
        return (current, total)
    }
}
