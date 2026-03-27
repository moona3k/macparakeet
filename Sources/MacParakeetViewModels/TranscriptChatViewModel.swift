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
    public var onConversationsChanged: ((UUID, Bool) -> Void)?
    public var onModelChanged: (() -> Void)?

    // Multi-conversation state
    public var conversations: [ChatConversation] = []
    public var currentConversation: ChatConversation?
    public var showConversationPicker: Bool = false

    // Model selection state
    public var currentModelName: String = ""
    public var currentProviderID: LLMProviderID?
    public var availableModels: [String] = []

    private var llmService: LLMServiceProtocol?
    private var configStore: LLMConfigStoreProtocol?
    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    private var conversationRepo: ChatConversationRepositoryProtocol?
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
        configStore: LLMConfigStoreProtocol? = nil,
        conversationRepo: ChatConversationRepositoryProtocol? = nil
    ) {
        self.llmService = llmService
        self.transcriptText = transcriptText
        self.transcriptionRepo = transcriptionRepo
        self.configStore = configStore
        self.conversationRepo = conversationRepo
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

        // Lazy conversation creation on first message
        if currentConversation == nil {
            guard let transcriptionId else { return }
            let title = String(text.prefix(50))
            var conversation = ChatConversation(transcriptionId: transcriptionId, title: title)
            do {
                try conversationRepo?.save(conversation)
            } catch {
                logger.error("Failed to save new conversation error=\(error.localizedDescription, privacy: .public)")
            }
            currentConversation = conversation
            conversations.insert(conversation, at: 0)
        }

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

    public func loadTranscript(_ text: String, transcriptionId: UUID?) {
        cancelStreaming()
        self.transcriptText = text
        self.transcriptionId = transcriptionId
        self.streamingAssistantID = nil

        guard let transcriptionId else {
            messages.removeAll()
            chatHistory.removeAll()
            conversations.removeAll()
            currentConversation = nil
            errorMessage = nil
            inputText = ""
            return
        }

        // Load conversations from repo
        do {
            try conversationRepo?.deleteEmpty(transcriptionId: transcriptionId)
            conversations = try conversationRepo?.fetchAll(transcriptionId: transcriptionId) ?? []
        } catch {
            logger.error("Failed to load conversations error=\(error.localizedDescription, privacy: .public)")
            conversations = []
        }

        if let mostRecent = conversations.first {
            loadConversationMessages(mostRecent)
        } else {
            messages.removeAll()
            chatHistory.removeAll()
            currentConversation = nil
        }

        errorMessage = nil
        inputText = ""
    }

    // MARK: - Multi-Conversation

    public func newChat() {
        cancelStreaming()

        // If current conversation has no messages, delete it
        if let current = currentConversation, current.messages == nil || current.messages?.isEmpty == true {
            _ = try? conversationRepo?.delete(id: current.id)
            conversations.removeAll { $0.id == current.id }
        }

        messages.removeAll()
        chatHistory.removeAll()
        errorMessage = nil
        inputText = ""
        currentConversation = nil

        notifyConversationsChanged()
    }

    public func switchConversation(_ conversation: ChatConversation) {
        cancelStreaming()

        // Clean up empty current conversation
        if let current = currentConversation, current.messages == nil || current.messages?.isEmpty == true {
            _ = try? conversationRepo?.delete(id: current.id)
            conversations.removeAll { $0.id == current.id }
        }

        loadConversationMessages(conversation)
        errorMessage = nil
        inputText = ""
    }

    public func deleteConversation(_ conversation: ChatConversation) {
        _ = try? conversationRepo?.delete(id: conversation.id)
        conversations.removeAll { $0.id == conversation.id }

        if currentConversation?.id == conversation.id {
            if let next = conversations.first {
                loadConversationMessages(next)
            } else {
                messages.removeAll()
                chatHistory.removeAll()
                currentConversation = nil
            }
        }

        notifyConversationsChanged()
    }

    /// Clears all conversations for the current transcript (used when retranscribing).
    public func clearHistory() {
        messages.removeAll()
        chatHistory.removeAll()
        errorMessage = nil
        inputText = ""

        // Delete all conversations for this transcript
        if let transcriptionId {
            for conv in conversations {
                _ = try? conversationRepo?.delete(id: conv.id)
            }
            conversations.removeAll()
        }
        currentConversation = nil

        notifyConversationsChanged()
    }

    // MARK: - Private

    private func loadConversationMessages(_ conversation: ChatConversation) {
        currentConversation = conversation
        if let chatMessages = conversation.messages, !chatMessages.isEmpty {
            messages = chatMessages.map { msg in
                ChatDisplayMessage(role: msg.role, content: msg.content)
            }
            chatHistory = chatMessages
        } else {
            messages.removeAll()
            chatHistory.removeAll()
        }
    }

    private func persistChatMessages() {
        guard let currentConversation else { return }
        let toSave = chatHistory.isEmpty ? nil : chatHistory
        do {
            try conversationRepo?.updateMessages(id: currentConversation.id, messages: toSave)
            // Update the local copy
            self.currentConversation?.messages = toSave
            if let idx = conversations.firstIndex(where: { $0.id == currentConversation.id }) {
                conversations[idx].messages = toSave
                conversations[idx].updatedAt = Date()
            }
        } catch {
            logger.error("Failed to persist chat messages error=\(error.localizedDescription, privacy: .public)")
        }
        notifyConversationsChanged()
    }

    private func notifyConversationsChanged() {
        guard let transcriptionId else { return }
        let hasConvs = !conversations.isEmpty
        onConversationsChanged?(transcriptionId, hasConvs)
    }

    private func removeStreamingAssistantMessage() {
        guard let streamingAssistantID else { return }
        if let idx = messages.firstIndex(where: { $0.id == streamingAssistantID }) {
            messages.remove(at: idx)
        }
        self.streamingAssistantID = nil
    }
}
