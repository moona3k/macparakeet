import Foundation
import MacParakeetCore
import OSLog

@MainActor
@Observable
public final class SummaryViewModel {
    private static let autoSummaryTranscriptLengthThreshold = 500

    public var summaries: [Summary] = []
    public var isStreaming: Bool = false
    public var streamingContent: String = ""
    public var streamingSummaryID: UUID?
    public var streamingPromptName: String = ""
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
    public var onSelectSummaryTab: ((UUID) -> Void)?
    public var onDeletedSummary: ((UUID) -> Void)?
    public var shouldShowBadge: (() -> Bool)?

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
        llmService != nil && !isStreaming
    }

    public var hasSummaryGenerationCapability: Bool {
        llmService != nil
    }

    public var modelDisplayName: String {
        guard !currentModelName.isEmpty else { return "" }
        if currentProviderID == .openrouter, let slashIndex = currentModelName.firstIndex(of: "/") {
            return String(currentModelName[currentModelName.index(after: slashIndex)...])
        }
        return currentModelName
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
        cancelStreaming()
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
        guard let configStore, currentProviderID != .localCLI else { return }
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
                self.selectedPrompt = visiblePrompts.first(where: { $0.name == Prompt.defaultSummaryPrompt.name })
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
    }

    public func clearBadge(for summaryID: UUID) {
        if badgedSummaryID == summaryID {
            badgedSummaryID = nil
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

    public func generateSummary(transcript: String, transcriptionId: UUID) {
        let prompt = selectedPrompt ?? Prompt.defaultSummaryPrompt
        startGeneration(
            transcript: transcript,
            transcriptionId: transcriptionId,
            prompt: prompt,
            extraInstructions: normalizedExtraInstructions(extraInstructions)
        )
    }

    public func regenerateSummary(_ summary: Summary, transcript: String) {
        let prompt = Prompt(
            name: summary.promptName,
            content: summary.promptContent,
            isBuiltIn: false,
            sortOrder: 0
        )
        startGeneration(
            transcript: transcript,
            transcriptionId: summary.transcriptionId,
            prompt: prompt,
            extraInstructions: summary.extraInstructions
        )
    }

    public func autoSummarize(transcript: String, transcriptionId: UUID) {
        guard transcript.count > Self.autoSummaryTranscriptLengthThreshold else { return }
        startGeneration(
            transcript: transcript,
            transcriptionId: transcriptionId,
            prompt: Prompt.defaultSummaryPrompt,
            extraInstructions: nil
        )
    }

    public func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        isStreaming = false
        streamingContent = ""
        streamingSummaryID = nil
        streamingPromptName = ""
    }

    private func startGeneration(
        transcript: String,
        transcriptionId: UUID,
        prompt: Prompt,
        extraInstructions: String?
    ) {
        guard let llmService, !isStreaming else { return }

        currentTranscriptionID = transcriptionId
        errorMessage = nil
        isStreaming = true
        streamingContent = ""
        let summaryID = UUID()
        streamingSummaryID = summaryID
        streamingPromptName = prompt.name

        let systemPrompt = assembledSystemPrompt(prompt: prompt, extraInstructions: extraInstructions)
        let targetTranscriptionID = transcriptionId
        streamingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let stream = llmService.summarizeStream(transcript: transcript, systemPrompt: systemPrompt)
                for try await token in stream {
                    streamingContent += token
                }
                guard !Task.isCancelled else { return }

                let timestamp = Date()
                let summary = Summary(
                    id: summaryID,
                    transcriptionId: targetTranscriptionID,
                    promptName: prompt.name,
                    promptContent: prompt.content,
                    extraInstructions: extraInstructions,
                    content: streamingContent,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
                let existing = summaries.first(where: {
                    $0.transcriptionId == targetTranscriptionID && $0.promptName == prompt.name
                })
                try summaryRepo?.replace(summary, deletingExistingID: existing?.id)
                try transcriptionRepo?.updateSummary(id: targetTranscriptionID, summary: summary.content)
                onLegacySummaryChanged?(targetTranscriptionID, summary.content)

                isStreaming = false
                streamingSummaryID = nil
                streamingPromptName = ""
                streamingContent = ""

                if currentTranscriptionID == targetTranscriptionID {
                    if let existing {
                        if badgedSummaryID == existing.id { badgedSummaryID = nil }
                        summaries.removeAll { $0.id == existing.id }
                    }
                    summaries.insert(summary, at: 0)
                }
                if let existing {
                    onDeletedSummary?(existing.id)
                }
                onSummariesChanged?(targetTranscriptionID, true)
                onSelectSummaryTab?(summary.id)
                if shouldShowBadge?() ?? true {
                    badgedSummaryID = summary.id
                }
            } catch is CancellationError {
                cancelStreaming()
            } catch {
                logger.error("Failed to generate summary error=\(error.localizedDescription, privacy: .public)")
                isStreaming = false
                streamingSummaryID = nil
                streamingPromptName = ""
                streamingContent = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    private func assembledSystemPrompt(prompt: Prompt?, extraInstructions: String?) -> String {
        let trimmedInstructions = extraInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prompt {
            guard let trimmedInstructions, !trimmedInstructions.isEmpty else {
                return prompt.content
            }
            return prompt.content + "\n\n" + trimmedInstructions
        }

        if let trimmedInstructions, !trimmedInstructions.isEmpty {
            return """
                You are a helpful assistant that processes transcripts. Follow the user's instructions below.

                \(trimmedInstructions)
                """
        }

        return Prompt.defaultSummaryPrompt.content
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
