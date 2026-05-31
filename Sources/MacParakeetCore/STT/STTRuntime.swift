import FluidAudio
import Foundation
import os

protocol STTRuntimeProtocol: Sendable {
    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult
    func transcribe(
        audioPath: String,
        job: STTJobKind,
        speechEngine: SpeechEngineSelection,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult
    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws
    func backgroundWarmUp() async
    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>)
    func removeWarmUpObserver(id: UUID) async
    func isReady() async -> Bool
    func shutdown() async
    func clearModelCache() async
    func setSpeechEngine(_ preference: SpeechEnginePreference) async throws
    func setSpeechEngine(
        _ preference: SpeechEnginePreference,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws
    func setParakeetModelVariant(
        _ variant: ParakeetModelVariant,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws
    func currentSpeechEngineSelection() async -> SpeechEngineSelection
}

extension STTRuntimeProtocol {
    func setSpeechEngine(
        _ preference: SpeechEnginePreference,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        onProgress?("Preparing \(preference.displayName)...")
        try await setSpeechEngine(preference)
    }
}

/// Sole owner of the shared Parakeet STT lifecycle.
///
/// The runtime stays process-wide and singular at the app boundary, but it keeps
/// one `AsrManager` per execution slot so dictation remains isolated from the
/// shared background workload inside app-level scheduling.
public actor STTRuntime: STTRuntimeProtocol {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "STTRuntime")

    private var interactiveManager: AsrManager?
    private var backgroundManager: AsrManager?
    private var models: AsrModels?
    private var decoderLayerCount: Int?
    private var initializationTask: Task<Void, Error>?
    private var initializationGeneration: UInt64 = 0
    private var warmUpProgressHandler: (@Sendable (String) -> Void)?
    /// The active Parakeet build. Mutable because the user can switch between
    /// the multilingual `v3` and English-only `v2` variants at runtime
    /// (`setParakeetModelVariant`); `ensureInitialized()` reads it when loading.
    private var modelVersion: AsrModelVersion
    private var speechEngine: SpeechEnginePreference
    private var whisperEngine: WhisperEngine?
    private let whisperModelVariant: String
    private var activeTranscriptionCount = 0

    private var backgroundWarmUpState: STTWarmUpState = .idle
    private var backgroundWarmUpTask: Task<Void, Never>?
    private var warmUpObservers: [UUID: AsyncStream<STTWarmUpState>.Continuation] = [:]
    private var backgroundWarmUpGeneration: UInt64 = 0

    public init(
        modelVersion: AsrModelVersion = .v3,
        speechEngine: SpeechEnginePreference = .parakeet,
        whisperModelVariant: String = SpeechEnginePreference.defaultWhisperModelVariant
    ) {
        self.modelVersion = modelVersion
        self.speechEngine = speechEngine
        self.whisperModelVariant = WhisperEngine.normalizeModelVariant(whisperModelVariant)
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        try await transcribe(
            audioPath: audioPath,
            job: job,
            speechEngine: SpeechEngineSelection(
                engine: speechEngine,
                language: speechEngine == .whisper ? SpeechEnginePreference.whisperDefaultLanguage() : nil
            ),
            onProgress: onProgress
        )
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        speechEngine selection: SpeechEngineSelection,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        activeTranscriptionCount += 1
        defer { activeTranscriptionCount -= 1 }

        switch selection.engine {
        case .parakeet:
            return try await transcribeWithParakeet(audioPath: audioPath, job: job, onProgress: onProgress)
        case .whisper:
            return try await transcribeWithWhisper(audioPath: audioPath, language: selection.language, onProgress: onProgress)
        }
    }

    private func transcribeWithWhisper(
        audioPath: String,
        language: String?,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        let engine = whisperEngine ?? WhisperEngine(model: whisperModelVariant)
        whisperEngine = engine
        return try await engine.transcribe(
            audioURL: URL(fileURLWithPath: audioPath),
            language: language,
            onProgress: onProgress
        )
    }

    private func transcribeWithParakeet(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        try await ensureInitialized()

        let slot = route(for: job)
        guard let manager = manager(for: slot) else {
            throw STTError.modelNotLoaded
        }
        guard let decoderLayers = decoderLayerCount else {
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
            var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
            try Task.checkCancellation()
            let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
            let words = Self.mergeTokenTimingsIntoWords(result.tokenTimings)
            onProgress?(100, 100)
            // Telemetry `language` is attributed "en": MacParakeet positions
            // Parakeet as English-first (v2 is English-only; v3 multilingual is
            // not surfaced via a Parakeet language picker), so this reflects the
            // app's configuration rather than per-segment detection. The
            // `engineVariant` carries the active build (v2/v3) so adoption and
            // impact can be measured without exposing transcript content.
            return STTResult(
                text: result.text,
                words: words,
                language: "en",
                engine: .parakeet,
                engineVariant: ParakeetModelVariant(asrModelVersion: modelVersion).rawValue
            )
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
        let operationContext = Observability.childOperationContext()
        let activeSpeechEngine = speechEngine
        let modelKind = telemetryModelKind(for: activeSpeechEngine)
        let engineVariant = telemetryEngineVariant(for: activeSpeechEngine)
        do {
            switch activeSpeechEngine {
            case .parakeet:
                try await ensureInitialized()
            case .whisper:
                let engine = whisperEngine ?? WhisperEngine(model: whisperModelVariant)
                whisperEngine = engine
                try await engine.prepare(onProgress: onProgress)
            }
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            Telemetry.send(.modelLoaded(
                loadTimeSeconds: seconds,
                modelKind: modelKind,
                speechEngine: activeSpeechEngine,
                engineVariant: engineVariant
            ))
            Telemetry.send(.modelOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                action: .warmUp,
                outcome: .success,
                stage: .warmUp,
                modelKind: modelKind,
                speechEngine: activeSpeechEngine,
                engineVariant: engineVariant,
                durationSeconds: seconds,
                errorType: nil
            ))
            onProgress?("Ready")
        } catch is CancellationError {
            let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
            Telemetry.send(.modelOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                action: .warmUp,
                outcome: .cancelled,
                stage: .warmUp,
                modelKind: modelKind,
                speechEngine: activeSpeechEngine,
                engineVariant: engineVariant,
                durationSeconds: durationSeconds,
                errorType: "CancellationError"
            ))
            throw CancellationError()
        } catch {
            let mapped = try Self.mapWarmUpError(error)
            Telemetry.send(.modelOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                action: .warmUp,
                outcome: .failure,
                stage: .warmUp,
                modelKind: modelKind,
                speechEngine: activeSpeechEngine,
                engineVariant: engineVariant,
                durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                errorType: TelemetryErrorClassifier.classify(mapped)
            ))
            throw mapped
        }
    }

    public func backgroundWarmUp() async {
        if case .ready = backgroundWarmUpState { return }
        if backgroundWarmUpTask != nil { return }

        // Order matters: `beginBackgroundWarmUp()` advances the generation
        // counter *before* the task is assigned to `backgroundWarmUpTask`.
        // This is safe because both the generation check and the nil-task
        // guard at the top run synchronously on this actor — no suspension
        // point exists between them and the assignment below, so no
        // concurrent caller can observe the intermediate state.
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
        if speechEngine == .whisper {
            return await whisperEngine?.isReady() ?? false
        }

        guard let interactiveManager, let backgroundManager else { return false }
        let interactiveReady = await interactiveManager.isAvailable
        let backgroundReady = await backgroundManager.isAvailable
        return interactiveReady && backgroundReady
    }

    public func shutdown() async {
        invalidateBackgroundWarmUp()
        await unloadWhisper()
        await unloadParakeet()
        warmUpProgressHandler = nil
        setBackgroundWarmUpState(.idle)
    }

    public func clearModelCache() async {
        let operationContext = Observability.childOperationContext()
        let activeSpeechEngine = speechEngine
        let engineVariant = telemetryEngineVariant(for: activeSpeechEngine)
        await shutdown()
        DownloadUtils.clearAllModelCaches()
        try? FileManager.default.removeItem(atPath: AppPaths.whisperModelsDir)
        setBackgroundWarmUpState(.idle)
        Telemetry.send(.modelOperation(
            operationID: operationContext.operationID,
            operationContext: operationContext,
            action: .clearCache,
            outcome: .success,
            stage: .clearCache,
            modelKind: .localSpeechStack,
            speechEngine: activeSpeechEngine,
            engineVariant: engineVariant,
            durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
            errorType: nil
        ))
    }

    public func setSpeechEngine(_ preference: SpeechEnginePreference) async throws {
        try await setSpeechEngine(preference, onProgress: nil)
    }

    public func setSpeechEngine(
        _ preference: SpeechEnginePreference,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        guard preference != speechEngine else {
            preference.save()
            return
        }

        guard initializationTask == nil, activeTranscriptionCount == 0 else {
            throw STTError.engineBusy
        }

        invalidateBackgroundWarmUp()
        setBackgroundWarmUpState(.idle)

        let previous = speechEngine
        let startedAt = Date()
        let targetVariant = telemetryEngineVariant(for: preference) ?? "none"
        logger.notice("speech_engine_switch_start from=\(previous.rawValue, privacy: .public) to=\(preference.rawValue, privacy: .public) variant=\(targetVariant, privacy: .public)")
        AudioCaptureDiagnostics.append(
            "speech_engine_switch_start from=\(previous.rawValue) to=\(preference.rawValue) variant=\(targetVariant)"
        )

        do {
            try await performSpeechEngineSwitch(
                from: previous,
                to: preference,
                onProgress: onProgress
            )
            let duration = Observability.durationSeconds(since: startedAt)
            logger.notice("speech_engine_switch_complete from=\(previous.rawValue, privacy: .public) to=\(preference.rawValue, privacy: .public) duration_s=\(duration, privacy: .public)")
            AudioCaptureDiagnostics.append(
                "speech_engine_switch_complete from=\(previous.rawValue) to=\(preference.rawValue) duration_s=\(Self.formatSeconds(duration))"
            )
        } catch {
            let duration = Observability.durationSeconds(since: startedAt)
            logger.error("speech_engine_switch_failed from=\(previous.rawValue, privacy: .public) to=\(preference.rawValue, privacy: .public) duration_s=\(duration, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
            AudioCaptureDiagnostics.append(
                "speech_engine_switch_failed from=\(previous.rawValue) to=\(preference.rawValue) duration_s=\(Self.formatSeconds(duration)) \(AudioCaptureDiagnostics.errorFields(error))"
            )
            throw error
        }
    }

    private func performSpeechEngineSwitch(
        from previous: SpeechEnginePreference,
        to preference: SpeechEnginePreference,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        var preparedWhisper: WhisperEngine?

        switch preference {
        case .parakeet:
            onProgress?("Loading Parakeet model on Neural Engine...")
            try await ensureInitialized()
        case .whisper:
            let engine = whisperEngine ?? WhisperEngine(
                model: whisperModelVariant,
                language: SpeechEnginePreference.whisperDefaultLanguage()
            )
            try await engine.prepare(onProgress: onProgress)
            preparedWhisper = engine
        }

        if let preparedWhisper {
            whisperEngine = preparedWhisper
        }
        speechEngine = preference
        preference.save()

        switch previous {
        case .parakeet where preference != .parakeet:
            onProgress?("Releasing Parakeet model...")
            await unloadParakeet()
        case .whisper where preference != .whisper:
            onProgress?("Releasing Whisper model...")
            await unloadWhisper()
        default:
            break
        }
        onProgress?("\(preference.displayName) is ready")
    }

    /// Switches the active Parakeet build between the multilingual `v3` and the
    /// English-only `v2` variant. Symmetric to ``setSpeechEngine(_:onProgress:)``:
    /// it downloads the target first (so the current model keeps serving until
    /// the slow fetch finishes), then swaps the loaded managers in place. When
    /// the target is already cached the download is a cheap no-op, so flipping
    /// between two installed variants is near-instant.
    ///
    /// If Parakeet isn't the active engine there is nothing loaded to swap, so
    /// the new version is simply recorded and takes effect the next time
    /// Parakeet loads.
    public func setParakeetModelVariant(
        _ variant: ParakeetModelVariant,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        let targetVersion = variant.asrModelVersion
        guard targetVersion != modelVersion else { return }

        guard initializationTask == nil, activeTranscriptionCount == 0 else {
            throw STTError.engineBusy
        }

        let previousVersion = modelVersion
        let startedAt = Date()
        logger.notice("parakeet_variant_switch_start to=\(variant.rawValue, privacy: .public) engine=\(self.speechEngine.rawValue, privacy: .public)")
        AudioCaptureDiagnostics.append(
            "parakeet_variant_switch_start to=\(variant.rawValue) engine=\(self.speechEngine.rawValue)"
        )

        guard speechEngine == .parakeet else {
            // Inactive engine: record the choice; it loads on the next Parakeet use.
            modelVersion = targetVersion
            logger.notice("parakeet_variant_switch_deferred to=\(variant.rawValue, privacy: .public) reason=engine_inactive")
            AudioCaptureDiagnostics.append("parakeet_variant_switch_deferred to=\(variant.rawValue) reason=engine_inactive")
            return
        }

        invalidateBackgroundWarmUp()
        setBackgroundWarmUpState(.idle)

        do {
            onProgress?("Preparing \(variant.modelName)...")
            try await downloadParakeetModels(version: targetVersion, onProgress: onProgress)

            onProgress?("Loading \(variant.modelName) on Neural Engine...")
            await unloadParakeet()
            modelVersion = targetVersion
            try await ensureInitialized()

            onProgress?("\(variant.modelName) is ready")
            let duration = Observability.durationSeconds(since: startedAt)
            logger.notice("parakeet_variant_switch_complete to=\(variant.rawValue, privacy: .public) duration_s=\(duration, privacy: .public)")
            AudioCaptureDiagnostics.append(
                "parakeet_variant_switch_complete to=\(variant.rawValue) duration_s=\(Self.formatSeconds(duration))"
            )
        } catch {
            let switchError = error
            // Restore the previous version so the in-memory runtime matches the
            // persisted preference; callers only save the new selection on
            // success.
            modelVersion = previousVersion
            do {
                try await ensureInitialized()
            } catch {
                logger.error("parakeet_variant_restore_failed version=\(String(describing: previousVersion), privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
                AudioCaptureDiagnostics.append(
                    "parakeet_variant_restore_failed version=\(previousVersion) \(AudioCaptureDiagnostics.errorFields(error))"
                )
            }
            let duration = Observability.durationSeconds(since: startedAt)
            logger.error("parakeet_variant_switch_failed to=\(variant.rawValue, privacy: .public) duration_s=\(duration, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(switchError), privacy: .public) error_detail=\(switchError.localizedDescription, privacy: .private)")
            AudioCaptureDiagnostics.append(
                "parakeet_variant_switch_failed to=\(variant.rawValue) duration_s=\(Self.formatSeconds(duration)) \(AudioCaptureDiagnostics.errorFields(switchError))"
            )
            throw switchError
        }
    }

    /// Pre-fetches a Parakeet build to disk without loading it, reusing the
    /// throttled progress→message bridge. Returns immediately when the model is
    /// already cached (`AsrModels.download` validates and no-ops).
    private func downloadParakeetModels(
        version: AsrModelVersion,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        try await Self.downloadParakeetModel(version: version, onProgress: onProgress)
    }

    /// Downloads a Parakeet build to its version-specific cache without loading
    /// it (no runtime spin-up). Cached builds are a cheap validate-and-return.
    /// Exposed for the CLI's `models download parakeet-v2|v3` path so a build can
    /// be pre-fetched headlessly without selecting it.
    public nonisolated static func downloadParakeetModel(
        version: AsrModelVersion,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let progressHandler = makeDownloadProgressHandler(onProgress)
        _ = try await AsrModels.download(version: version, progressHandler: progressHandler)
    }

    public func currentSpeechEngineSelection() async -> SpeechEngineSelection {
        SpeechEngineSelection(
            engine: speechEngine,
            language: speechEngine == .whisper ? SpeechEnginePreference.whisperDefaultLanguage() : nil
        )
    }

    public nonisolated static func isModelCached(version: AsrModelVersion = .v3) -> Bool {
        let cacheDir = AsrModels.defaultCacheDirectory(for: version)
        return AsrModels.modelsExist(at: cacheDir, version: version)
    }

    private func unloadParakeet() async {
        let inFlightInitialization = cancelInitialization()
        inFlightInitialization?.cancel()
        _ = try? await inFlightInitialization?.value

        let interactiveManager = self.interactiveManager
        let backgroundManager = self.backgroundManager
        self.interactiveManager = nil
        self.backgroundManager = nil
        self.models = nil
        self.decoderLayerCount = nil
        await Self.cleanupManagers(
            interactiveManager: interactiveManager,
            backgroundManager: backgroundManager
        )
    }

    private func unloadWhisper() async {
        let engine = whisperEngine
        whisperEngine = nil
        await engine?.unload()
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
            var interactiveManager: AsrManager?
            var backgroundManager: AsrManager?
            let progressHandler = Self.makeDownloadProgressHandler(warmUpProgressHandler)

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
                let loadedDecoderLayerCount = await loadedInteractiveManager.decoderLayerCount
                try Task.checkCancellation()
                try await self.completeInitialization(
                    generation: generation,
                    models: downloadedModels,
                    decoderLayerCount: loadedDecoderLayerCount,
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
        decoderLayerCount: Int,
        interactiveManager: AsrManager,
        backgroundManager: AsrManager
    ) async throws {
        guard initializationGeneration == generation else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        self.models = models
        self.decoderLayerCount = decoderLayerCount
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

    private nonisolated static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3f", value)
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

    private func telemetryModelKind(for engine: SpeechEnginePreference) -> TelemetryModelKind {
        switch engine {
        case .parakeet:
            .parakeetSTT
        case .whisper:
            .whisperSTT
        }
    }

    private func telemetryEngineVariant(for engine: SpeechEnginePreference) -> String? {
        switch engine {
        case .parakeet:
            // Surface the active Parakeet build (v2/v3) so model-load telemetry
            // can measure variant adoption and impact (issues #311, #398).
            ParakeetModelVariant(asrModelVersion: modelVersion).rawValue
        case .whisper:
            whisperModelVariant
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

    /// Builds a download progress handler that throttles to ≤1 update / 250 ms
    /// and suppresses repeated identical messages, translating raw
    /// `DownloadProgress` into a user-facing string. Shared by initial warm-up
    /// loading and the Parakeet variant pre-download so both report identically.
    private nonisolated static func makeDownloadProgressHandler(
        _ onProgress: (@Sendable (String) -> Void)?
    ) -> DownloadUtils.ProgressHandler? {
        guard let onProgress else { return nil }
        let clock = ContinuousClock()
        let lastProgressUpdate = OSAllocatedUnfairLock(initialState: clock.now - .seconds(1))
        let lastProgressMessage = OSAllocatedUnfairLock(initialState: "")
        return { progress in
            guard let message = Self.warmUpProgressMessage(from: progress) else { return }
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
