import FluidAudio
import Foundation
import os

public actor NemotronEngine: STTTranscribing {
    public static let defaultModelVariant = SpeechEnginePreference.defaultNemotronModelVariant

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "NemotronEngine")

    private let modelVariant: NemotronModelVariant
    private let defaultLanguage: String?

    private var sharedModels: SharedNemotronMultilingualModels?
    private var interactiveManager: StreamingNemotronMultilingualAsrManager?
    private var backgroundManager: StreamingNemotronMultilingualAsrManager?
    private var initializationTask: Task<Void, Error>?
    private var activeLanes: Set<NemotronRuntimeLane> = []
    private var liveDictationLanguage: String?

    public init(
        modelVariant: NemotronModelVariant = NemotronEngine.defaultModelVariant,
        language: String? = nil
    ) {
        self.modelVariant = modelVariant
        self.defaultLanguage = SpeechEnginePreference.normalizeNemotronLanguage(language)
    }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        try await transcribe(
            audioURL: URL(fileURLWithPath: audioPath),
            job: job,
            language: defaultLanguage,
            onProgress: onProgress
        )
    }

    public func transcribe(
        audioURL: URL,
        job: STTJobKind,
        language: String?,
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
            let requestedLanguage = SpeechEnginePreference.normalizeNemotronLanguage(language)
            await manager.configureForMacParakeet(language: requestedLanguage)

            onProgress?(0, 100)
            try Task.checkCancellation()
            let samples = try await Task.detached(priority: .userInitiated) {
                try AudioConverter().resampleAudioFile(audioURL)
            }.value
            onProgress?(25, 100)
            try Task.checkCancellation()
            _ = try await manager.process(samples: samples)
            onProgress?(90, 100)
            let text = try await manager.finish()
            let detectedLanguage = await manager.detectedLanguage()
            onProgress?(100, 100)

            return STTResult(
                text: text,
                words: [],
                language: detectedLanguage ?? requestedLanguage,
                engine: .nemotron,
                engineVariant: modelVariant.rawValue
            )
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
    }

    public func beginLiveDictation(
        language: String?,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws {
        let lane: NemotronRuntimeLane = .interactive
        guard beginTranscription(on: lane) else {
            throw STTError.engineBusy
        }

        do {
            try await prepare(onProgress: nil)
            guard let manager = manager(for: lane) else {
                throw STTError.modelNotLoaded
            }
            let requestedLanguage = SpeechEnginePreference.normalizeNemotronLanguage(language)
            await manager.configureForMacParakeet(language: requestedLanguage)
            await manager.setPartialCallback { partial in
                onPartial(partial)
            }
            liveDictationLanguage = requestedLanguage
        } catch {
            endTranscription(on: lane)
            throw try Self.mapTranscriptionError(error)
        }
    }

    public func processLiveDictationSamples(_ samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        guard let manager = manager(for: .interactive),
              activeLanes.contains(.interactive) else {
            throw STTLiveDictationTranscriptionError.sessionNotActive
        }
        do {
            try Task.checkCancellation()
            _ = try await manager.process(samples: samples)
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
    }

    public func finishLiveDictation() async throws -> STTResult {
        let lane: NemotronRuntimeLane = .interactive
        guard let manager = manager(for: lane),
              activeLanes.contains(lane) else {
            throw STTLiveDictationTranscriptionError.sessionNotActive
        }
        let requestedLanguage = liveDictationLanguage
        defer {
            liveDictationLanguage = nil
            endTranscription(on: lane)
        }

        do {
            await manager.setPartialCallback { _ in }
            let text = try await manager.finish()
            let detectedLanguage = await manager.detectedLanguage()
            return STTResult(
                text: text,
                words: [],
                language: detectedLanguage ?? requestedLanguage,
                engine: .nemotron,
                engineVariant: modelVariant.rawValue
            )
        } catch {
            throw try Self.mapTranscriptionError(error)
        }
    }

    public func cancelLiveDictation() async {
        let lane: NemotronRuntimeLane = .interactive
        guard activeLanes.contains(lane) else { return }
        // Release the lane even if unload() already dropped the manager —
        // otherwise a cancel that races shutdown would leave the interactive
        // lane claimed forever on this engine instance.
        if let manager = manager(for: lane) {
            await manager.setPartialCallback { _ in }
            await manager.reset()
        }
        liveDictationLanguage = nil
        endTranscription(on: lane)
    }

    public func prepare(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        if isLoaded { return }

        if let initializationTask {
            try await initializationTask.value
            return
        }

        let task = Task {
            try await loadSharedModels(onProgress: onProgress)
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
        self.sharedModels = nil

        await interactiveManager?.cleanup()
        await backgroundManager?.cleanup()
    }

    public func isReady() -> Bool {
        isLoaded
    }

    public nonisolated static func defaultCacheRoot() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
    }

    public nonisolated static func defaultVariantDirectory(
        modelVariant: NemotronModelVariant = defaultModelVariant,
        language: String? = nil
    ) -> URL {
        let languageCode = SpeechEnginePreference.normalizeNemotronLanguage(language) ?? "auto"
        let languageDirectory = StreamingNemotronMultilingualAsrManager.languageDirectory(for: languageCode)
        return defaultCacheRoot()
            .appendingPathComponent(languageDirectory, isDirectory: true)
            .appendingPathComponent("\(modelVariant.chunkMilliseconds)ms", isDirectory: true)
    }

    public nonisolated static func isModelCached(
        modelVariant: NemotronModelVariant = defaultModelVariant,
        language: String? = nil
    ) -> Bool {
        let metadata = defaultVariantDirectory(modelVariant: modelVariant, language: language)
            .appendingPathComponent(ModelNames.NemotronMultilingualStreaming.metadata)
        return FileManager.default.fileExists(atPath: metadata.path)
    }

    @discardableResult
    public nonisolated static func deleteModel(
        modelVariant: NemotronModelVariant = defaultModelVariant,
        language: String? = nil
    ) -> Bool {
        deleteModel(
            modelVariant: modelVariant,
            language: language,
            cacheRoot: defaultCacheRoot()
        )
    }

    @discardableResult
    nonisolated static func deleteModel(
        modelVariant: NemotronModelVariant = defaultModelVariant,
        language: String? = nil,
        cacheRoot: URL
    ) -> Bool {
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedLanguage,
              !trimmedLanguage.isEmpty,
              trimmedLanguage.lowercased() != "auto" else {
            return deleteModelCaches(modelVariant: modelVariant, cacheRoot: cacheRoot)
        }
        guard let language = SpeechEnginePreference.normalizeNemotronLanguage(trimmedLanguage) else {
            return false
        }

        return deleteModelCache(
            modelVariant: modelVariant,
            language: language,
            cacheRoot: cacheRoot
        )
    }

    @discardableResult
    nonisolated static func deleteModelCaches(
        modelVariant: NemotronModelVariant = defaultModelVariant,
        cacheRoot: URL = defaultCacheRoot()
    ) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheRoot.path) else { return false }

        let languageDirectories = (try? fileManager.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var removedAny = false
        var removalFailed = false
        for languageDirectory in languageDirectories {
            let variantDirectory = languageDirectory
                .appendingPathComponent("\(modelVariant.chunkMilliseconds)ms", isDirectory: true)
            guard fileManager.fileExists(atPath: variantDirectory.path) else { continue }
            do {
                try fileManager.removeItem(at: variantDirectory)
                removedAny = true
            } catch {
                removalFailed = true
                continue
            }
            removeIfEmpty(languageDirectory, fileManager: fileManager)
        }

        removeIfEmpty(cacheRoot, fileManager: fileManager)
        return removedAny && !removalFailed
    }

    private nonisolated static func deleteModelCache(
        modelVariant: NemotronModelVariant,
        language: String,
        cacheRoot: URL
    ) -> Bool {
        let languageDirectory = StreamingNemotronMultilingualAsrManager.languageDirectory(for: language)
        let fileManager = FileManager.default
        let targetDirectory = cacheRoot
            .appendingPathComponent(languageDirectory, isDirectory: true)
            .appendingPathComponent("\(modelVariant.chunkMilliseconds)ms", isDirectory: true)
        guard fileManager.fileExists(atPath: targetDirectory.path) else { return false }
        do {
            try fileManager.removeItem(at: targetDirectory)
        } catch {
            return false
        }
        removeIfEmpty(targetDirectory.deletingLastPathComponent(), fileManager: fileManager)
        removeIfEmpty(cacheRoot, fileManager: fileManager)
        return !fileManager.fileExists(atPath: targetDirectory.path)
    }

    private nonisolated static func removeIfEmpty(_ directory: URL, fileManager: FileManager) {
        guard let children = try? fileManager.contentsOfDirectory(atPath: directory.path),
              children.isEmpty else {
            return
        }
        try? fileManager.removeItem(at: directory)
    }

    public nonisolated static func downloadModel(
        modelVariant: NemotronModelVariant = defaultModelVariant,
        language: String? = nil,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        let progressHandler = makeDownloadProgressHandler(onProgress)
        return try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: SpeechEnginePreference.normalizeNemotronLanguage(language) ?? "auto",
            chunkMs: modelVariant.chunkMilliseconds,
            progressHandler: progressHandler
        )
    }

    private var isLoaded: Bool {
        sharedModels != nil && interactiveManager != nil && backgroundManager != nil
    }

    private func loadSharedModels(onProgress: (@Sendable (String) -> Void)?) async throws {
        let languageCode = defaultLanguage ?? "auto"
        let progressHandler = Self.makeDownloadProgressHandler(onProgress)
        onProgress?("Preparing Nemotron model download...")
        let shared = try await StreamingNemotronMultilingualAsrManager.downloadAndPreloadShared(
            languageCode: languageCode,
            chunkMs: modelVariant.chunkMilliseconds,
            progressHandler: progressHandler
        )

        let loadedInteractiveManager = StreamingNemotronMultilingualAsrManager()
        let loadedBackgroundManager = StreamingNemotronMultilingualAsrManager()
        try await loadedInteractiveManager.loadFromShared(shared)
        try await loadedBackgroundManager.loadFromShared(shared)
        await loadedInteractiveManager.configureForMacParakeet(language: defaultLanguage)
        await loadedBackgroundManager.configureForMacParakeet(language: defaultLanguage)

        self.sharedModels = shared
        self.interactiveManager = loadedInteractiveManager
        self.backgroundManager = loadedBackgroundManager
        logger.notice("nemotron_model_prepare_complete variant=\(self.modelVariant.rawValue, privacy: .public)")
        AudioCaptureDiagnostics.append("nemotron_model_prepare_complete variant=\(self.modelVariant.rawValue)")
        onProgress?("Ready")
    }

    private func manager(for lane: NemotronRuntimeLane) -> StreamingNemotronMultilingualAsrManager? {
        switch lane {
        case .interactive:
            interactiveManager
        case .background:
            backgroundManager
        }
    }

    private func route(for job: STTJobKind) -> NemotronRuntimeLane {
        switch job {
        case .dictation:
            .interactive
        case .meetingFinalize, .meetingLiveChunk, .fileTranscription:
            .background
        }
    }

    private func beginTranscription(on lane: NemotronRuntimeLane) -> Bool {
        guard !activeLanes.contains(lane) else { return false }
        activeLanes.insert(lane)
        return true
    }

    private func endTranscription(on lane: NemotronRuntimeLane) {
        activeLanes.remove(lane)
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

private enum NemotronRuntimeLane: Hashable, Sendable {
    case interactive
    case background
}

private extension StreamingNemotronMultilingualAsrManager {
    func configureForMacParakeet(language: String?) async {
        await reset()
        await setLanguage(language)
        appendTerminalPunctuation = true
    }
}
