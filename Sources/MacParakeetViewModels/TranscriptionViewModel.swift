import Foundation
import MacParakeetCore
import OSLog
import SwiftUI

@MainActor
@Observable
public final class TranscriptionViewModel {
    public enum SourceKind: Sendable {
        case localFile
        case youtubeURL
    }

    public enum ProgressPhase: Int, CaseIterable, Sendable {
        case preparing
        case downloading
        case converting
        case transcribing
        case identifyingSpeakers
        case finalizing
    }

    public enum TranscriptTab: String, CaseIterable, Sendable {
        case transcript
        case summary
        case chat
    }

    public enum LLMActionState: Equatable {
        case idle
        case streaming
        case complete
        case error(String)
    }

    public var transcriptions: [Transcription] = []
    public var currentTranscription: Transcription?
    public var pendingDeleteTranscription: Transcription?
    public var isTranscribing = false
    public var progress: String = ""
    public var transcriptionProgress: Double?
    public private(set) var sourceKind: SourceKind = .localFile
    public private(set) var progressPhase: ProgressPhase = .preparing
    public private(set) var progressHeadline: String = "Preparing transcription pipeline"
    public private(set) var progressSubline: String? = nil
    public var errorMessage: String?
    public private(set) var transcribingFileName: String = ""
    public var isDragging = false
    public var urlInput: String = ""

    // LLM state
    public var llmAvailable: Bool = false
    public var summary: String = ""
    public var summaryState: LLMActionState = .idle
    public var selectedTab: TranscriptTab = .transcript
    public var summaryBadge: Bool = false

    // Model selection state
    public var currentModelName: String = ""
    public var currentProviderID: LLMProviderID?
    public var availableModels: [String] = []
    public var onModelChanged: (() -> Void)?
    public var onTranscribingChanged: ((Bool) -> Void)?

    public var isValidURL: Bool {
        YouTubeURLValidator.isYouTubeURL(urlInput)
    }

    public var hasConversations: Bool = false

    public var showTabs: Bool {
        llmAvailable
            || currentTranscription?.summary != nil
            || hasConversations
    }

    public var canGenerateSummary: Bool {
        llmAvailable && summaryState != .streaming
    }

