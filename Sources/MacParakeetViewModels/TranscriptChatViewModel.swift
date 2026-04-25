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
    private static let storageUnavailableMessage = "Chat storage is unavailable. Please relaunch."

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
    private var cliConfigStore: LocalCLIConfigStore?
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
        conversationRepo: ChatConversationRepositoryProtocol? = nil,
        cliConfigStore: LocalCLIConfigStore = LocalCLIConfigStore()
    ) {
        self.llmService = llmService
        self.transcriptText = transcriptText
        self.transcriptionRepo = transcriptionRepo
        self.configStore = configStore
        self.conversationRepo = conversationRepo
        self.cliConfigStore = cliConfigStore
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

    /// Updates the LLM service reference (e.g., when provider config changes).
    /// Passes `nil` to disable chat when LLM is unconfigured.
    public func updateLLMService(_ service: LLMServiceProtocol?) {
        cancelStreaming()
        self.llmService = service
        refreshModelInfo()
    }

    /// - Parameter richPrompt: Optional expanded prompt sent to the LLM in place of
    ///   the visible `inputText`. Used by pills where the label is short ("Tell me
    ///   more") but the actual prompt deserves to be more comprehensive. The
    ///   user-visible bubble and persisted history both show `inputText`.
    public func sendMessage(richPrompt: String? = nil) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, let llmService else { return }
        let llmQuestion: String
        if let rich = richPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !rich.isEmpty {
            llmQuestion = rich
        } else {
            llmQuestion = text
        }

        // Live in-memory mode: no transcriptionId + no conversationRepo means we are
        // chatting against a not-yet-finalized transcript (e.g. an in-flight meeting).
        // Skip persistence; promote to a real ChatConversation later via
        // bindPersistedConversation(transcriptionId:transcriptionRepo:conversationRepo:).
        let isLiveInMemoryMode = (transcriptionId == nil && conversationRepo == nil)

        // Lazy conversation creation on first message (skipped in live in-memory mode)
        if currentConversation == nil && !isLiveInMemoryMode {
            guard let transcriptionId else {
                errorMessage = "Chat is unavailable until a transcript is loaded."
                return
            }
            guard let conversationRepo else {
                logger.error("Missing conversationRepo in sendMessage")
                errorMessage = Self.storageUnavailableMessage
                return
            }
            let title = String(text.prefix(50))
            let conversation = ChatConversation(transcriptionId: transcriptionId, title: title)
            do {
                try conversationRepo.save(conversation)
                currentConversation = conversation
                conversations.insert(conversation, at: 0)
            } catch {
                logger.error("Failed to save new conversation error=\(error.localizedDescription, privacy: .public)")
                errorMessage = "Failed to create conversation"
                return
            }
        }

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

        // Capture context so the task can persist independently if detached (e.g. user clicks New Chat)
        let capturedConversationId = currentConversation?.id
        let capturedHistory = chatHistory
        let repo = conversationRepo

        streamingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""
            do {
                let stream = llmService.chatStream(
                    question: llmQuestion,
                    transcript: transcript,
                    history: historyForRequest
                )
                for try await token in stream {
                    accumulated += token
                    // UI update — silently no-ops if message was removed (detached)
                    if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[idx].content = accumulated
                    }
                }

                // Explicit cancellation (Stop button) — discard partial response
                guard !Task.isCancelled else {
                    if streamingAssistantID == assistantID {
                        removeStreamingAssistantMessage()
                        isStreaming = false
                    }
                    return
                }

                let assistantMsg = ChatMessage(role: .assistant, content: accumulated)

                if streamingAssistantID == assistantID {
                    // Still the active task — normal UI update and persistence
                    if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[idx].isStreaming = false
                    }
                    chatHistory.append(assistantMsg)
                    persistChatMessages()
                    streamingAssistantID = nil
                    isStreaming = false
                } else if let convId = capturedConversationId, !accumulated.isEmpty {
                    // Detached — user switched away. Persist directly to repo.
                    // Only write if the conversation hasn't been modified since detach,
                    // otherwise we'd overwrite newer messages (e.g. user navigated back and sent more).
                    let currentMessages = conversations.first(where: { $0.id == convId })?.messages
                    if currentMessages == nil || currentMessages == capturedHistory {
                        var updatedHistory = capturedHistory
                        updatedHistory.append(assistantMsg)
                        try? repo?.updateMessages(id: convId, messages: updatedHistory)
                        if let idx = conversations.firstIndex(where: { $0.id == convId }) {
                            conversations[idx].messages = updatedHistory
                            conversations[idx].updatedAt = Date()
                        }
                    }
                }
            } catch is CancellationError {
                // Cancellation is expected (Stop button, provider change) — don't surface as error
                if streamingAssistantID == assistantID {
                    removeStreamingAssistantMessage()
                    isStreaming = false
                }
            } catch {
                if streamingAssistantID == assistantID {
                    removeStreamingAssistantMessage()
                    isStreaming = false
                    errorMessage = error.localizedDescription
                }
            }
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

    /// Updates the transcript text without clearing chat history. Use during a live
    /// recording where the rolling transcript grows across many ticks; each new send
    /// should run against the latest text without losing prior turns.
    public func updateTranscriptText(_ text: String) {
        transcriptText = text
    }

    /// Promotes an in-memory live chat (no transcriptionId, no conversationRepo)
    /// into a persisted `ChatConversation` linked to a finalized transcription.
    /// Call this once after `sendMessage()` was used in live in-memory mode and the
    /// recording has been transcribed and saved. Existing in-memory `chatHistory` is
    /// flushed to the new conversation in one repo write.
    public func bindPersistedConversation(
        transcriptionId: UUID,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        conversationRepo: ChatConversationRepositoryProtocol
    ) {
        self.transcriptionId = transcriptionId
        self.transcriptionRepo = transcriptionRepo
        self.conversationRepo = conversationRepo

        // Nothing to persist, or already bound to a conversation.
        guard !chatHistory.isEmpty, currentConversation == nil else {
            return
        }

        let firstUser = chatHistory.first(where: { $0.role == .user })?.content ?? "Meeting chat"
        let title = String(firstUser.prefix(50))
        let conversation = ChatConversation(transcriptionId: transcriptionId, title: title)

        do {
            try conversationRepo.save(conversation)
            try conversationRepo.updateMessages(id: conversation.id, messages: chatHistory)
            var stored = conversation
            stored.messages = chatHistory
            currentConversation = stored
            conversations.insert(stored, at: 0)
            notifyConversationsChanged()
        } catch {
            logger.error("Failed to promote live chat error=\(error.localizedDescription, privacy: .public)")
            errorMessage = "Failed to save chat history."
        }
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

        guard let conversationRepo else {
            logger.error("Missing conversationRepo in loadTranscript")
            messages.removeAll()
            chatHistory.removeAll()
            conversations.removeAll()
            currentConversation = nil
            errorMessage = Self.storageUnavailableMessage
            inputText = ""
            return
        }

        // Load conversations from repo
        do {
            try conversationRepo.deleteEmpty(transcriptionId: transcriptionId)
            conversations = try conversationRepo.fetchAll(transcriptionId: transcriptionId)
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

        notifyConversationsChanged()
    }

    // MARK: - Multi-Conversation

    public func newChat() {
        detachCurrentStreaming()
        discardEmptyCurrentConversation()

        messages.removeAll()
        chatHistory.removeAll()
        errorMessage = nil
        inputText = ""
        currentConversation = nil

        Telemetry.send(.chatConversationCreated)
        notifyConversationsChanged()
    }

    public func switchConversation(_ conversation: ChatConversation) {
        detachCurrentStreaming()
        discardEmptyCurrentConversation()

        loadConversationMessages(conversation)
        errorMessage = nil
        inputText = ""
    }

    public func deleteConversation(_ conversation: ChatConversation) {
        if currentConversation?.id == conversation.id {
            cancelStreaming()
        }

        guard let conversationRepo else {
            logger.error("Missing conversationRepo in deleteConversation")
            errorMessage = Self.storageUnavailableMessage
            return
        }

        do {
            _ = try conversationRepo.delete(id: conversation.id)
        } catch {
            logger.error("Failed to delete conversation error=\(error.localizedDescription, privacy: .public)")
            errorMessage = "Failed to delete conversation."
            return
        }

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
        cancelStreaming()

        // Delete all conversations for this transcript
        if let transcriptionId {
            guard let conversationRepo else {
                logger.error("Missing conversationRepo in clearHistory")
                errorMessage = Self.storageUnavailableMessage
                return
            }

            do {
                try conversationRepo.deleteAll(transcriptionId: transcriptionId)
            } catch {
                logger.error("Failed to clear conversations error=\(error.localizedDescription, privacy: .public)")
                errorMessage = "Failed to clear chat history."
                return
            }

            conversations.removeAll()
        }

        messages.removeAll()
        chatHistory.removeAll()
        errorMessage = nil
        inputText = ""
        currentConversation = nil

        notifyConversationsChanged()
    }

    // MARK: - Private

    /// Disowns the current streaming task without cancelling.
    /// The task continues in the background and persists to DB when done.
    private func detachCurrentStreaming() {
        streamingTask = nil
        isStreaming = false
        removeStreamingAssistantMessage()
    }

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

    private func discardEmptyCurrentConversation() {
        guard let current = currentConversation,
              current.messages == nil || current.messages?.isEmpty == true else { return }

        guard let conversationRepo else {
            logger.error("Missing conversationRepo in discardEmptyCurrentConversation")
            errorMessage = Self.storageUnavailableMessage
            return
        }

        do {
            _ = try conversationRepo.delete(id: current.id)
        } catch {
            logger.error("Failed to discard empty conversation error=\(error.localizedDescription, privacy: .public)")
            return
        }

        conversations.removeAll { $0.id == current.id }
    }

    private func persistChatMessages() {
        guard let currentConversation else { return }
        guard let conversationRepo else {
            logger.error("Missing conversationRepo in persistChatMessages")
            return
        }
        let toSave = chatHistory.isEmpty ? nil : chatHistory
        do {
            try conversationRepo.updateMessages(id: currentConversation.id, messages: toSave)
            // Update the local copy
            self.currentConversation?.messages = toSave
            if let idx = conversations.firstIndex(where: { $0.id == currentConversation.id }) {
                conversations[idx].messages = toSave
                conversations[idx].updatedAt = Date()
                // Move to front so most-recently-updated stays first
                if idx != 0 {
                    let updated = conversations.remove(at: idx)
                    conversations.insert(updated, at: 0)
                }
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
