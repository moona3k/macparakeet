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

    public enum TranscriptTab: Hashable, Sendable {
        case transcript
        case result(id: UUID)
        case generation(id: UUID)
        case chat
    }

    public enum LLMActionState: Equatable {
        case idle
        case streaming
        case complete
        case error(String)
    }

    public var transcriptions: [Transcription] = []
    public var currentTranscription: Transcription? {
        didSet {
            refreshPromptResultStatus()
            if currentTranscription == nil {
                hasConversations = false
            }
        }
    }
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
    public var hasPromptResultTabs: Bool = false

    // LLM state
    public var llmAvailable: Bool = false
    public var selectedTab: TranscriptTab = .transcript

    public var onTranscribingChanged: ((Bool) -> Void)?

    public var isValidURL: Bool {
        YouTubeURLValidator.isYouTubeURL(urlInput)
    }

    public var hasConversations: Bool = false

    public var showTabs: Bool {
        llmAvailable
            || hasPromptResultTabs
            || hasConversations
    }
    public private(set) var isConfigured = false

    public func handlePromptResultDeleted(_ deletedID: UUID) {
        guard case .result(let selectedID) = selectedTab, selectedID == deletedID else { return }
        selectedTab = .transcript
    }

    public func handleGenerationCompleted(_ generationID: UUID, promptResultID: UUID) {
        guard case .generation(let selectedID) = selectedTab, selectedID == generationID else { return }
        selectedTab = .result(id: promptResultID)
    }

    private var transcriptionService: TranscriptionServiceProtocol?
    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    private var promptResultRepo: PromptResultRepositoryProtocol?
    private var transcriptionTask: Task<Void, Never>?
    private var activeTranscriptionTaskID: UUID?
    private var activeDropRequestID: UUID?
    private var dropPendingCount = 0
    private var dropAccepted = false
    private static let configurationError = "Transcription services are unavailable. Please try again."
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "TranscriptionViewModel")
    public var promptResultsViewModel: PromptResultsViewModel?

    public init() {}

    public func configure(
        transcriptionService: TranscriptionServiceProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        llmService: LLMServiceProtocol? = nil,
        promptResultRepo: PromptResultRepositoryProtocol? = nil,
        promptResultsViewModel: PromptResultsViewModel? = nil
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionRepo = transcriptionRepo
        self.llmAvailable = llmService != nil
        self.promptResultRepo = promptResultRepo
        self.promptResultsViewModel = promptResultsViewModel
        isConfigured = true
        errorMessage = nil
        loadTranscriptions()
    }

    public func loadTranscriptions() {
        guard let repo = transcriptionRepo else {
            reportMissingConfiguration("transcriptionRepo", action: "loadTranscriptions")
            transcriptions = []
            return
        }
        do {
            transcriptions = try repo.fetchAll(limit: 50)
        } catch {
            logger.error("Failed to load transcriptions: \(error.localizedDescription, privacy: .public)")
            transcriptions = []
        }
    }

    public func transcribeFile(url: URL, source: TelemetryTranscriptionSource = .file) {
        guard let service = transcriptionService else {
            reportMissingConfiguration("transcriptionService", action: "transcribeFile")
            return
        }
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
        guard let service = transcriptionService else {
            reportMissingConfiguration("transcriptionService", action: "transcribeURL")
            return
        }
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
        guard let service = transcriptionService else {
            reportMissingConfiguration("transcriptionService", action: "retranscribe")
            return
        }
        guard let filePath = original.filePath,
              FileManager.default.fileExists(atPath: filePath) else { return }

        let url = URL(fileURLWithPath: filePath)
        let taskID = beginNewTranscription(source: .localFile, fileName: original.fileName, clearCurrent: true)
        let retranscriptionSource: TelemetryTranscriptionSource = switch original.sourceType {
        case .file:
            .file
        case .youtube:
            .youtube
        case .meeting:
            .meeting
        }

        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let progressHandler: @Sendable (TranscriptionProgress) -> Void = { [weak self] phase in
                    Task { @MainActor [weak self] in
                        self?.updateProgress(with: phase, taskID: taskID)
                    }
                }
                let result: Transcription
                if original.sourceType == .meeting,
                   let meetingRecording = archivedMeetingRecording(for: original, mixedAudioURL: url) {
                    result = try await service.transcribeMeeting(
                        recording: meetingRecording,
                        onProgress: progressHandler
                    )
                } else {
                    result = try await service.transcribe(
                        fileURL: url,
                        source: retranscriptionSource,
                        onProgress: progressHandler
                    )
                }
                var updatedResult = result
                // Preserve row identity and user-owned metadata so retranscription updates
                // the existing record instead of deleting and recreating it.
                updatedResult.id = original.id
                updatedResult.createdAt = original.createdAt
                updatedResult.isFavorite = original.isFavorite
                updatedResult.fileName = original.fileName
                updatedResult.filePath = original.filePath
                updatedResult.sourceURL = original.sourceURL
                updatedResult.thumbnailURL = original.thumbnailURL
                updatedResult.channelName = original.channelName
                updatedResult.videoDescription = original.videoDescription
                updatedResult.sourceType = original.sourceType
                updatedResult.updatedAt = Date()
                do {
                    try transcriptionRepo?.save(updatedResult)
                    completeSuccessfulTranscription(taskID: taskID, result: updatedResult)
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

    private func archivedMeetingRecording(
        for original: Transcription,
        mixedAudioURL: URL
    ) -> MeetingRecordingOutput? {
        let durationSeconds = Double(original.durationMs ?? 0) / 1000.0
        do {
            return try MeetingRecordingOutput.loadArchived(
                displayName: original.fileName,
                mixedAudioURL: mixedAudioURL,
                durationSeconds: durationSeconds
            )
        } catch {
            logger.notice(
                "Meeting retranscribe falling back to mixed audio path file=\(original.fileName, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
            )
            return nil
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
        guard let repo = transcriptionRepo else {
            reportMissingConfiguration("transcriptionRepo", action: "deleteTranscription")
            return
        }

        do {
            let deleted = try repo.delete(id: transcription.id)
            guard deleted else { return }
            TranscriptionDeletionCleanup.removeOwnedAssets(for: transcription)
            Telemetry.send(.transcriptionDeleted)
            if currentTranscription?.id == transcription.id {
                currentTranscription = nil
            }
            loadTranscriptions()
        } catch {
            logger.error("Failed to delete transcription: \(error.localizedDescription, privacy: .public)")
        }
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

    private func reportMissingConfiguration(_ dependency: String, action: String) {
        logger.error(
            "Missing dependency action=\(action, privacy: .public) dependency=\(dependency, privacy: .public)"
        )
        if errorMessage == nil {
            errorMessage = Self.configurationError
        }
    }

    private func completeSuccessfulTranscription(taskID: UUID, result: Transcription) {
        guard activeTranscriptionTaskID == taskID else { return }
        transcriptionTask = nil
        activeTranscriptionTaskID = nil
        endTranscription()
        presentCompletedTranscription(result)
        autoSaveIfEnabled(result)
    }

    private func autoSaveIfEnabled(_ transcription: Transcription) {
        let service = AutoSaveService()
        let scope: AutoSaveScope = transcription.sourceType == .meeting ? .meeting : .transcription
        service.saveIfEnabled(transcription, scope: scope)
    }

    public func presentCompletedTranscription(_ transcription: Transcription) {
        presentCompletedTranscription(transcription, autoSave: false)
    }

    public func presentCompletedTranscription(_ transcription: Transcription, autoSave: Bool) {
        currentTranscription = transcription
        loadTranscriptions()
        if autoSave {
            autoSaveIfEnabled(transcription)
        }
        let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        promptResultsViewModel?.autoGeneratePromptResults(transcript: text, transcriptionId: transcription.id)
    }

    public func showInputPortal() {
        currentTranscription = nil
        selectedTab = .transcript
        errorMessage = nil
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

    public func loadPersistedContent() {
        if let id = currentTranscription?.id,
           let fresh = try? transcriptionRepo?.fetch(id: id) {
            currentTranscription = fresh
        }
        refreshPromptResultStatus()
    }

    public func updateConversationStatus(id: UUID, hasConversations: Bool) {
        guard currentTranscription?.id == id else { return }
        self.hasConversations = hasConversations
    }

    public func updateLegacySummary(id: UUID, summary: String?) {
        guard currentTranscription?.id == id else { return }
        currentTranscription?.summary = summary
    }

    public func updateLLMAvailability(_ available: Bool, llmService: LLMServiceProtocol? = nil) {
        self.llmAvailable = available
    }

    // MARK: - Transcript Editing

    @discardableResult
    public func updateCurrentTranscriptText(to newText: String) -> Bool {
        guard var transcription = currentTranscription else { return false }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let currentText = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        guard trimmed != currentText else { return false }

        transcription.cleanTranscript = trimmed == transcription.rawTranscript ? nil : trimmed
        transcription.updatedAt = Date()

        do {
            try transcriptionRepo?.save(transcription)
            currentTranscription = transcription
            if let index = transcriptions.firstIndex(where: { $0.id == transcription.id }) {
                transcriptions[index] = transcription
            }
            return true
        } catch {
            logger.error("Failed to persist transcript edit error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    public func revertCurrentTranscriptToOriginal() -> Bool {
        guard var transcription = currentTranscription,
              transcription.cleanTranscript != nil
        else { return false }

        transcription.cleanTranscript = nil
        transcription.updatedAt = Date()

        do {
            try transcriptionRepo?.save(transcription)
            currentTranscription = transcription
            if let index = transcriptions.firstIndex(where: { $0.id == transcription.id }) {
                transcriptions[index] = transcription
            }
            return true
        } catch {
            logger.error("Failed to persist transcript revert error=\(error.localizedDescription, privacy: .public)")
            return false
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

    public func renameCurrentTranscription(to newFileName: String) {
        guard var transcription = currentTranscription else { return }
        let trimmed = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != transcription.fileName else { return }

        transcription.fileName = trimmed
        currentTranscription = transcription
        do {
            try transcriptionRepo?.updateFileName(id: transcription.id, fileName: trimmed)
            if let index = transcriptions.firstIndex(where: { $0.id == transcription.id }) {
                transcriptions[index].fileName = trimmed
            }
        } catch {
            logger.error("Failed to persist transcription rename error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshPromptResultStatus() {
        guard let transcriptionID = currentTranscription?.id else {
            hasPromptResultTabs = false
            return
        }

        do {
            hasPromptResultTabs = try promptResultRepo?.hasPromptResults(transcriptionId: transcriptionID) ?? false
        } catch {
            logger.error("Failed to query prompt results error=\(error.localizedDescription, privacy: .public)")
            hasPromptResultTabs = false
        }
    }
}
