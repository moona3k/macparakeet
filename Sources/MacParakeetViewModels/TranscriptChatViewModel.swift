import Foundation
import MacParakeetCore

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

    private var llmService: LLMServiceProtocol?
    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    private var transcriptionId: UUID?
    private var transcriptText: String = ""
    private var chatHistory: [ChatMessage] = []
    private var streamingTask: Task<Void, Never>?
    private var streamingAssistantID: UUID?

    public var canSendMessage: Bool {
        llmService != nil
    }

    public init() {}

    public func configure(
        llmService: LLMServiceProtocol?,
        transcriptText: String,
        transcriptionRepo: TranscriptionRepositoryProtocol? = nil
    ) {
        self.llmService = llmService
        self.transcriptText = transcriptText
        self.transcriptionRepo = transcriptionRepo
    }

    /// Updates the LLM service reference (e.g., when provider config changes).
    /// Passes `nil` to disable chat when LLM is unconfigured.
    public func updateLLMService(_ service: LLMServiceProtocol?) {
        cancelStreaming()
        self.llmService = service
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
        try? transcriptionRepo?.updateChatMessages(id: transcriptionId, chatMessages: toSave)
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
