import Foundation
import MacParakeetCore
import OSLog
import SwiftUI

@MainActor
@Observable
public final class TranscriptionViewModel {
    public struct RetranscriptionEngineOption: Equatable, Sendable {
        public let primaryEngine: SpeechEngineSelection
        public let alternativeEngine: SpeechEngineSelection
        public let isAlternativeAvailable: Bool
        public let unavailableReason: String?

        public var title: String {
            "Try with \(alternativeEngine.engine.displayName)"
        }
    }

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
            let transcriptionChanged = oldValue?.id != currentTranscription?.id
            if transcriptionChanged {
                selectedTab = .transcript
            }
            if transcriptionChanged || currentTranscription == nil {
                hasConversations = false
            }
            refreshPromptResultStatus()
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

    /// Fired once when a single transcription, or a whole batch, finishes and
    /// the user's completion-notification setting is on. The app layer plays
    /// the chime and (when backgrounded) posts a banner. Nil-safe: the
    /// ViewModel only invokes this with a non-nil `Content`.
    public var onTranscriptionCompleted: ((TranscriptionCompletionNotifier.Content) -> Void)?

    // MARK: - Batch transcription (local files only)
    //
    // A multi-file drop / multi-select / folder fans out into a sequential
    // queue drained on the shared file-transcription path — no new STT slot and
    // no parallelism (ADR-016). YouTube stays single-URL. The single-file path
    // (`count <= 1`) is untouched: it never enters batch state.
    public private(set) var isBatchActive = false
    public private(set) var batchTotalCount = 0
    public private(set) var batchCompletedCount = 0
    public private(set) var batchFailedCount = 0
    private var batchQueue: [URL] = []
    private var batchSource: TelemetryTranscriptionSource = .file

    /// One-line batch status for the global progress bar / batch card,
    /// e.g. "Transcribing 7 of 40" or "Transcribing 7 of 40 · 1 failed".
    public var batchStatusHeadline: String {
        let current = min(batchCompletedCount + batchFailedCount + 1, max(batchTotalCount, 1))
        var line = "Transcribing \(current) of \(batchTotalCount)"
        if batchFailedCount > 0 {
            line += " \u{00B7} \(batchFailedCount) failed"
        }
        return line
    }

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

    public func handleGenerationFailed(_ generationID: UUID, replacingPromptResultID: UUID?) {
        guard case .generation(let selectedID) = selectedTab, selectedID == generationID else { return }
        if let replacingPromptResultID {
            selectedTab = .result(id: replacingPromptResultID)
        } else {
            selectedTab = .transcript
        }
    }

