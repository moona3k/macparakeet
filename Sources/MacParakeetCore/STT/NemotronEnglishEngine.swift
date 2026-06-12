import AVFoundation
import FluidAudio
import Foundation
import os

/// Wraps FluidAudio's English-only `StreamingNemotronAsrManager`
/// (Nemotron Speech Streaming EN 0.6B). Sibling of `NemotronEngine`, which
/// wraps the multilingual manager — the two FluidAudio managers share no API
/// surface for language hints, shared weights, or cache layout, so each build
/// gets its own engine actor and `STTRuntime` routes on the persisted
/// `NemotronModelVariant`.
///
/// Streaming-only model driven batch-at-stop: the whole file is resampled,
/// then fed through the streaming manager in bounded slices and finalized.
public actor NemotronEnglishEngine: STTTranscribing {
    public static let modelVariant = NemotronModelVariant.english1120

    /// Samples per feed slice (10 s at 16 kHz). The manager's internal buffer
    /// drains with `removeFirst` per 1120 ms chunk, so slice size bounds both
    /// peak buffer copies and the O(buffer) memmove cost per chunk; it also
    /// sets the cancellation-check and progress granularity.
    private static let sliceSampleCount = 160_000
    private static let targetSampleRate = 16_000.0

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "NemotronEnglishEngine")

    private var interactiveManager: StreamingNemotronAsrManager?
    private var backgroundManager: StreamingNemotronAsrManager?
    private var initializationTask: Task<Void, Error>?
    private var activeLanes: Set<NemotronEnglishRuntimeLane> = []

    public init() {}

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        try await transcribe(
            audioURL: URL(fileURLWithPath: audioPath),
            job: job,
            onProgress: onProgress
        )
    }

    public func transcribe(
        audioURL: URL,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        let lane = route(for: job)
        guard beginTranscription(on: lane) else {
            throw STTError.engineBusy
        }
        defer { endTranscription(on: lane) }

        do {
            try await prepare(onProgress: nil)
            guard let manager = manager(for: lane) else {
                throw STTError.modelNotLoaded
            }
            // Fresh session: clears encoder caches, decoder LSTM state, and any
            // buffered audio a cancelled prior job may have left behind.
            await manager.reset()

            onProgress?(0, 100)
            try Task.checkCancellation()
            let samples = try await Task.detached(priority: .userInitiated) {
                try AudioConverter().resampleAudioFile(audioURL)
            }.value
            onProgress?(25, 100)

            var offset = 0
            while offset < samples.count {
                try Task.checkCancellation()
                let end = min(offset + Self.sliceSampleCount, samples.count)
                let buffer = try Self.makePCMBuffer(samples: samples[offset..<end])
                _ = try await manager.process(audioBuffer: buffer)
                offset = end
                if !samples.isEmpty {
                    let fraction = Double(offset) / Double(samples.count)
                    onProgress?(25 + Int(fraction * 65), 100)
                }
            }
            let text = try await manager.finish()
            onProgress?(100, 100)

            // `language` reflects the build's fixed configuration (the model is
            // English-only), mirroring the Parakeet attribution posture. No
            // word timings: the streaming RNN-T path exposes none (same
            // posture as the multilingual Nemotron build).
            return STTResult(
                text: text,
                words: [],
                language: "en",
                engine: .nemotron,
                engineVariant: Self.modelVariant.rawValue
            )
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
    }

    public func prepare(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        if isLoaded { return }

        if let initializationTask {
            try await initializationTask.value
            return
        }

        let task = Task {
            try await loadManagers(onProgress: onProgress)
        }
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

        let interactiveManager = self.interactiveManager
        let backgroundManager = self.backgroundManager
        self.interactiveManager = nil
        self.backgroundManager = nil

        await interactiveManager?.cleanup()
        await backgroundManager?.cleanup()
    }

    public func isReady() -> Bool {
        isLoaded
    }

    /// `<Application Support>/FluidAudio/Models` — the base FluidAudio's
    /// `loadModels(to:)` resolves when no directory is passed.
    nonisolated static func modelsBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// The 1120 ms tier directory (`…/Models/nemotron-streaming/1120ms`).
    /// Unlike the multilingual build there is no language dimension — one flat
    /// per-tier folder, keyed by `Repo.nemotronStreaming1120.folderName`.
    public nonisolated static func defaultCacheRoot() -> URL {
        modelsBaseDirectory()
            .appendingPathComponent(Repo.nemotronStreaming1120.folderName, isDirectory: true)
    }

    public nonisolated static func isModelCached() -> Bool {
        isModelCached(cacheRoot: defaultCacheRoot())
    }

    /// Cached only when both `metadata.json` and the int8 encoder are present:
    /// the encoder is the manager's own download gate, and without metadata the
    /// manager would silently fall back to `NemotronStreamingConfig()`'s 2240 ms
    /// chunk geometry — the wrong tier for this build.
    nonisolated static func isModelCached(cacheRoot: URL) -> Bool {
        let fileManager = FileManager.default
        let metadata = cacheRoot.appendingPathComponent(ModelNames.NemotronStreaming.metadata)
        let encoder = cacheRoot.appendingPathComponent(ModelNames.NemotronStreaming.encoderInt8File)
        return fileManager.fileExists(atPath: metadata.path)
            && fileManager.fileExists(atPath: encoder.path)
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
        guard let children = try? fileManager.contentsOfDirectory(atPath: directory.path),
              children.isEmpty else {
            return
        }
        try? fileManager.removeItem(at: directory)
    }

    /// Pre-fetches the model to its cache without loading it. A cached model is
    /// a cheap no-op, mirroring `NemotronEngine.downloadModel`.
    @discardableResult
    public nonisolated static func downloadModel(
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let cacheRoot = defaultCacheRoot()
        guard !isModelCached(cacheRoot: cacheRoot) else { return cacheRoot }
        onProgress?("Preparing Nemotron model download...")
        let progressHandler = makeDownloadProgressHandler(onProgress)
        try await DownloadUtils.downloadRepo(
            .nemotronStreaming1120,
            to: modelsBaseDirectory(),
            progressHandler: progressHandler
        )
        return cacheRoot
    }

    private var isLoaded: Bool {
        interactiveManager != nil && backgroundManager != nil
    }

    private func loadManagers(onProgress: (@Sendable (String) -> Void)?) async throws {
        onProgress?("Preparing Nemotron model download...")
        let progressHandler = Self.makeDownloadProgressHandler(onProgress)

        // No shared-weights API on the English manager (unlike the multilingual
        // `loadFromShared` path); both lanes load the same compiled artifacts,
        // which CoreML maps read-only, so the dominant encoder weights are
        // shared via the page cache rather than duplicated per instance.
        let loadedInteractiveManager = StreamingNemotronAsrManager(requestedChunkSize: .ms1120)
        let loadedBackgroundManager = StreamingNemotronAsrManager(requestedChunkSize: .ms1120)
        try await loadedInteractiveManager.loadModels(
            to: nil,
            configuration: nil,
            progressHandler: progressHandler
        )
        try await loadedBackgroundManager.loadModels(
            to: nil,
            configuration: nil,
            progressHandler: progressHandler
        )

        self.interactiveManager = loadedInteractiveManager
        self.backgroundManager = loadedBackgroundManager
        logger.notice("nemotron_english_model_prepare_complete variant=\(Self.modelVariant.rawValue, privacy: .public)")
        AudioCaptureDiagnostics.append("nemotron_english_model_prepare_complete variant=\(Self.modelVariant.rawValue)")
        onProgress?("Ready")
    }

    private func manager(for lane: NemotronEnglishRuntimeLane) -> StreamingNemotronAsrManager? {
        switch lane {
        case .interactive:
            interactiveManager
        case .background:
            backgroundManager
        }
    }

    private func route(for job: STTJobKind) -> NemotronEnglishRuntimeLane {
        switch job {
        case .dictation:
            .interactive
        case .meetingFinalize, .meetingLiveChunk, .fileTranscription:
            .background
        }
    }

    private func beginTranscription(on lane: NemotronEnglishRuntimeLane) -> Bool {
        guard !activeLanes.contains(lane) else { return false }
        activeLanes.insert(lane)
        return true
    }

    private func endTranscription(on lane: NemotronEnglishRuntimeLane) {
        activeLanes.remove(lane)
    }

    /// Wraps one resampled slice in the manager's target format
    /// (16 kHz mono Float32, non-interleaved), so `resampleBuffer`'s fast path
    /// extracts the samples without a second resample.
    private nonisolated static func makePCMBuffer(samples: ArraySlice<Float>) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channelData = buffer.floatChannelData else {
            throw STTError.transcriptionFailed("Failed to allocate audio buffer for Nemotron streaming")
        }
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channelData[0].update(from: baseAddress, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
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
            return "Preparing Nemotron model download..."
        case .downloading(let completedFiles, let totalFiles):
            guard totalFiles > 0 else { return nil }
            let percent = max(0, min(100, Int(progress.fractionCompleted * 100.0)))
            return "Downloading Nemotron model... \(percent)% (\(completedFiles)/\(totalFiles))"
        case .compiling:
            return "Compiling Nemotron model..."
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

private enum NemotronEnglishRuntimeLane: Hashable, Sendable {
    case interactive
    case background
}
