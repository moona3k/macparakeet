import AVFoundation
import FluidAudio
import Foundation
import os

/// Wraps FluidAudio's Parakeet Unified managers (NVIDIA Parakeet Unified
/// EN 0.6B). Parakeet Unified is a separate
/// FluidAudio runtime from the TDT v2/v3 builds — it has its own
/// preprocessor/encoder/decoder CoreML chain and no `AsrModelVersion`/
/// `AsrManager` surface — so it gets its own engine actor and `STTRuntime`
/// routes the `.unified` `ParakeetModelVariant` here, exactly as the Nemotron
/// engine routes its English variant to `NemotronEnglishEngine`.
///
/// File, meeting, and recorded-file dictation use FluidAudio's offline
/// `parakeet-unified-offline-15s` path because that remains the best-quality
/// stop-time transcription mode. Live dictation uses the native
/// `StreamingUnifiedAsrManager` (`parakeet-unified-2080ms`) on the interactive
/// lane only to emit partial transcripts while capture is active;
/// `DictationService` still uses the recorded-file offline result for the final
/// paste/history transcript.
///
/// Two lanes (interactive for dictation, background for file/meeting) each get
/// their own `UnifiedAsrManager` so concurrent dictation + file/meeting work
/// (ADR-015) never collides on one actor's buffers. Both instances load the
/// same compiled artifacts, which CoreML maps read-only, so the dominant
/// encoder weights are shared via the page cache rather than duplicated.
public actor ParakeetUnifiedEngine: STTTranscribing, NativeLiveDictating {
    public static let modelVariant = ParakeetModelVariant.unified

    /// int8 is FluidAudio's default and WER-lossless vs fp16 within benchmark
    /// noise, at ~half the download. Kept explicit so the choice is visible at
    /// the callsite that owns the model's disk + battery posture.
    private static let encoderPrecision = UnifiedEncoderPrecision.int8

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "ParakeetUnifiedEngine")

    private var interactiveManager: UnifiedAsrManager?
    private var backgroundManager: UnifiedAsrManager?
    private var liveStreamingManager: StreamingUnifiedAsrManager?
    private var initializationTask: Task<Void, Error>?
    private var activeLanes: Set<ParakeetUnifiedRuntimeLane> = []

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
            // Fresh session: drop any buffered audio a cancelled prior job may
            // have left behind on this lane's manager.
            try await manager.reset()

            onProgress?(0, 100)
            try Task.checkCancellation()
            let recordedSamples = try await Task.detached(priority: .userInitiated) {
                try AudioConverter().resampleAudioFile(audioURL)
            }.value
            let samples = Self.samplesForOfflineTranscription(recordedSamples, job: job)
            onProgress?(20, 100)

            try Task.checkCancellation()
            // The offline manager runs its own overlapping 15 s windows over the
            // whole buffer, so the call is atomic — progress is coarse and
            // cancellation is checked at the boundaries rather than mid-window.
            let text = try await ANEInferenceGate.shared.withExclusiveAccess {
                try await manager.transcribe(samples)
            }
            onProgress?(100, 100)

            // No word timings: the offline `transcribe(_:) -> String` path
            // surfaces none (same posture as the Nemotron builds). `language`
            // reflects the build's fixed configuration — the model is
            // English-only.
            return STTResult(
                text: text,
                words: [],
                language: "en",
                engine: .parakeet,
                engineVariant: Self.modelVariant.rawValue
            )
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
    }

    static func samplesForOfflineTranscription(
        _ samples: [Float],
        job: STTJobKind
    ) -> [Float] {
        guard job == .dictation else { return samples }
        return STTRuntime.appendingTrailingSilence(
            samples,
            seconds: STTRuntime.dictationTrailingSilenceSeconds,
            sampleRate: ASRConstants.sampleRate
        )
    }

    // MARK: - Live dictation

    /// Begins a native streaming dictation session on the interactive lane.
    /// Unified is English-only, so `language` is intentionally ignored.
    public func beginLiveDictation(
        language: String?,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws {
        let lane: ParakeetUnifiedRuntimeLane = .interactive
        guard beginTranscription(on: lane) else {
            throw STTError.engineBusy
        }

        do {
            try await prepare(onProgress: nil)
            guard let manager = liveStreamingManager else {
                throw STTError.modelNotLoaded
            }
            try await manager.reset()
            await manager.setPartialTranscriptCallback { partial in
                onPartial(partial)
            }
        } catch {
            endTranscription(on: lane)
            throw try Self.mapTranscriptionError(error)
        }
    }

    public func processLiveDictationSamples(_ samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        guard let manager = liveStreamingManager,
              activeLanes.contains(.interactive) else {
            throw STTLiveDictationTranscriptionError.sessionNotActive
        }
        do {
            try Task.checkCancellation()
            let buffer = try Self.makePCMBuffer(samples: samples[...])
            try await manager.appendAudio(buffer)
            try await ANEInferenceGate.shared.withExclusiveAccess {
                try await manager.processBufferedAudio()
            }
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
    }

    public func finishLiveDictation() async throws -> STTResult {
        let lane: ParakeetUnifiedRuntimeLane = .interactive
        guard let manager = liveStreamingManager,
              activeLanes.contains(lane) else {
            throw STTLiveDictationTranscriptionError.sessionNotActive
        }
        defer { endTranscription(on: lane) }

        do {
            await manager.setPartialTranscriptCallback { _ in }
            let text = try await ANEInferenceGate.shared.withExclusiveAccess {
                try await manager.finish()
            }
            return STTResult(
                text: text,
                words: [],
                language: "en",
                engine: .parakeet,
                engineVariant: Self.modelVariant.rawValue
            )
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
    }

    public func cancelLiveDictation() async {
        let lane: ParakeetUnifiedRuntimeLane = .interactive
        guard activeLanes.contains(lane) else { return }
        if let manager = liveStreamingManager {
            await manager.setPartialTranscriptCallback { _ in }
            try? await manager.reset()
        }
        endTranscription(on: lane)
    }

    public func prepare(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        if isLoaded { return }

        if let initializationTask {
            do {
                try await initializationTask.value
            } catch {
                throw try Self.mapWarmUpError(error)
            }
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
        let liveStreamingManager = self.liveStreamingManager
        self.interactiveManager = nil
        self.backgroundManager = nil
        self.liveStreamingManager = nil

        await interactiveManager?.cleanup()
        await backgroundManager?.cleanup()
        await liveStreamingManager?.cleanup()
    }

    public func isReady() -> Bool {
        isLoaded
    }

    // MARK: - Model cache / download / delete (statics)

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

    /// `.../Models/parakeet-unified-en-0.6b` - keyed off FluidAudio's own
    /// `Repo.parakeetUnified.folderName` so the path can never drift from where
    /// the manager actually downloads.
    public nonisolated static func defaultCacheRoot() -> URL {
        modelsBaseDirectory()
            .appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true)
    }

    public nonisolated static func isModelCached() -> Bool {
        isModelCached(cacheRoot: defaultCacheRoot())
    }

    nonisolated static func requiredModelFiles() -> Set<String> {
        ModelNames.ParakeetUnified.requiredModels(variant: downloadVariant)
    }

    nonisolated static func requiredStreamingModelFiles() -> Set<String> {
        ModelNames.ParakeetUnified.requiredModels(variant: streamingDownloadVariant)
    }

    nonisolated static func requiredAllModelFiles() -> Set<String> {
        requiredModelFiles().union(requiredStreamingModelFiles())
    }

    /// Cached only when every file FluidAudio needs for both Unified access
    /// paths is present. FluidAudio's own `loadModels(to:)` gates only on the
    /// manager-specific encoder, so MacParakeet must be stricter to let explicit
    /// downloads repair interrupted or partially deleted caches.
    nonisolated static func isModelCached(cacheRoot: URL) -> Bool {
        let fileManager = FileManager.default
        return requiredAllModelFiles().allSatisfy { fileName in
            fileManager.fileExists(atPath: cacheRoot.appendingPathComponent(fileName).path)
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
        return !fileManager.fileExists(atPath: cacheRoot.path)
    }

    /// Pre-fetches the offline model to its cache without loading it. A cached
    /// model is a cheap no-op, mirroring the Nemotron engines' `downloadModel`.
    @discardableResult
    public nonisolated static func downloadModel(
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let cacheRoot = defaultCacheRoot()
        try await downloadModelFilesIfNeeded(cacheRoot: cacheRoot, onProgress: onProgress)
        return cacheRoot
    }

    // MARK: - Internals

    private var isLoaded: Bool {
        interactiveManager != nil && backgroundManager != nil && liveStreamingManager != nil
    }

    private nonisolated static var downloadVariant: String {
        encoderPrecision == .fp16 ? "offline-fp16" : "offline"
    }

    private nonisolated static var streamingDownloadVariant: String? {
        // nil selects FluidAudio's default streaming export, which is the int8
        // encoder. The fp16 export lives under the explicit "fp16" variant key.
        encoderPrecision == .fp16 ? "fp16" : nil
    }

    private nonisolated static func downloadModelFilesIfNeeded(
        cacheRoot: URL,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        let progressHandler = makeDownloadProgressHandler(onProgress)
        if !requiredModelFiles().allSatisfy({
            FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent($0).path)
        }) {
            onProgress?("Preparing Parakeet Unified model download...")
            try await DownloadUtils.downloadRepo(
                .parakeetUnified,
                to: modelsBaseDirectory(),
                variant: downloadVariant,
                progressHandler: progressHandler
            )
        }
        if !requiredStreamingModelFiles().allSatisfy({
            FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent($0).path)
        }) {
            onProgress?("Preparing Parakeet Unified streaming model download...")
            try await DownloadUtils.downloadRepo(
                .parakeetUnified,
                to: modelsBaseDirectory(),
                variant: streamingDownloadVariant,
                progressHandler: progressHandler
            )
        }
    }

    private func loadManagers(onProgress: (@Sendable (String) -> Void)?) async throws {
        try await Self.downloadModelFilesIfNeeded(
            cacheRoot: Self.defaultCacheRoot(),
            onProgress: onProgress
        )
        let progressHandler = Self.makeDownloadProgressHandler(onProgress)

        let loadedInteractiveManager = UnifiedAsrManager(encoderPrecision: Self.encoderPrecision)
        let loadedBackgroundManager = UnifiedAsrManager(encoderPrecision: Self.encoderPrecision)
        let loadedLiveStreamingManager = StreamingUnifiedAsrManager(encoderPrecision: Self.encoderPrecision)
        do {
            try await loadedInteractiveManager.loadModels(
                to: nil,
                configuration: nil,
                progressHandler: progressHandler
            )
            try Task.checkCancellation()
            try await loadedBackgroundManager.loadModels(
                to: nil,
                configuration: nil,
                progressHandler: progressHandler
            )
            try Task.checkCancellation()
            try await loadedLiveStreamingManager.loadModels(
                to: nil,
                configuration: nil,
                progressHandler: progressHandler
            )
            try Task.checkCancellation()
        } catch {
            await loadedInteractiveManager.cleanup()
            await loadedBackgroundManager.cleanup()
            await loadedLiveStreamingManager.cleanup()
            throw error
        }

        self.interactiveManager = loadedInteractiveManager
        self.backgroundManager = loadedBackgroundManager
        self.liveStreamingManager = loadedLiveStreamingManager
        logger.notice("parakeet_unified_model_prepare_complete variant=\(Self.modelVariant.rawValue, privacy: .public)")
        AudioCaptureDiagnostics.append("parakeet_unified_model_prepare_complete variant=\(Self.modelVariant.rawValue)")
        onProgress?("Ready")
    }

    private func manager(for lane: ParakeetUnifiedRuntimeLane) -> UnifiedAsrManager? {
        switch lane {
        case .interactive:
            interactiveManager
        case .background:
            backgroundManager
        }
    }

    private func route(for job: STTJobKind) -> ParakeetUnifiedRuntimeLane {
        switch job {
        case .dictation:
            .interactive
        case .meetingFinalize, .meetingLiveChunk, .fileTranscription:
            .background
        }
    }

    private func beginTranscription(on lane: ParakeetUnifiedRuntimeLane) -> Bool {
        guard !activeLanes.contains(lane) else { return false }
        activeLanes.insert(lane)
        return true
    }

    private func endTranscription(on lane: ParakeetUnifiedRuntimeLane) {
        activeLanes.remove(lane)
    }

    private nonisolated static func makePCMBuffer(samples: ArraySlice<Float>) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channelData = buffer.floatChannelData else {
            throw STTError.transcriptionFailed("Failed to allocate audio buffer for Parakeet Unified streaming")
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
            return "Preparing Parakeet Unified model download..."
        case .downloading(let completedFiles, let totalFiles):
            guard totalFiles > 0 else { return nil }
            let percent = max(0, min(100, Int(progress.fractionCompleted * 100.0)))
            return "Downloading Parakeet Unified model... \(percent)% (\(completedFiles)/\(totalFiles))"
        case .compiling:
            return "Compiling Parakeet Unified model..."
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

private enum ParakeetUnifiedRuntimeLane: Hashable, Sendable {
    case interactive
    case background
}