    private var transcriptionService: TranscriptionServiceProtocol?
    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    private var promptResultRepo: PromptResultRepositoryProtocol?
    private var transcriptionTask: Task<Void, Never>?
    private var activeTranscriptionTaskID: UUID?
    private var activeProgressSpeechEngine: SpeechEngineSelection?
    private var activeProgressWhisperVariant: String?
    private var activeDropRequestID: UUID?
    private var dropPendingCount = 0
    private var dropCollectedURLs: [URL] = []
    private static let configurationError = "Transcription services are unavailable. Please try again."
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "TranscriptionViewModel")
    private let defaults: UserDefaults
    private let isWhisperModelDownloaded: () -> Bool
    public var promptResultsViewModel: PromptResultsViewModel?

    public init(
        defaults: UserDefaults = .standard,
        isWhisperModelDownloaded: (() -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.isWhisperModelDownloaded = isWhisperModelDownloaded ?? {
            WhisperEngine.isModelDownloaded(
                model: SpeechEnginePreference.whisperModelVariant(defaults: defaults)
            )
        }
    }

    private func aiContextText(for transcription: Transcription) -> String {
        TranscriptAIContextFormatter.format(
            transcription: transcription,
            mode: TranscriptAIContextMode.current(defaults: defaults)
        )
    }

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

    /// Entry point for one-or-many local files (drag-drop, Browse, menu-bar
    /// open). Folders are expanded recursively; a single resolved file routes
    /// through the unchanged `transcribeFile` path, two or more start a
    /// sequential batch. Returns `true` when at least one supported file was
    /// accepted (so the drop handler knows whether to dismiss the drop UI).
    @discardableResult
    public func transcribeFiles(urls: [URL], source: TelemetryTranscriptionSource = .file) -> Bool {
        guard transcriptionService != nil else {
            reportMissingConfiguration("transcriptionService", action: "transcribeFiles")
            return false
        }
        guard !isTranscribing, !isBatchActive else { return false }
        let expansion = AudioFileEnumerator.expand(urls: urls)
        let files = expansion.files
        guard !files.isEmpty else {
            errorMessage = unsupportedDropMessage
            return false
        }

        if files.count == 1 {
            transcribeFile(url: files[0], source: source)
            return true
        }

        batchSource = source
        batchTotalCount = files.count
        batchCompletedCount = 0
        batchFailedCount = 0
        batchQueue = Array(files.dropFirst())
        isBatchActive = true
        transcribeFile(url: files[0], source: source)
        // `transcribeFile` clears `errorMessage`; surface any cap overflow after
        // it so the dropped-file count is never lost silently.
        if expansion.truncated {
            let dropped = expansion.stoppedEarly
                ? "at least \(expansion.droppedCount)"
                : "\(expansion.droppedCount)"
            errorMessage = "Queued the first \(files.count) files; "
                + "\(dropped) more were skipped "
                + "(\(AudioFileEnumerator.defaultMaxFiles)-file limit)."
        }
        return true
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
        onAccepted: (@MainActor @Sendable () -> Void)? = nil
    ) -> Bool {
        guard !isTranscribing, !isBatchActive else { return false }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !fileProviders.isEmpty else { return false }

        let requestID = UUID()
        activeDropRequestID = requestID
        dropPendingCount = fileProviders.count
        dropCollectedURLs = []

        // Collect every dropped URL (files and folders), then dispatch once when
        // the last provider resolves. `transcribeFiles` expands folders, applies
        // the supported-extension filter, and chooses single vs. batch.
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                let droppedURL: URL? = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }

                Task { @MainActor in
                    guard self.activeDropRequestID == requestID else { return }
                    if let droppedURL {
                        self.dropCollectedURLs.append(droppedURL)
                    }
                    self.dropPendingCount -= 1
                    guard self.dropPendingCount == 0 else { return }

                    self.activeDropRequestID = nil
                    let urls = self.dropCollectedURLs
                    self.dropCollectedURLs = []
                    if self.transcribeFiles(urls: urls, source: .dragDrop) {
                        onAccepted?()
                    }
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

    public func retranscriptionEngineOption(for original: Transcription) -> RetranscriptionEngineOption? {
        guard let filePath = original.filePath,
              FileManager.default.fileExists(atPath: filePath) else {
            return nil
        }

        let primaryEngine: SpeechEngineSelection
        if original.sourceType == .meeting,
           let archivedRecording = archivedMeetingRecording(
               for: original,
               mixedAudioURL: URL(fileURLWithPath: filePath),
               logFailure: false
           ),
           archivedRecording.speechEngineWasCaptured {
            primaryEngine = archivedRecording.speechEngine
        } else {
            primaryEngine = SpeechEngineSelection.current(defaults: defaults)
        }

        let alternativePreference = primaryEngine.engine.alternative
        let alternativeEngine = SpeechEngineSelection(
            engine: alternativePreference,
            language: alternativePreference == .whisper
                ? SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults)
                : nil
        )
        let unavailableReason: String?
        if alternativePreference == .whisper && !isWhisperModelDownloaded() {
            unavailableReason = "Download the Whisper model in Settings before trying Whisper."
        } else {
            unavailableReason = nil
        }

        return RetranscriptionEngineOption(
            primaryEngine: primaryEngine,
            alternativeEngine: alternativeEngine,
            isAlternativeAvailable: unavailableReason == nil,
            unavailableReason: unavailableReason
        )
    }

    public func retranscribe(_ original: Transcription, speechEngineOverride: SpeechEngineSelection? = nil) {
        guard let service = transcriptionService else {
            reportMissingConfiguration("transcriptionService", action: "retranscribe")
            return
        }
        guard let filePath = original.filePath,
              FileManager.default.fileExists(atPath: filePath) else { return }

        let url = URL(fileURLWithPath: filePath)
        let taskID = beginNewTranscription(
            source: .localFile,
            fileName: original.fileName,
            clearCurrent: true,
            speechEngine: speechEngineOverride
        )
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
                    result = try await service.retranscribeMeeting(
                        existing: original,
                        recording: meetingRecording,
                        speechEngineOverride: speechEngineOverride,
                        onProgress: progressHandler
                    )
                } else {
                    result = try await service.retranscribe(
                        existing: original,
                        fileURL: url,
                        source: retranscriptionSource,
                        speechEngineOverride: speechEngineOverride,
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
                updatedResult.recoveredFromCrash = original.recoveredFromCrash
                updatedResult.userNotes = original.userNotes
                updatedResult.updatedAt = Date()
                do {
                    try transcriptionRepo?.save(updatedResult)
                    // Skip auto-run prompts on retranscribe — they would duplicate the existing tabs.
                    completeSuccessfulTranscription(taskID: taskID, result: updatedResult, runAutoPrompts: false)
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
        mixedAudioURL: URL,
        logFailure: Bool = true
    ) -> MeetingRecordingOutput? {
        let durationSeconds = Double(original.durationMs ?? 0) / 1000.0
        do {
            return try MeetingRecordingOutput.loadArchived(
                displayName: original.fileName,
                mixedAudioURL: mixedAudioURL,
                durationSeconds: durationSeconds
            )
        } catch {
            if logFailure {
                logger.notice(
                    "Meeting retranscribe falling back to mixed audio path file=\(original.fileName, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
                )
            }
            return nil
        }
    }

    public func cancelTranscription() {
        transcriptionTask?.cancel()
    }

    /// Cancel an in-progress batch deterministically: drop everything still
    /// queued, cancel the in-flight task, and clear all batch + transcription
    /// state *now*. Crucially we also drop `activeTranscriptionTaskID`, so if the
    /// in-flight file's STT inference isn't cancellation-aware and completes
    /// anyway, its completion funnel no-ops on the task-ID guard — the batch
    /// never advances or fires a spurious completion chime after "Cancel all".
    public func cancelBatch() {
        guard isBatchActive else { return }
        batchQueue.removeAll()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        activeTranscriptionTaskID = nil
        resetBatchState()
        endTranscription()
        errorMessage = nil
        loadTranscriptions()
    }

    /// Submit the next queued file, or finish the batch when the queue drains.
    /// Called only from the completion funnels, where `transcriptionTask` is
    /// already nil — so `transcribeFile` → `beginNewTranscription`'s
    /// `cancel()` is a no-op and never aborts the next file.
    private func advanceBatch() {
        guard isBatchActive else { return }
        if batchQueue.isEmpty {
            finishBatch()
        } else {
            let next = batchQueue.removeFirst()
            transcribeFile(url: next, source: batchSource)
        }
    }

    private func finishBatch() {
        let content = TranscriptionCompletionNotifier.batchContent(
            settingEnabled: notifyOnCompletionEnabled,
            completed: batchCompletedCount,
            failed: batchFailedCount
        )
        resetBatchState()
        emitCompletionSignal(content)
    }

    private func resetBatchState() {
        isBatchActive = false
        batchTotalCount = 0
        batchCompletedCount = 0
        batchFailedCount = 0
        batchQueue.removeAll()
    }

    private func emitCompletionSignal(_ content: TranscriptionCompletionNotifier.Content?) {
        guard let content else { return }
        onTranscriptionCompleted?(content)
    }

    private var notifyOnCompletionEnabled: Bool {
        defaults.object(forKey: UserDefaultsAppRuntimePreferences.notifyOnTranscriptionCompleteKey) as? Bool ?? true
    }

    private static func wordCount(of transcription: Transcription) -> Int {
        let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        return text.split(whereSeparator: { $0.isWhitespace }).count
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
            try TranscriptionDeletionCleanup.removeOwnedAssets(for: transcription)
            let deleted = try repo.delete(id: transcription.id)
            guard deleted else { return }
            Telemetry.send(.transcriptionDeleted)
            if currentTranscription?.id == transcription.id {
                currentTranscription = nil
            }
            loadTranscriptions()
        } catch {
            logger.error("Failed to delete transcription: \(error.localizedDescription, privacy: .private)")
            errorMessage = "Failed to delete transcription: \(error.localizedDescription)"
        }
    }

    // MARK: - Progress State

    private func beginNewTranscription(
        source: SourceKind,
        fileName: String,
        clearCurrent: Bool = false,
        speechEngine: SpeechEngineSelection? = nil
    ) -> UUID {
        transcriptionTask?.cancel()

        let taskID = UUID()
        activeTranscriptionTaskID = taskID
        let progressSpeechEngine = speechEngine ?? SpeechEngineSelection.current(defaults: defaults)
        activeProgressSpeechEngine = progressSpeechEngine
        activeProgressWhisperVariant = progressSpeechEngine.engine == .whisper
            ? SpeechEnginePreference.whisperModelVariant(defaults: defaults)
            : nil
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

    private func completeSuccessfulTranscription(
        taskID: UUID,
        result: Transcription,
        runAutoPrompts: Bool = true
    ) {
        guard activeTranscriptionTaskID == taskID else { return }
        transcriptionTask = nil
        activeTranscriptionTaskID = nil
        endTranscription()

        if isBatchActive {
            // Ambient batch: don't present each file (no nav thrash) and don't
            // auto-run prompts per file. Export-to-folder still honors its own
            // toggle, and Library refreshes live so results appear as they land.
            batchCompletedCount += 1
            autoSaveIfEnabled(result)
            loadTranscriptions()
            advanceBatch()
        } else {
            presentCompletedTranscription(result, autoSave: false, runAutoPrompts: runAutoPrompts)
            autoSaveIfEnabled(result)
            emitCompletionSignal(
                TranscriptionCompletionNotifier.singleContent(
                    settingEnabled: notifyOnCompletionEnabled,
                    transcriptName: result.fileName,
                    wordCount: Self.wordCount(of: result)
                )
            )
        }
    }

    private func autoSaveIfEnabled(_ transcription: Transcription) {
        let service = AutoSaveService()
        let scope: AutoSaveScope = transcription.sourceType == .meeting ? .meeting : .transcription
        service.saveIfEnabled(transcription, scope: scope)
    }

    /// Persist a new playback-friendly file path produced by the background
    /// YouTube audio transcode (webm/opus → m4a). Used by MediaPlayerViewModel's
    /// lazy on-open migration so the next open hits the .m4a directly.
    ///
    /// `sourceFileToCleanup`, when non-nil, is the original (unplayable)
    /// file the new path supersedes. It is deleted only after the DB
    /// `updateFilePath` write succeeds — a DB failure leaves the source
    /// in place so a future open can retry the migration.
    public func applyConvertedPlaybackPath(
        transcriptionID: UUID,
        newFilePath: String,
        sourceFileToCleanup: String? = nil
    ) throws {
        guard let repo = transcriptionRepo else { return }
        do {
            try repo.updateFilePath(id: transcriptionID, filePath: newFilePath)
        } catch {
            logger.error("transcription_file_path_update_failed id=\(transcriptionID, privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
            throw error
        }
        if let sourceFileToCleanup, sourceFileToCleanup != newFilePath {
            try? FileManager.default.removeItem(atPath: sourceFileToCleanup)
        }
        if let current = currentTranscription, current.id == transcriptionID {
            var updated = current
            updated.filePath = newFilePath
            currentTranscription = updated
        }
        if let index = transcriptions.firstIndex(where: { $0.id == transcriptionID }) {
            transcriptions[index].filePath = newFilePath
        }
    }

    public func presentCompletedTranscription(_ transcription: Transcription) {
        presentCompletedTranscription(transcription, autoSave: false, runAutoPrompts: true)
    }

    public func presentCompletedTranscription(_ transcription: Transcription, autoSave: Bool) {
        presentCompletedTranscription(transcription, autoSave: autoSave, runAutoPrompts: true)
    }

    public func presentCompletedTranscription(
        _ transcription: Transcription,
        autoSave: Bool,
        runAutoPrompts: Bool
    ) {
        currentTranscription = transcription
        loadTranscriptions()
        if autoSave {
            autoSaveIfEnabled(transcription)
        }
        guard runAutoPrompts else { return }
        let text = aiContextText(for: transcription)
        promptResultsViewModel?.autoGeneratePromptResults(
            transcript: text,
            transcriptionId: transcription.id,
            sourceType: transcription.sourceType
        )
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
        endTranscription()

        if isBatchActive {
            // A failed file never aborts the batch — it bumps the failure count
            // (surfaced in the status line + completion banner) and advances.
            batchFailedCount += 1
            logger.error("Batch file transcription failed error=\(error.localizedDescription, privacy: .public)")
            loadTranscriptions()
            advanceBatch()
        } else {
            errorMessage = error.localizedDescription
            loadTranscriptions()
        }
    }

    private func completeCancelledTranscription(taskID: UUID) {
        guard activeTranscriptionTaskID == taskID else { return }
        transcriptionTask = nil
        activeTranscriptionTaskID = nil
        errorMessage = nil
        endTranscription()
        // Any cancellation ends the whole batch — there is no per-item cancel,
        // so "Cancel all" and a stray single cancel converge to the same reset.
        if isBatchActive {
            resetBatchState()
        }
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
        activeProgressSpeechEngine = nil
        activeProgressWhisperVariant = nil
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
        let speechEngine = activeProgressSpeechEngine ?? SpeechEngineSelection.current(defaults: defaults)
        let whisperVariant = activeProgressWhisperVariant
            ?? SpeechEnginePreference.whisperModelVariant(defaults: defaults)
        self.progressSubline = Self.subline(
            for: phase,
            sourceKind: sourceKind,
            engine: speechEngine.engine,
            whisperVariant: whisperVariant
        )
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

    private static func subline(
        for phase: ProgressPhase,
        sourceKind: SourceKind,
        engine: SpeechEnginePreference,
        whisperVariant: String
    ) -> String? {
        switch phase {
        case .downloading:
            return sourceKind == .youtubeURL
                ? "Longer videos take more time to fetch"
                : nil
        case .transcribing:
            switch engine {
            case .parakeet:
                return "Parakeet TDT \u{00B7} Neural Engine"
            case .whisper:
                let friendly = SpeechEnginePreference.friendlyVariantName(whisperVariant)
                return "Whisper \(friendly) \u{00B7} Neural Engine"
            }
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

    public func updateLLMAvailability(_ available: Bool, llmService: LLMServiceProtocol? = nil) {
        self.llmAvailable = available
    }

    // MARK: - Transcript Editing

    @discardableResult
    public func updateCurrentTranscriptText(to newText: String) -> Bool {
        guard var transcription = currentTranscription else { return false }
        guard let repo = transcriptionRepo else {
            reportMissingConfiguration("transcriptionRepo", action: "updateCurrentTranscriptText")
            return false
        }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let currentText = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        guard trimmed != currentText else { return false }

        transcription.cleanTranscript = trimmed == transcription.rawTranscript ? nil : trimmed
        transcription.isTranscriptEdited = transcription.cleanTranscript != nil
        transcription.updatedAt = Date()

        do {
            try repo.save(transcription)
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
        guard let repo = transcriptionRepo else {
            reportMissingConfiguration("transcriptionRepo", action: "revertCurrentTranscriptToOriginal")
            return false
        }

        transcription.cleanTranscript = nil
        transcription.isTranscriptEdited = false
        transcription.updatedAt = Date()

        do {
            try repo.save(transcription)
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
        transcription.derivedTitle = trimmed
        currentTranscription = transcription
        do {
            try transcriptionRepo?.updateFileName(id: transcription.id, fileName: trimmed)
            if let index = transcriptions.firstIndex(where: { $0.id == transcription.id }) {
                transcriptions[index].fileName = trimmed
                transcriptions[index].derivedTitle = trimmed
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
