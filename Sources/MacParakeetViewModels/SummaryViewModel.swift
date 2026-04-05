import Foundation
import MacParakeetCore
import OSLog

@MainActor
@Observable
public final class SummaryViewModel {
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
        public var replacingSummaryID: UUID?
        public var state: State
        public var content: String

        public init(
            id: UUID = UUID(),
            transcriptionId: UUID,
            promptName: String,
            promptContent: String,
            extraInstructions: String?,
            transcript: String,
            replacingSummaryID: UUID? = nil,
            state: State = .queued,
            content: String = ""
        ) {
            self.id = id
            self.transcriptionId = transcriptionId
            self.promptName = promptName
            self.promptContent = promptContent
            self.extraInstructions = extraInstructions
            self.transcript = transcript
            self.replacingSummaryID = replacingSummaryID
            self.state = state
            self.content = content
        }
    }

    private static let autoSummaryTranscriptLengthThreshold = 500

    public var summaries: [Summary] = []
    public var pendingGenerations: [PendingGeneration] = []
    public var selectedPrompt: Prompt?
    public var extraInstructions: String = ""
    public var errorMessage: String?
    public var visiblePrompts: [Prompt] = []
    public var pendingDeleteSummary: Summary?
    public var currentModelName: String = ""
    public var currentProviderID: LLMProviderID?
    public var availableModels: [String] = []
    public var badgedSummaryID: UUID?
    public var onModelChanged: (() -> Void)?
    public var onSummariesChanged: ((UUID, Bool) -> Void)?
    public var onLegacySummaryChanged: ((UUID, String?) -> Void)?
    public var onGenerationCompleted: ((UUID, UUID) -> Void)?
    public var onDeletedSummary: ((UUID) -> Void)?
    public var shouldShowBadge: ((UUID) -> Bool)?

    private var llmService: LLMServiceProtocol?
    private var promptRepo: PromptRepositoryProtocol?
    private var summaryRepo: SummaryRepositoryProtocol?
    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    private var configStore: LLMConfigStoreProtocol?
    private var cliConfigStore: LocalCLIConfigStore?
    private var currentTranscriptionID: UUID?
    private var streamingTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "SummaryViewModel")

    public var canGenerateSummary: Bool {
        llmService != nil
    }

    public var canGenerateManualSummary: Bool {
        llmService != nil && selectedPrompt != nil
    }

    public var hasSummaryGenerationCapability: Bool {
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

    public var streamingSummaryID: UUID? {
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
        summaryRepo: SummaryRepositoryProtocol?,
        transcriptionRepo: TranscriptionRepositoryProtocol? = nil,
        configStore: LLMConfigStoreProtocol? = nil,
        cliConfigStore: LocalCLIConfigStore = LocalCLIConfigStore()
    ) {
        self.llmService = llmService
        self.promptRepo = promptRepo
        self.summaryRepo = summaryRepo
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
            visiblePrompts = try promptRepo.fetchVisible(category: .summary)
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

    public func loadSummaries(transcriptionId: UUID) {
        if currentTranscriptionID != transcriptionId {
            cancelStreaming()
        }
        currentTranscriptionID = transcriptionId
        do {
            summaries = try summaryRepo?.fetchAll(transcriptionId: transcriptionId) ?? []
            onSummariesChanged?(transcriptionId, !summaries.isEmpty)
            errorMessage = nil
        } catch {
            summaries = []
            onSummariesChanged?(transcriptionId, false)
            errorMessage = error.localizedDescription
        }
        processNextQueuedGeneration()
    }

    public func clearBadge(for summaryID: UUID) {
        if badgedSummaryID == summaryID {
            badgedSummaryID = nil
        }
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
        guard let summary = pendingDeleteSummary else { return }
        pendingDeleteSummary = nil
        deleteSummary(summary)
    }

    public func deleteSummary(_ summary: Summary) {
        guard let summaryRepo else { return }
        do {
            _ = try summaryRepo.delete(id: summary.id)
            summaries.removeAll { $0.id == summary.id }
            if badgedSummaryID == summary.id { badgedSummaryID = nil }
            try syncLegacySummary(for: summary.transcriptionId)
            if let transcriptionID = currentTranscriptionID {
                onSummariesChanged?(transcriptionID, !summaries.isEmpty)
            }
            onDeletedSummary?(summary.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func generateSummary(transcript: String, transcriptionId: UUID) -> UUID? {
        guard let prompt = selectedPrompt else { return nil }
        return enqueueGeneration(
            transcript: transcript,
            transcriptionId: transcriptionId,
            prompt: prompt,
            extraInstructions: normalizedExtraInstructions(extraInstructions)
        )
    }

    @discardableResult
    public func regenerateSummary(_ summary: Summary, transcript: String) -> UUID? {
        let prompt = Prompt(
            name: summary.promptName,
            content: summary.promptContent,
            isBuiltIn: false,
            sortOrder: 0
        )
        return enqueueGeneration(
            transcript: transcript,
            transcriptionId: summary.transcriptionId,
            prompt: prompt,
            extraInstructions: summary.extraInstructions,
            replacingSummaryID: summary.id
        )
    }

    @discardableResult
    public func autoSummarize(transcript: String, transcriptionId: UUID) -> [UUID] {
        guard transcript.count > Self.autoSummaryTranscriptLengthThreshold else { return [] }
        
        let autoPrompts = (try? promptRepo?.fetchAutoRunPrompts()) ?? [Prompt.defaultPrompt]
        guard !autoPrompts.isEmpty else { return [] }
        
        var queuedIDs: [UUID] = []
        for prompt in autoPrompts {
            if let id = enqueueGeneration(
                transcript: transcript,
                transcriptionId: transcriptionId,
                prompt: prompt,
                extraInstructions: nil
            ) {
                queuedIDs.append(id)
            }
        }
        return queuedIDs
    }

    public func cancelStreaming() {
        guard let generationID = streamingSummaryID else { return }
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
        replacingSummaryID: UUID? = nil
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
            replacingSummaryID: replacingSummaryID
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
            extraInstructions: generation.extraInstructions
        )

        streamingTask = Task { @MainActor [weak self] in
            guard let self, let llmService = self.llmService else { return }
            do {
                let stream = llmService.summarizeStream(
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
        let summary = Summary(
            id: generation.id,
            transcriptionId: generation.transcriptionId,
            promptName: generation.promptName,
            promptContent: generation.promptContent,
            extraInstructions: generation.extraInstructions,
            content: generation.content,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        if let replacingSummaryID = generation.replacingSummaryID {
            try summaryRepo?.replace(summary, deletingExistingID: replacingSummaryID)
        } else {
            try summaryRepo?.save(summary)
        }
        try transcriptionRepo?.updateSummary(id: generation.transcriptionId, summary: summary.content)
        onLegacySummaryChanged?(generation.transcriptionId, summary.content)

        pendingGenerations.remove(at: index)
        streamingTask = nil

        if currentTranscriptionID == generation.transcriptionId {
            if let replacingSummaryID = generation.replacingSummaryID {
                if badgedSummaryID == replacingSummaryID { badgedSummaryID = nil }
                summaries.removeAll { $0.id == replacingSummaryID }
            }
            summaries.insert(summary, at: 0)
        }

        onSummariesChanged?(generation.transcriptionId, true)
        onGenerationCompleted?(generation.id, summary.id)
        if let replacingSummaryID = generation.replacingSummaryID {
            onDeletedSummary?(replacingSummaryID)
        }
        if shouldShowBadge?(summary.id) ?? true {
            badgedSummaryID = summary.id
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
        logger.error("Failed to generate summary error=\(error.localizedDescription, privacy: .public)")
        if let index = pendingGenerations.firstIndex(where: { $0.id == generationID }) {
            pendingGenerations.remove(at: index)
        }
        streamingTask = nil
        errorMessage = error.localizedDescription
        processNextQueuedGeneration()
    }

    private func assembledSystemPrompt(promptContent: String, extraInstructions: String?) -> String {
        let trimmedInstructions = extraInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedInstructions, !trimmedInstructions.isEmpty else {
            return promptContent
        }
        return promptContent + "\n\n" + trimmedInstructions
    }

    private func normalizedExtraInstructions(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func syncLegacySummary(for transcriptionId: UUID) throws {
        let latestSummary = try summaryRepo?.fetchAll(transcriptionId: transcriptionId).first
        try transcriptionRepo?.updateSummary(id: transcriptionId, summary: latestSummary?.content)
        onLegacySummaryChanged?(transcriptionId, latestSummary?.content)
    }
}
