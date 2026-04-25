import Foundation
import MacParakeetCore
import OSLog

@MainActor
@Observable
public final class PromptResultsViewModel {
    public struct PendingGeneration: Identifiable, Equatable, Sendable {
        public enum State: Equatable, Sendable {
            case queued
            case streaming
        }

        public var id: UUID
        public var transcriptionId: UUID
        public var promptName: String
        public var promptContent: String
        public var extraInstructions: String?
        public var transcript: String
        /// Snapshot of `Transcription.userNotes` captured at enqueue time. Used
        /// both to substitute `{{userNotes}}` in the prompt template and to
        /// snapshot onto the resulting `PromptResult` (ADR-020 §4, §6).
        public var userNotes: String?
        public var replacingPromptResultID: UUID?
        public var state: State
        public var content: String

        public init(
            id: UUID = UUID(),
            transcriptionId: UUID,
            promptName: String,
            promptContent: String,
            extraInstructions: String?,
            transcript: String,
            userNotes: String? = nil,
            replacingPromptResultID: UUID? = nil,
            state: State = .queued,
            content: String = ""
        ) {
            self.id = id
            self.transcriptionId = transcriptionId
            self.promptName = promptName
            self.promptContent = promptContent
            self.extraInstructions = extraInstructions
            self.transcript = transcript
            self.userNotes = userNotes
            self.replacingPromptResultID = replacingPromptResultID
            self.state = state
            self.content = content
        }
    }

    private static let autoGenerationTranscriptLengthThreshold = 500
    /// Soft cap on user notes for prompt-assembly only — full notes remain on
    /// the Transcription row. ~11k tokens at typical English word→token ratio,
    /// leaving headroom for transcript + system prompt + response (ADR-020 §3).
    static let userNotesPromptWordCap = 8_000

    public var promptResults: [PromptResult] = []
    public var pendingGenerations: [PendingGeneration] = []
    public var selectedPrompt: Prompt?
    public var extraInstructions: String = ""
    public var errorMessage: String?
    public var visiblePrompts: [Prompt] = []
    public var pendingDeletePromptResult: PromptResult?
    public var currentModelName: String = ""
    public var currentProviderID: LLMProviderID?
    public var availableModels: [String] = []
    public var unreadPromptResultIDs: Set<UUID> = []
    public var onModelChanged: (() -> Void)?
    public var onPromptResultsChanged: ((UUID, Bool) -> Void)?
    public var onGenerationCompleted: ((UUID, UUID) -> Void)?
    public var onDeletedPromptResult: ((UUID) -> Void)?
    public var shouldMarkPromptResultUnread: ((UUID) -> Bool)?

