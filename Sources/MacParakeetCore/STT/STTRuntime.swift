import FluidAudio
import Foundation
import os

protocol STTRuntimeProtocol: Sendable {
    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult
    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws
    func backgroundWarmUp() async
    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>)
    func removeWarmUpObserver(id: UUID) async
    func isReady() async -> Bool
    func shutdown() async
    func clearModelCache() async
}

/// Sole owner of the shared Parakeet STT lifecycle.
///
/// The runtime stays process-wide and singular at the app boundary, but it keeps
/// one `AsrManager` per execution slot so dictation remains isolated from the
/// shared background workload inside app-level scheduling.
public actor STTRuntime: STTRuntimeProtocol {
    private var interactiveManager: AsrManager?
    private var backgroundManager: AsrManager?
    private var models: AsrModels?
    private var initializationTask: Task<Void, Error>?
    private var initializationGeneration: UInt64 = 0
    private var warmUpProgressHandler: (@Sendable (String) -> Void)?
    private let modelVersion: AsrModelVersion

    private var backgroundWarmUpState: STTWarmUpState = .idle
    private var backgroundWarmUpTask: Task<Void, Never>?
    private var warmUpObservers: [UUID: AsyncStream<STTWarmUpState>.Continuation] = [:]
    private var backgroundWarmUpGeneration: UInt64 = 0

    public init(modelVersion: AsrModelVersion = .v3) {
        self.modelVersion = modelVersion
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        try await ensureInitialized()

        let slot = route(for: job)
        guard let manager = manager(for: slot) else {
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
                    // The transcription task completes or fails independently.
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
            let result = try await manager.transcribe(audioURL)
            let words = Self.mergeTokenTimingsIntoWords(result.tokenTimings)
            onProgress?(100, 100)
            return STTResult(text: result.text, words: words)
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
    }

    /// Warms the runtime and reports progress through `onProgress` only.
    ///
    /// This method does not update `observeWarmUpProgress()` observers. Call
    /// `backgroundWarmUp()` when UI state should flow through the shared
    /// observer stream instead of a one-off callback.
    public func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        warmUpProgressHandler = onProgress
        defer {
            warmUpProgressHandler = nil
        }

        onProgress?("Loading model into memory...")

        let start = ContinuousClock.now
        do {
            try await ensureInitialized()
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            Telemetry.send(.modelLoaded(loadTimeSeconds: seconds))
            onProgress?("Ready")
        } catch {
            throw try Self.mapWarmUpError(error)
        }
    }

    public func backgroundWarmUp() async {
        if case .ready = backgroundWarmUpState { return }
        if backgroundWarmUpTask != nil { return }

        let generation = beginBackgroundWarmUp()
        prepareBackgroundWarmUpForRetry()
        setBackgroundWarmUpState(
            .working(message: "Checking setup requirements...", progress: nil),
            generation: generation
        )
        backgroundWarmUpTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.warmUp { [weak self] progressMessage in
                    guard let self else { return }
                    Task { [weak self] in
                        guard let self else { return }
                        let message = "Speech model: \(progressMessage)"
                        let fraction = OnboardingProgressParser.parseProgressFraction(from: message)
                        await self.setBackgroundWarmUpState(
                            .working(message: message, progress: fraction),
                            generation: generation
                        )
                    }
                }
                try Task.checkCancellation()
                await self.setBackgroundWarmUpState(.ready, generation: generation)
            } catch is CancellationError {
                // Cancelled — don't update state.
            } catch {
                await self.setBackgroundWarmUpState(.failed(message: error.localizedDescription), generation: generation)
            }
            await self.clearBackgroundWarmUpTask(generation: generation)
        }
    }

    public func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let id = UUID()
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(backgroundWarmUpState)
            warmUpObservers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { [weak self] in
                    await self?.removeWarmUpObserver(id: id)
                }
            }
        }
        return (id, stream)
    }

    public func removeWarmUpObserver(id: UUID) async {
        warmUpObservers.removeValue(forKey: id)?.finish()
    }

    public func isReady() async -> Bool {
        guard let interactiveManager, let backgroundManager else { return false }
        let interactiveReady = await interactiveManager.isAvailable
        let backgroundReady = await backgroundManager.isAvailable
        return interactiveReady && backgroundReady
    }

    public func shutdown() async {
        invalidateBackgroundWarmUp()
        let inFlightInitialization = cancelInitialization()
        inFlightInitialization?.cancel()
        _ = try? await inFlightInitialization?.value

        let interactiveManager = self.interactiveManager
        let backgroundManager = self.backgroundManager
        self.interactiveManager = nil
        self.backgroundManager = nil
        self.models = nil
        await Self.cleanupManagers(
            interactiveManager: interactiveManager,
            backgroundManager: backgroundManager
        )
        warmUpProgressHandler = nil
        setBackgroundWarmUpState(.idle)
    }

    public func clearModelCache() async {
        await shutdown()
        DownloadUtils.clearAllModelCaches()
        setBackgroundWarmUpState(.idle)
    }

    public nonisolated static func isModelCached(version: AsrModelVersion = .v3) -> Bool {
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        return AsrModels.modelsExist(at: cacheDir, version: version)
    }

    private func beginBackgroundWarmUp() -> UInt64 {
        backgroundWarmUpGeneration &+= 1
        return backgroundWarmUpGeneration
    }

    private func invalidateBackgroundWarmUp() {
        backgroundWarmUpGeneration &+= 1
        backgroundWarmUpTask?.cancel()
        backgroundWarmUpTask = nil
    }

    private func prepareBackgroundWarmUpForRetry() {
        if case .failed = backgroundWarmUpState {
            backgroundWarmUpState = .idle
        }
    }

    private func setBackgroundWarmUpState(_ state: STTWarmUpState, generation: UInt64) {
        guard generation == backgroundWarmUpGeneration else { return }
        setBackgroundWarmUpState(state)
    }

    private func setBackgroundWarmUpState(_ state: STTWarmUpState) {
        if case .working = state {
            switch backgroundWarmUpState {
            case .ready, .failed: return
            default: break
            }
        }
        backgroundWarmUpState = state
        for (_, continuation) in warmUpObservers {
            continuation.yield(state)
        }
    }

    private func clearBackgroundWarmUpTask(generation: UInt64) {
        guard generation == backgroundWarmUpGeneration else { return }
        backgroundWarmUpTask = nil
    }

    private func ensureInitialized() async throws {
        if interactiveManager != nil, backgroundManager != nil {
            return
        }

        if let initializationTask {
            try await initializationTask.value
            return
        }

        let generation = nextInitializationGeneration()
        let version = modelVersion
        let warmUpProgressHandler = self.warmUpProgressHandler
        let task = Task {
            let lastProgressUpdate = OSAllocatedUnfairLock(initialState: Date.distantPast)
            let lastProgressMessage = OSAllocatedUnfairLock(initialState: "")
            var interactiveManager: AsrManager?
            var backgroundManager: AsrManager?
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
            do {
                // FluidAudio progress is manager-scoped, so each slot keeps its
                // own manager while the read-only model bundle stays shared.
                let loadedInteractiveManager = AsrManager(config: .default)
                let loadedBackgroundManager = AsrManager(config: .default)
                interactiveManager = loadedInteractiveManager
                backgroundManager = loadedBackgroundManager
                try await loadedInteractiveManager.loadModels(downloadedModels)
                try await loadedBackgroundManager.loadModels(downloadedModels)
                try Task.checkCancellation()
                try await self.completeInitialization(
                    generation: generation,
                    models: downloadedModels,
                    interactiveManager: loadedInteractiveManager,
                    backgroundManager: loadedBackgroundManager
                )
                interactiveManager = nil
                backgroundManager = nil
            } catch {
                await Self.cleanupManagers(
                    interactiveManager: interactiveManager,
                    backgroundManager: backgroundManager
                )
                throw error
            }
        }

        initializationTask = task

        do {
            try await task.value
            if initializationGeneration == generation {
                initializationTask = nil
            }
        } catch {
            if initializationGeneration == generation {
                initializationTask = nil
            }
            throw error
        }
    }

    private func completeInitialization(
        generation: UInt64,
        models: AsrModels,
        interactiveManager: AsrManager,
        backgroundManager: AsrManager
    ) async throws {
        guard initializationGeneration == generation else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        self.models = models
        self.interactiveManager = interactiveManager
        self.backgroundManager = backgroundManager
    }

    private func nextInitializationGeneration() -> UInt64 {
        initializationGeneration &+= 1
        return initializationGeneration
    }

    private func cancelInitialization() -> Task<Void, Error>? {
        initializationGeneration &+= 1
        let task = initializationTask
        initializationTask = nil
        return task
    }

    private nonisolated static func cleanupManagers(
        interactiveManager: AsrManager?,
        backgroundManager: AsrManager?
    ) async {
        if let interactiveManager {
            await interactiveManager.cleanup()
        }
        if let backgroundManager {
            await backgroundManager.cleanup()
        }
    }

    private func manager(for lane: STTRuntimeLane) -> AsrManager? {
        switch lane {
        case .interactive:
            interactiveManager
        case .background:
            backgroundManager
        }
    }

    private func route(for job: STTJobKind) -> STTRuntimeLane {
        switch job {
        case .dictation:
            .interactive
        case .meetingFinalize, .meetingLiveChunk, .fileTranscription:
            .background
        }
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

private enum STTRuntimeLane: Sendable {
    case interactive
    case background
}