    private var transcriptionService: TranscriptionServiceProtocol?
    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    private var llmService: LLMServiceProtocol?
    private var configStore: LLMConfigStoreProtocol?
    private var cliConfigStore: LocalCLIConfigStore?
    private var transcriptionTask: Task<Void, Never>?
    private var activeTranscriptionTaskID: UUID?
    private var summaryTask: Task<Void, Never>?
    private var activeDropRequestID: UUID?
    private var dropPendingCount = 0
    private var dropAccepted = false
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "TranscriptionViewModel")

    public init() {}

    public func configure(
        transcriptionService: TranscriptionServiceProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        llmService: LLMServiceProtocol? = nil,
        configStore: LLMConfigStoreProtocol? = nil,
        cliConfigStore: LocalCLIConfigStore = LocalCLIConfigStore()
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionRepo = transcriptionRepo
        self.llmService = llmService
        self.llmAvailable = llmService != nil
        self.configStore = configStore
        self.cliConfigStore = cliConfigStore
        refreshModelInfo()
        loadTranscriptions()
    }

    public func loadTranscriptions() {
        guard let repo = transcriptionRepo else { return }
        do {
            transcriptions = try repo.fetchAll(limit: 50)
        } catch {
            logger.error("Failed to load transcriptions: \(error.localizedDescription, privacy: .public)")
            transcriptions = []
        }
    }

    public func transcribeFile(url: URL, source: TelemetryTranscriptionSource = .file) {
        guard let service = transcriptionService else { return }
        let taskID = beginNewTranscription(source: .localFile, fileName: url.lastPathComponent)

        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await service.transcribe(fileURL: url, source: source) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateProgress(with: progress, taskID: taskID)
                    }
                }
                completeSuccessfulTranscription(taskID: taskID, result: result)
            } catch is CancellationError {
                completeCancelledTranscription(taskID: taskID)
            } catch {
                completeFailedTranscription(taskID: taskID, error: error)
            }
        }
    }

    public func transcribeURL() {
        guard let service = transcriptionService else { return }
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let videoID = YouTubeURLValidator.extractVideoID(url) else { return }

        // Check for existing transcription of the same video
        if let existing = try? transcriptionRepo?.fetchCompletedByVideoID(videoID) {
            currentTranscription = existing
            urlInput = ""
            return
        }

        let taskID = beginNewTranscription(source: .youtubeURL, fileName: "YouTube video")
        urlInput = ""

        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await service.transcribeURL(urlString: url) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateProgress(with: progress, taskID: taskID)
                    }
                }
                completeSuccessfulTranscription(taskID: taskID, result: result)
            } catch is CancellationError {
                completeCancelledTranscription(taskID: taskID)
            } catch {
                completeFailedTranscription(taskID: taskID, error: error)
            }
        }
    }

    public func handleFileDrop(
        providers: [NSItemProvider],
        onAccepted: (() -> Void)? = nil
    ) -> Bool {
        guard !isTranscribing else { return false }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !fileProviders.isEmpty else { return false }

        let requestID = UUID()
        activeDropRequestID = requestID
        dropPendingCount = fileProviders.count
        dropAccepted = false

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                let droppedURL: URL?
                if let data = item as? Data {
                    droppedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    droppedURL = nil
                }

                Task { @MainActor in
                    guard self.activeDropRequestID == requestID else { return }
                    defer {
                        self.dropPendingCount -= 1
                        if self.dropPendingCount == 0 {
                            if !self.dropAccepted {
                                self.errorMessage = self.unsupportedDropMessage
                            }
                            self.activeDropRequestID = nil
                        }
                    }

                    guard let droppedURL else { return }
                    let ext = droppedURL.pathExtension.lowercased()
                    guard AudioFileConverter.supportedExtensions.contains(ext) else { return }
                    guard !self.dropAccepted, !self.isTranscribing else { return }

                    self.dropAccepted = true
                    self.errorMessage = nil
                    onAccepted?()
                    self.transcribeFile(url: droppedURL, source: .dragDrop)
                }
            }
        }
        return true
    }

    private var unsupportedDropMessage: String {
        let formats = AudioFileConverter.supportedExtensions
            .sorted()
            .map { $0.uppercased() }
            .joined(separator: ", ")
        return "Unsupported file type. Supported formats: \(formats)."
    }

    public func retranscribe(_ original: Transcription) {
        guard let service = transcriptionService,
              let filePath = original.filePath,
              FileManager.default.fileExists(atPath: filePath) else { return }

        let url = URL(fileURLWithPath: filePath)
        let originalID = original.id
        let taskID = beginNewTranscription(source: .localFile, fileName: original.fileName, clearCurrent: true)

        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var result = try await service.transcribe(fileURL: url, source: .file) { [weak self] phase in
                    Task { @MainActor [weak self] in
                        self?.updateProgress(with: phase, taskID: taskID)
                    }
                }
                // Preserve original metadata
                result.fileName = original.fileName
                result.sourceURL = original.sourceURL
                do {
                    try transcriptionRepo?.save(result)
                    // Delete the original to avoid duplicates
                    _ = try? transcriptionRepo?.delete(id: originalID)
                    completeSuccessfulTranscription(taskID: taskID, result: result)
                } catch {
                    logger.error("Failed to save transcription result error=\(error.localizedDescription, privacy: .public)")
                    completeFailedTranscription(taskID: taskID, error: error)
                }
            } catch is CancellationError {
                completeCancelledTranscription(taskID: taskID)
            } catch {
                completeFailedTranscription(taskID: taskID, error: error)
            }
        }
    }

    public func cancelTranscription() {
        transcriptionTask?.cancel()
    }

    public func confirmDelete() {
        guard let transcription = pendingDeleteTranscription else { return }
        pendingDeleteTranscription = nil
        deleteTranscription(transcription)
    }

    public func deleteTranscription(_ transcription: Transcription) {
        guard let repo = transcriptionRepo else { return }

        if transcription.sourceURL != nil, let audioPath = transcription.filePath {
            do { try FileManager.default.removeItem(atPath: audioPath) }
            catch { logger.warning("Failed to remove audio: \(error.localizedDescription, privacy: .public)") }
        }
        do {
            _ = try repo.delete(id: transcription.id)
            Telemetry.send(.transcriptionDeleted)
        }
        catch { logger.error("Failed to delete transcription: \(error.localizedDescription, privacy: .public)") }
        if currentTranscription?.id == transcription.id {
            currentTranscription = nil
        }
        loadTranscriptions()
    }

    // MARK: - Progress State

    private func beginNewTranscription(
        source: SourceKind,
        fileName: String,
        clearCurrent: Bool = false
    ) -> UUID {
        transcriptionTask?.cancel()

        let taskID = UUID()
        activeTranscriptionTaskID = taskID
        transcribingFileName = fileName
        beginTranscription(source: source)

        if clearCurrent {
            currentTranscription = nil
        }

        return taskID
    }

    private func completeSuccessfulTranscription(taskID: UUID, result: Transcription) {
        guard activeTranscriptionTaskID == taskID else { return }
        transcriptionTask = nil
        activeTranscriptionTaskID = nil
        endTranscription()
        currentTranscription = result
        loadTranscriptions()
        autoSummarizeIfNeeded(result)
        autoSaveIfEnabled(result)
    }

    private func autoSaveIfEnabled(_ transcription: Transcription) {
        let service = AutoSaveService()
        service.saveIfEnabled(transcription)
    }

    private func completeFailedTranscription(taskID: UUID, error: Error) {
        guard activeTranscriptionTaskID == taskID else { return }
        transcriptionTask = nil
        activeTranscriptionTaskID = nil
        errorMessage = error.localizedDescription
        endTranscription()
        loadTranscriptions()
    }

    private func completeCancelledTranscription(taskID: UUID) {
        guard activeTranscriptionTaskID == taskID else { return }
        transcriptionTask = nil
        activeTranscriptionTaskID = nil
        errorMessage = nil
        endTranscription()
        loadTranscriptions()
    }

    private func beginTranscription(source: SourceKind) {
        sourceKind = source
        isTranscribing = true
        onTranscribingChanged?(true)
        progress = "Preparing..."
        transcriptionProgress = nil
        progressPhase = .preparing
        progressHeadline = Self.headline(for: .preparing)
        progressSubline = nil
        errorMessage = nil
        resetSummaryState()
        selectedTab = .transcript
    }

    private func endTranscription() {
        isTranscribing = false
        onTranscribingChanged?(false)
        progress = ""
        transcriptionProgress = nil
        transcribingFileName = ""
        progressPhase = .preparing
        progressHeadline = Self.headline(for: .preparing)
        progressSubline = nil
    }

    private func updateProgress(with progress: TranscriptionProgress, taskID: UUID? = nil) {
        if let taskID, activeTranscriptionTaskID != taskID {
            return
        }
        let phase = Self.mapPhase(from: progress)
        self.progress = Self.displayText(for: progress)
        self.transcriptionProgress = progress.fraction
        self.progressPhase = phase
        self.progressHeadline = Self.headline(for: phase)
        self.progressSubline = Self.subline(for: phase, sourceKind: sourceKind)
    }

    private static func mapPhase(from progress: TranscriptionProgress) -> ProgressPhase {
        switch progress {
        case .converting: return .converting
        case .downloading: return .downloading
        case .transcribing: return .transcribing
        case .identifyingSpeakers: return .identifyingSpeakers
        case .finalizing: return .finalizing
        }
    }

    private static func displayText(for progress: TranscriptionProgress) -> String {
        switch progress {
        case .converting:
            return "Converting audio..."
        case .downloading(let percent):
            return "Downloading audio... \(percent)%"
        case .transcribing(let percent):
            return "Transcribing... \(percent)%"
        case .identifyingSpeakers:
            return "Identifying speakers..."
        case .finalizing:
            return "Finalizing..."
        }
    }

    private static func headline(for phase: ProgressPhase) -> String {
        switch phase {
        case .preparing:
            return "Preparing transcription pipeline"
        case .downloading:
            return "Fetching source audio"
        case .converting:
            return "Normalizing audio stream"
        case .transcribing:
            return "Running speech recognition"
        case .identifyingSpeakers:
            return "Identifying speakers"
        case .finalizing:
            return "Finalizing transcript"
        }
    }

    private static func subline(for phase: ProgressPhase, sourceKind: SourceKind) -> String? {
        switch phase {
        case .downloading:
            return sourceKind == .youtubeURL
                ? "Longer videos take more time to fetch"
                : nil
        case .transcribing:
            return "Runs entirely on-device using the Neural Engine"
        case .identifyingSpeakers:
            return "May take several minutes per hour of audio. Speaker labels are approximate \u{2014} click to rename."
        default:
            return nil
        }
    }

    // MARK: - LLM Summary

    private func autoSummarizeIfNeeded(_ transcription: Transcription) {
        let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        guard llmAvailable, text.count > 500 else { return }
        generateSummary(text: text)
    }

    public func generateSummary(text: String) {
        guard let llmService, summaryState != .streaming else { return }
        summary = ""
        summaryState = .streaming
        summaryBadge = false

        // Capture ID before async work — currentTranscription may change mid-stream
        let targetID = currentTranscription?.id

        summaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let stream = llmService.summarizeStream(transcript: text)
                for try await token in stream {
                    summary += token
                }
                guard !Task.isCancelled else { return }
                // Discard if user navigated to a different transcription mid-stream
                guard currentTranscription?.id == targetID else { return }
                summaryState = .complete
                if let targetID {
                    currentTranscription?.summary = summary
                    do {
                        try transcriptionRepo?.updateSummary(id: targetID, summary: summary)
                    } catch {
                        logger.error("Failed to persist summary error=\(error.localizedDescription, privacy: .public)")
                    }
                }
                if selectedTab != .summary {
                    summaryBadge = true
                }
            } catch is CancellationError {
                // Cancellation is expected (navigation, config change) — handled by cancelSummary()
            } catch {
                guard currentTranscription?.id == targetID else { return }
                summaryState = .error(error.localizedDescription)
            }
        }
    }

    public func cancelSummary() {
        summaryTask?.cancel()
        summaryTask = nil
        if summaryState == .streaming {
            summaryState = summary.isEmpty ? .idle : .complete
        }
    }

    /// Clears in-memory summary state without touching the database.
    /// Used when switching between transcriptions to avoid destroying saved summaries.
    public func resetSummaryState() {
        cancelSummary()
        summary = ""
        summaryState = .idle
        summaryBadge = false
    }

    /// Clears the summary and persists the removal to the database.
    /// Used when the user explicitly dismisses a summary.
    public func dismissSummary() {
        cancelSummary()
        summary = ""
        summaryState = .idle
        summaryBadge = false
        if let id = currentTranscription?.id {
            currentTranscription?.summary = nil
            do {
                try transcriptionRepo?.updateSummary(id: id, summary: nil)
            } catch {
                logger.error("Failed to clear summary error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func loadPersistedContent() {
        // Refresh from DB to pick up persisted summary/chat that may not be
        // reflected in the stale list copy of the transcription.
        if let id = currentTranscription?.id,
           let fresh = try? transcriptionRepo?.fetch(id: id) {
            currentTranscription = fresh
        }
        if let saved = currentTranscription?.summary, !saved.isEmpty {
            summary = saved
            summaryState = .complete
        }
    }

    public func updateConversationStatus(id: UUID, hasConversations: Bool) {
        guard currentTranscription?.id == id else { return }
        self.hasConversations = hasConversations
    }

    public func updateLLMAvailability(_ available: Bool, llmService: LLMServiceProtocol? = nil) {
        self.llmAvailable = available
        self.llmService = llmService
        refreshModelInfo()
    }

    public var modelDisplayName: String {
        guard !currentModelName.isEmpty else { return "" }
        if currentProviderID == .openrouter, let slashIndex = currentModelName.firstIndex(of: "/") {
            return String(currentModelName[currentModelName.index(after: slashIndex)...])
        }
        return currentModelName
    }

    public func refreshModelInfo() {
        guard let configStore, let config = try? configStore.loadConfig() else {
            currentModelName = ""
            currentProviderID = nil
            availableModels = []
            return
        }
        currentProviderID = config.id
        if config.id == .localCLI {
            let displayName = cliConfigStore
                .flatMap { $0.load() }
                .map { LocalCLITemplate.displayName(for: $0.commandTemplate) }
                ?? "Custom CLI"
            currentModelName = displayName
            availableModels = [displayName]
            return
        }

        currentModelName = config.modelName
        var models = LLMSettingsViewModel.suggestedModels(for: config.id)
        if !config.modelName.isEmpty && !models.contains(config.modelName) {
            models.insert(config.modelName, at: 0)
        }
        availableModels = models
    }

    public func selectModel(_ modelName: String) {
        guard let configStore, currentProviderID != .localCLI else { return }
        do {
            try configStore.updateModelName(modelName)
            currentModelName = modelName
            onModelChanged?()
        } catch {
            refreshModelInfo()
        }
    }

    // MARK: - Speaker Rename

    public func renameSpeaker(id speakerId: String, to newLabel: String) {
        guard var transcription = currentTranscription,
              var speakers = transcription.speakers else { return }
        guard let index = speakers.firstIndex(where: { $0.id == speakerId }) else { return }
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, speakers[index].label != trimmed else { return }
        speakers[index].label = trimmed
        transcription.speakers = speakers
        currentTranscription = transcription
        do {
            try transcriptionRepo?.updateSpeakers(id: transcription.id, speakers: speakers)
        } catch {
            logger.error("Failed to persist speaker rename error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