    private var llmService: LLMServiceProtocol?
    private var promptRepo: PromptRepositoryProtocol?
    private var promptResultRepo: PromptResultRepositoryProtocol?
    /// Read-only access to the underlying transcription so prompt assembly
    /// can pull `userNotes` for `{{userNotes}}` substitution and snapshotting
    /// (ADR-020 §4, §6). The legacy `updateSummary` write-back path that
    /// also lived through this property was removed in v0.7.6.
    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    private var configStore: LLMConfigStoreProtocol?
    private var cliConfigStore: LocalCLIConfigStore?
    private var currentTranscriptionID: UUID?
    private var streamingTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "PromptResultsViewModel")

    public var canGeneratePromptResult: Bool {
        llmService != nil
    }

    public var canGenerateManualPromptResult: Bool {
        llmService != nil && selectedPrompt != nil
    }

    public var hasPromptResultGenerationCapability: Bool {
        llmService != nil
    }

    public var hasPendingGenerations: Bool {
        !pendingGenerations.isEmpty
    }

    public var isStreaming: Bool {
        activeStreamingGeneration != nil
    }

    public var queuedGenerationCount: Int {
        pendingGenerations.filter { $0.state == .queued }.count
    }

    public var streamingContent: String {
        activeStreamingGeneration?.content ?? ""
    }

    public var streamingPromptResultID: UUID? {
        activeStreamingGeneration?.id
    }

    public var streamingPromptName: String {
        activeStreamingGeneration?.promptName ?? ""
    }

    public var modelDisplayName: String {
        guard !currentModelName.isEmpty else { return "" }
        if currentProviderID == .openrouter, let slashIndex = currentModelName.firstIndex(of: "/") {
            return String(currentModelName[currentModelName.index(after: slashIndex)...])
        }
        return currentModelName
    }

    private var activeStreamingGeneration: PendingGeneration? {
        pendingGenerations.first(where: { $0.state == .streaming })
    }

    public init() {}

    public func configure(
        llmService: LLMServiceProtocol?,
        promptRepo: PromptRepositoryProtocol?,
        promptResultRepo: PromptResultRepositoryProtocol?,
        transcriptionRepo: TranscriptionRepositoryProtocol? = nil,
        configStore: LLMConfigStoreProtocol? = nil,
        cliConfigStore: LocalCLIConfigStore = LocalCLIConfigStore()
    ) {
        self.llmService = llmService
        self.promptRepo = promptRepo
        self.promptResultRepo = promptResultRepo
        self.transcriptionRepo = transcriptionRepo
        self.configStore = configStore
        self.cliConfigStore = cliConfigStore
        loadVisiblePrompts()
        refreshModelInfo()
    }

    public func updateLLMService(_ service: LLMServiceProtocol?) {
        cancelAllGenerations()
        llmService = service
        refreshModelInfo()
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
        guard let configStore, currentProviderID != .localCLI, !hasPendingGenerations else { return }
        do {
            try configStore.updateModelName(modelName)
            currentModelName = modelName
            onModelChanged?()
        } catch {
            refreshModelInfo()
        }
    }

    public func loadVisiblePrompts() {
        guard let promptRepo else { return }
        do {
            visiblePrompts = try promptRepo.fetchVisible(category: .result)
            if let selectedPrompt,
               let refreshed = visiblePrompts.first(where: { $0.id == selectedPrompt.id }) {
                self.selectedPrompt = refreshed
            } else {
                self.selectedPrompt = visiblePrompts.first(where: { $0.isAutoRun })
                    ?? visiblePrompts.first
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            visiblePrompts = []
            selectedPrompt = nil
        }
    }

    public func loadPromptResults(transcriptionId: UUID) {
        if currentTranscriptionID != transcriptionId {
            cancelAllGenerations()
        }
        currentTranscriptionID = transcriptionId
        do {
            promptResults = try promptResultRepo?.fetchAll(transcriptionId: transcriptionId) ?? []
            onPromptResultsChanged?(transcriptionId, !promptResults.isEmpty)
            errorMessage = nil
        } catch {
            promptResults = []
            onPromptResultsChanged?(transcriptionId, false)
            errorMessage = error.localizedDescription
        }
        processNextQueuedGeneration()
    }

    public func markPromptResultViewed(_ promptResultID: UUID) {
        unreadPromptResultIDs.remove(promptResultID)
    }

    public func hasUnreadPromptResult(_ promptResultID: UUID) -> Bool {
        unreadPromptResultIDs.contains(promptResultID)
    }

    public func pendingGeneration(id: UUID) -> PendingGeneration? {
        pendingGenerations.first(where: { $0.id == id })
    }

    public func pendingGenerations(for transcriptionId: UUID) -> [PendingGeneration] {
        pendingGenerations.filter { $0.transcriptionId == transcriptionId }
    }

    public func hasPendingGeneration(promptName: String, transcriptionId: UUID) -> Bool {
        pendingGenerations.contains {
            $0.transcriptionId == transcriptionId && $0.promptName == promptName
        }
    }

    public func confirmDelete() {
        guard let promptResult = pendingDeletePromptResult else { return }
        pendingDeletePromptResult = nil
        deletePromptResult(promptResult)
    }

    public func deletePromptResult(_ promptResult: PromptResult) {
        guard let promptResultRepo else { return }
        do {
            _ = try promptResultRepo.delete(id: promptResult.id)
            promptResults.removeAll { $0.id == promptResult.id }
            unreadPromptResultIDs.remove(promptResult.id)
            if let transcriptionID = currentTranscriptionID {
                onPromptResultsChanged?(transcriptionID, !promptResults.isEmpty)
            }
            onDeletedPromptResult?(promptResult.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func generatePromptResult(transcript: String, transcriptionId: UUID) -> UUID? {
        guard let prompt = selectedPrompt else { return nil }
        return enqueueGeneration(
            transcript: transcript,
            transcriptionId: transcriptionId,
            prompt: prompt,
            extraInstructions: normalizedExtraInstructions(extraInstructions),
            userNotes: fetchUserNotes(for: transcriptionId)
        )
    }

    @discardableResult
    public func regeneratePromptResult(_ promptResult: PromptResult, transcript: String) -> UUID? {
        let prompt = Prompt(
            name: promptResult.promptName,
            content: promptResult.promptContent,
            isBuiltIn: false,
            sortOrder: 0
        )
        // Regeneration re-snapshots from the *current* notes on the row — if
        // the user edited notes between summary generations they expect the
        // new summary to reflect the new notes. The original summary's
        // snapshot remains untouched on its row (ADR-020 §6).
        return enqueueGeneration(
            transcript: transcript,
            transcriptionId: promptResult.transcriptionId,
            prompt: prompt,
            extraInstructions: promptResult.extraInstructions,
            userNotes: fetchUserNotes(for: promptResult.transcriptionId),
            replacingPromptResultID: promptResult.id
        )
    }

    @discardableResult
    public func autoGeneratePromptResults(transcript: String, transcriptionId: UUID) -> [UUID] {
        guard transcript.count > Self.autoGenerationTranscriptLengthThreshold else { return [] }

        let autoPrompts = (try? promptRepo?.fetchAutoRunPrompts()) ?? [Prompt.defaultPrompt]
        guard !autoPrompts.isEmpty else { return [] }

        let userNotes = fetchUserNotes(for: transcriptionId)
        var queuedIDs: [UUID] = []
        for prompt in autoPrompts {
            if let id = enqueueGeneration(
                transcript: transcript,
                transcriptionId: transcriptionId,
                prompt: prompt,
                extraInstructions: nil,
                userNotes: userNotes
            ) {
                queuedIDs.append(id)
            }
        }
        return queuedIDs
    }

    public func cancelStreaming() {
        guard let generationID = streamingPromptResultID else { return }
        cancelGeneration(id: generationID)
    }

    public func cancelGeneration(id: UUID) {
        guard let index = pendingGenerations.firstIndex(where: { $0.id == id }) else { return }
        if pendingGenerations[index].state == .streaming {
            streamingTask?.cancel()
            return
        }
        pendingGenerations.remove(at: index)
    }

    private func cancelAllGenerations() {
        streamingTask?.cancel()
        streamingTask = nil
        pendingGenerations = []
    }

    @discardableResult
    private func enqueueGeneration(
        transcript: String,
        transcriptionId: UUID,
        prompt: Prompt,
        extraInstructions: String?,
        userNotes: String? = nil,
        replacingPromptResultID: UUID? = nil
    ) -> UUID? {
        guard llmService != nil else { return nil }

        currentTranscriptionID = transcriptionId
        errorMessage = nil

        let generation = PendingGeneration(
            transcriptionId: transcriptionId,
            promptName: prompt.name,
            promptContent: prompt.content,
            extraInstructions: extraInstructions,
            transcript: transcript,
            userNotes: userNotes,
            replacingPromptResultID: replacingPromptResultID
        )
        pendingGenerations.append(generation)
        processNextQueuedGeneration()
        return generation.id
    }

    private func processNextQueuedGeneration() {
        guard streamingTask == nil, llmService != nil else { return }
        guard let currentTranscriptionID else { return }
        guard let nextIndex = pendingGenerations.firstIndex(where: {
            $0.state == .queued && $0.transcriptionId == currentTranscriptionID
        }) else { return }

        pendingGenerations[nextIndex].state = .streaming
        let generation = pendingGenerations[nextIndex]
        let generationID = generation.id
        let systemPrompt = assembledSystemPrompt(
            promptContent: generation.promptContent,
            extraInstructions: generation.extraInstructions,
            userNotes: generation.userNotes
        )

        streamingTask = Task { @MainActor [weak self] in
            guard let self, let llmService = self.llmService else { return }
            do {
                let stream = llmService.generatePromptResultStream(
                    transcript: generation.transcript,
                    systemPrompt: systemPrompt
                )
                for try await token in stream {
                    appendStreamingToken(token, to: generationID)
                }
                guard !Task.isCancelled else {
                    finishCancelledGeneration(id: generationID)
                    return
                }
                try finishGeneration(id: generationID)
            } catch is CancellationError {
                finishCancelledGeneration(id: generationID)
            } catch {
                finishFailedGeneration(id: generationID, error: error)
            }
        }
    }

    private func appendStreamingToken(_ token: String, to generationID: UUID) {
        guard let index = pendingGenerations.firstIndex(where: { $0.id == generationID }) else { return }
        pendingGenerations[index].content += token
    }

    private func finishGeneration(id generationID: UUID) throws {
        guard let index = pendingGenerations.firstIndex(where: { $0.id == generationID }) else {
            streamingTask = nil
            processNextQueuedGeneration()
            return
        }

        let generation = pendingGenerations[index]
        let timestamp = Date()
        let promptResult = PromptResult(
            id: generation.id,
            transcriptionId: generation.transcriptionId,
            promptName: generation.promptName,
            promptContent: generation.promptContent,
            extraInstructions: generation.extraInstructions,
            content: generation.content,
            userNotesSnapshot: generation.userNotes,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        if let replacingPromptResultID = generation.replacingPromptResultID {
            try promptResultRepo?.replace(promptResult, deletingExistingID: replacingPromptResultID)
        } else {
            try promptResultRepo?.save(promptResult)
        }

        pendingGenerations.remove(at: index)
        streamingTask = nil

        if currentTranscriptionID == generation.transcriptionId {
            if let replacingPromptResultID = generation.replacingPromptResultID {
                unreadPromptResultIDs.remove(replacingPromptResultID)
                promptResults.removeAll { $0.id == replacingPromptResultID }
            }
            promptResults.insert(promptResult, at: 0)
        }

        onPromptResultsChanged?(generation.transcriptionId, true)
        onGenerationCompleted?(generation.id, promptResult.id)
        if let replacingPromptResultID = generation.replacingPromptResultID {
            onDeletedPromptResult?(replacingPromptResultID)
        }
        if shouldMarkPromptResultUnread?(promptResult.id) ?? true {
            unreadPromptResultIDs.insert(promptResult.id)
        }

        processNextQueuedGeneration()
    }

    private func finishCancelledGeneration(id generationID: UUID) {
        if let index = pendingGenerations.firstIndex(where: { $0.id == generationID }) {
            pendingGenerations.remove(at: index)
        }
        streamingTask = nil
        processNextQueuedGeneration()
    }

    private func finishFailedGeneration(id generationID: UUID, error: Error) {
        logger.error("Failed to generate prompt result error=\(error.localizedDescription, privacy: .public)")
        if let index = pendingGenerations.firstIndex(where: { $0.id == generationID }) {
            pendingGenerations.remove(at: index)
        }
        streamingTask = nil
        errorMessage = error.localizedDescription
        processNextQueuedGeneration()
    }

    private func assembledSystemPrompt(
        promptContent: String,
        extraInstructions: String?,
        userNotes: String? = nil
    ) -> String {
        // Substitute supported template variables (ADR-020 §4). Single-pass
        // simultaneous; user notes containing literal `{{transcript}}` cannot
        // smuggle further substitutions on a second pass.
        let cappedNotes = userNotes.map { Self.truncateNotesForPrompt($0) }
        let renderedPrompt = PromptTemplateRenderer.render(
            promptContent,
            substitutions: [
                .userNotes: cappedNotes ?? "",
            ]
        )

        let trimmedInstructions = extraInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedInstructions, !trimmedInstructions.isEmpty else {
            return renderedPrompt
        }
        return renderedPrompt + "\n\n" + trimmedInstructions
    }

    /// Truncate user notes to the prompt-assembly soft cap (8,000 words).
    /// Persisted notes are never modified — this only protects the LLM
    /// context window at generation time (ADR-020 §3).
    static func truncateNotesForPrompt(_ notes: String) -> String {
        let words = notes.split(whereSeparator: \.isWhitespace)
        guard words.count > userNotesPromptWordCap else { return notes }
        let kept = words.prefix(userNotesPromptWordCap).joined(separator: " ")
        return kept + "\n\n[Notes truncated to \(userNotesPromptWordCap) words for summary generation; full notes preserved on the recording.]"
    }

    private func fetchUserNotes(for transcriptionId: UUID) -> String? {
        guard let transcriptionRepo else { return nil }
        do {
            return try transcriptionRepo.fetch(id: transcriptionId)?.userNotes
        } catch {
            logger.warning("Failed to fetch userNotes for transcription \(transcriptionId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func normalizedExtraInstructions(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
