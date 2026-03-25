import Foundation
import MacParakeetCore
import OSLog

public struct ChatDisplayMessage: Identifiable, Equatable {
    public let id: UUID
    public let role: ChatMessage.Role
    public var content: String
    public var isStreaming: Bool

    public init(id: UUID = UUID(), role: ChatMessage.Role, content: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
    }
}

@MainActor
@Observable
public final class TranscriptChatViewModel {
    public var messages: [ChatDisplayMessage] = []
    public var inputText: String = ""
    public var isStreaming: Bool = false
    public var errorMessage: String?
    public var onChatMessagesChanged: ((UUID, [ChatMessage]?) -> Void)?
    public var onModelChanged: (() -> Void)?

    // Model selection state
    public var currentModelName: String = ""
    public var currentProviderID: LLMProviderID?
    public var availableModels: [String] = []

    private var llmService: LLMServiceProtocol?
    private var configStore: LLMConfigStoreProtocol?
    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    private var transcriptionId: UUID?
    private var transcriptText: String = ""
    private var chatHistory: [ChatMessage] = []
    private var streamingTask: Task<Void, Never>?
    private var streamingAssistantID: UUID?
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "TranscriptChatViewModel")

    public var canSendMessage: Bool {
        llmService != nil
    }

    public var modelDisplayName: String {
        guard !currentModelName.isEmpty else { return "" }
        // Strip provider prefix for OpenRouter models (e.g. "anthropic/claude-sonnet-4-6" -> "claude-sonnet-4-6")
        if currentProviderID == .openrouter, let slashIndex = currentModelName.firstIndex(of: "/") {
            return String(currentModelName[currentModelName.index(after: slashIndex)...])
        }
        return currentModelName
    }

    public init() {}

    public func configure(
        llmService: LLMServiceProtocol?,
        transcriptText: String,
        transcriptionRepo: TranscriptionRepositoryProtocol? = nil,
        configStore: LLMConfigStoreProtocol? = nil
    ) {
        self.llmService = llmService
        self.transcriptText = transcriptText
        self.transcriptionRepo = transcriptionRepo
        self.configStore = configStore
        refreshModelInfo()
    }

    public func refreshModelInfo() {
        guard let configStore, let config = try? configStore.loadConfig() else {
            currentModelName = ""
            currentProviderID = nil
            availableModels = []
            return
        }
        currentModelName = config.modelName
        currentProviderID = config.id
        var models = LLMSettingsViewModel.suggestedModels(for: config.id)
        if !config.modelName.isEmpty && !models.contains(config.modelName) {
            models.insert(config.modelName, at: 0)
        }
        availableModels = models
    }

    public func selectModel(_ modelName: String) {
        guard let configStore else { return }
        do {
            try configStore.updateModelName(modelName)
            currentModelName = modelName
            onModelChanged?()
        } catch {
            refreshModelInfo()
        }
    }

    /// Updates the LLM service reference (e.g., when provider config changes).
    /// Passes `nil` to disable chat when LLM is unconfigured.
    public func updateLLMService(_ service: LLMServiceProtocol?) {
        cancelStreaming()
        self.llmService = service
        refreshModelInfo()
    }

    public func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, let llmService else { return }

        inputText = ""
        errorMessage = nil

        let userMessage = ChatDisplayMessage(role: .user, content: text)
        messages.append(userMessage)

        // Capture history BEFORE appending user message — buildChatMessages() adds question separately
        let historyForRequest = chatHistory
        chatHistory.append(ChatMessage(role: .user, content: text))
        persistChatMessages()

        let assistantID = UUID()
        let assistantMessage = ChatDisplayMessage(id: assistantID, role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMessage)
        isStreaming = true
        streamingAssistantID = assistantID

        let transcript = transcriptText

        streamingTask = Task {
            var accumulated = ""
            do {
                let stream = llmService.chatStream(
                    question: text,
                    transcript: transcript,
                    history: historyForRequest
                )
                for try await token in stream {
                    accumulated += token
                    if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[idx].content = accumulated
                    }
                }

                guard !Task.isCancelled else { return }

                if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[idx].isStreaming = false
                }

                chatHistory.append(ChatMessage(role: .assistant, content: accumulated))
                persistChatMessages()
            } catch is CancellationError {
                // Cancellation is expected (navigation, provider change) — don't surface as error
                removeStreamingAssistantMessage()
                isStreaming = false
                return
            } catch {
                removeStreamingAssistantMessage()
                errorMessage = error.localizedDescription
            }
            streamingAssistantID = nil
            isStreaming = false
        }
    }

    public func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        isStreaming = false
        removeStreamingAssistantMessage()
    }

    public func updateTranscript(_ text: String) {
        transcriptText = text
        clearHistory()
    }

    public func loadTranscript(_ text: String, transcriptionId: UUID?, chatMessages: [ChatMessage]?) {
        cancelStreaming()
        self.transcriptText = text
        self.transcriptionId = transcriptionId
        self.streamingAssistantID = nil

        if let chatMessages, !chatMessages.isEmpty {
            messages = chatMessages.map { msg in
                ChatDisplayMessage(role: msg.role, content: msg.content)
            }
            chatHistory = chatMessages
        } else {
            messages.removeAll()
            chatHistory.removeAll()
        }
        errorMessage = nil
        inputText = ""
    }

    public func clearHistory() {
        messages.removeAll()
        chatHistory.removeAll()
        errorMessage = nil
        inputText = ""
        persistChatMessages()
    }

    private func persistChatMessages() {
        guard let transcriptionId else { return }
        let toSave = chatHistory.isEmpty ? nil : chatHistory
        do {
            try transcriptionRepo?.updateChatMessages(id: transcriptionId, chatMessages: toSave)
        } catch {
            logger.error("Failed to persist chat messages error=\(error.localizedDescription, privacy: .public)")
        }
        onChatMessagesChanged?(transcriptionId, toSave)
    }

    private func removeStreamingAssistantMessage() {
        guard let streamingAssistantID else { return }
        if let idx = messages.firstIndex(where: { $0.id == streamingAssistantID }) {
            messages.remove(at: idx)
        }
        self.streamingAssistantID = nil
    }
}
