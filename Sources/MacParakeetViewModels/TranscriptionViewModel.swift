import Foundation
import MacParakeetCore
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
        case finalizing
    }

    public enum ChatRuntimeStatus: Sendable {
        case unavailable
        case checking
        case cold
        case ready
    }

    public enum ChatMessageRole: String, Sendable {
        case user
        case assistant
    }

    public enum ChatMessageState: Sendable {
        case pending
        case delivered
        case failed
    }

    public struct ChatMessage: Identifiable, Sendable, Equatable {
        public var id: UUID
        public var role: ChatMessageRole
        public var state: ChatMessageState
        public var text: String
        public var createdAt: Date
        public var modelID: String?
        public var durationSeconds: TimeInterval?
        public var errorDescription: String?
        public var groundingNote: String?

        public init(
            id: UUID = UUID(),
            role: ChatMessageRole,
            state: ChatMessageState,
            text: String,
            createdAt: Date = Date(),
            modelID: String? = nil,
            durationSeconds: TimeInterval? = nil,
            errorDescription: String? = nil,
            groundingNote: String? = nil
        ) {
            self.id = id
            self.role = role
            self.state = state
            self.text = text
            self.createdAt = createdAt
            self.modelID = modelID
            self.durationSeconds = durationSeconds
            self.errorDescription = errorDescription
            self.groundingNote = groundingNote
        }
    }

    public var transcriptions: [Transcription] = []
    public var currentTranscription: Transcription? {
        didSet {
            if oldValue?.id != currentTranscription?.id {
                chatInput = ""
                chatErrorMessage = nil
            }
        }
    }
    public var isTranscribing = false
    public var progress: String = ""
    public var transcriptionProgress: Double?
    public private(set) var sourceKind: SourceKind = .localFile
    public private(set) var progressPhase: ProgressPhase = .preparing
    public private(set) var progressHeadline: String = "Preparing transcription pipeline"
    public var errorMessage: String?
    public var isDragging = false
    public var urlInput: String = ""
    public var chatInput: String = ""
    public private(set) var chatRuntimeStatus: ChatRuntimeStatus = .checking
    public private(set) var chatRuntimeStatusDetail: String = "Checking local model state..."
    public private(set) var chatErrorMessage: String?

    public var currentChatMessages: [ChatMessage] {
        guard let id = currentTranscription?.id else { return [] }
        return chatMessagesByTranscriptionID[id] ?? []
    }

    public var isGeneratingCurrentChatResponse: Bool {
        guard let id = currentTranscription?.id else { return false }
        return generatingTranscriptionIDs.contains(id)
    }

    public var canSendChatMessage: Bool {
        guard currentTranscription != nil else { return false }
        let hasText = !chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText && !isGeneratingCurrentChatResponse
    }

    public var isValidURL: Bool {
        YouTubeURLValidator.isYouTubeURL(urlInput)
    }

    private var transcriptionService: TranscriptionServiceProtocol?
    private var transcriptionRepo: TranscriptionRepositoryProtocol?
    private var llmService: (any LLMServiceProtocol)?
    private var activeDropRequestID: UUID?
    private var dropPendingCount = 0
    private var dropAccepted = false
    private var chatMessagesByTranscriptionID: [UUID: [ChatMessage]] = [:]
    private var generatingTranscriptionIDs: Set<UUID> = []
    private var activeChatTaskByTranscriptionID: [UUID: Task<Void, Never>] = [:]
    private static let progressPercentRegex = try! NSRegularExpression(pattern: #"(\d{1,3})(?:\.\d+)?\s*%"#)

    private static let chatGenerationOptions = LLMGenerationOptions(
        temperature: 0.2,
        topP: 0.9,
        maxTokens: 900,
        timeoutSeconds: 75
    )

    public init() {}

    public func configure(
        transcriptionService: TranscriptionServiceProtocol,
        transcriptionRepo: TranscriptionRepositoryProtocol,
        llmService: (any LLMServiceProtocol)? = nil
    ) {
        self.transcriptionService = transcriptionService
        self.transcriptionRepo = transcriptionRepo
        self.llmService = llmService
        loadTranscriptions()
        refreshChatRuntimeStatus()
    }

    public func loadTranscriptions() {
        guard let repo = transcriptionRepo else { return }
        transcriptions = (try? repo.fetchAll(limit: 50)) ?? []
    }

    public func transcribeFile(url: URL) {
        guard let service = transcriptionService else { return }
        beginTranscription(source: .localFile)

        Task {
            do {
                let result = try await service.transcribe(fileURL: url) { [weak self] phase in
                    DispatchQueue.main.async {
                        self?.updateProgress(with: phase)
                    }
                }
                currentTranscription = result
                endTranscription()
                loadTranscriptions()
                if result.id == currentTranscription?.id {
                    chatInput = ""
                    chatErrorMessage = nil
                }
            } catch {
                errorMessage = error.localizedDescription
                endTranscription()
                loadTranscriptions()
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

        beginTranscription(source: .youtubeURL)
        urlInput = ""

        Task {
            do {
                let result = try await service.transcribeURL(urlString: url) { [weak self] phase in
                    DispatchQueue.main.async {
                        self?.updateProgress(with: phase)
                    }
                }
                currentTranscription = result
                endTranscription()
                loadTranscriptions()
                if result.id == currentTranscription?.id {
                    chatInput = ""
                    chatErrorMessage = nil
                }
            } catch {
                errorMessage = error.localizedDescription
                endTranscription()
                loadTranscriptions()
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
                    self.transcribeFile(url: droppedURL)
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
        beginTranscription(source: .localFile)
        currentTranscription = nil

        Task {
            do {
                var result = try await service.transcribe(fileURL: url) { [weak self] phase in
                    DispatchQueue.main.async {
                        self?.updateProgress(with: phase)
                    }
                }
                // Preserve original metadata
                result.fileName = original.fileName
                result.sourceURL = original.sourceURL
                try? transcriptionRepo?.save(result)
                currentTranscription = result
                endTranscription()
                loadTranscriptions()
                chatInput = ""
                chatErrorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                endTranscription()
                loadTranscriptions()
            }
        }
    }

    public func deleteTranscription(_ transcription: Transcription) {
        guard let repo = transcriptionRepo else { return }
        cancelChatGeneration(for: transcription.id)
        chatMessagesByTranscriptionID.removeValue(forKey: transcription.id)
        generatingTranscriptionIDs.remove(transcription.id)

        if transcription.sourceURL != nil, let audioPath = transcription.filePath {
            try? FileManager.default.removeItem(atPath: audioPath)
        }
        _ = try? repo.delete(id: transcription.id)
        if currentTranscription?.id == transcription.id {
            currentTranscription = nil
        }
        loadTranscriptions()
    }

    // MARK: - Transcript Chat

    public func refreshChatRuntimeStatus() {
        guard let llmService else {
            chatRuntimeStatus = .unavailable
            chatRuntimeStatusDetail = "Local chat model unavailable in this runtime."
            return
        }

        chatRuntimeStatus = .checking
        chatRuntimeStatusDetail = "Checking local model state..."

        Task {
            let ready = await llmService.isReady()
            await MainActor.run {
                if ready {
                    self.chatRuntimeStatus = .ready
                    self.chatRuntimeStatusDetail = "Model is loaded and ready."
                } else {
                    self.chatRuntimeStatus = .cold
                    self.chatRuntimeStatusDetail = "Model loads on first question."
                }
            }
        }
    }

    public func suggestedChatPrompts(for transcription: Transcription) -> [String] {
        let basePrompts = [
            "Summarize the key points in 5 bullets.",
            "What action items were discussed?",
            "List blockers and open questions.",
            "Draft a follow-up email from this transcript."
        ]

        guard transcription.sourceURL != nil else {
            return basePrompts
        }

        return [
            "What are the main takeaways from this video?",
            "List the most actionable moments from this transcript.",
            "What risks or cautions were mentioned?",
            "Draft a concise recap I can send to my team."
        ]
    }

    public func clearChat(for transcriptionID: UUID) {
        cancelChatGeneration(for: transcriptionID)
        generatingTranscriptionIDs.remove(transcriptionID)
        chatMessagesByTranscriptionID.removeValue(forKey: transcriptionID)
        if currentTranscription?.id == transcriptionID {
            chatInput = ""
            chatErrorMessage = nil
        }
    }

    public func retryLastFailedQuestion() {
        guard let transcriptionID = currentTranscription?.id,
              let messages = chatMessagesByTranscriptionID[transcriptionID],
              let failedAssistantIndex = messages.lastIndex(where: { $0.role == .assistant && $0.state == .failed })
        else { return }

        let prior = messages[..<failedAssistantIndex]
        guard let userMessage = prior.last(where: { $0.role == .user }) else { return }
        sendChatQuestion(userMessage.text)
    }

    public func sendChatQuestion() {
        sendChatQuestion(chatInput)
    }

    public func sendChatQuestion(_ rawQuestion: String) {
        guard let transcription = currentTranscription else {
            chatErrorMessage = "Select a transcript before asking a question."
            return
        }

        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard !generatingTranscriptionIDs.contains(transcription.id) else { return }
        guard let llmService else {
            chatRuntimeStatus = .unavailable
            chatRuntimeStatusDetail = "Local chat model unavailable in this runtime."
            chatErrorMessage = "Local chat model is unavailable."
            return
        }

        guard let transcriptBody = transcriptBody(for: transcription),
              !transcriptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            chatErrorMessage = "This transcript has no readable text yet."
            return
        }

        chatErrorMessage = nil
        if question == chatInput.trimmingCharacters(in: .whitespacesAndNewlines) {
            chatInput = ""
        }

        let transcriptionID = transcription.id
        let userMessage = ChatMessage(
            role: .user,
            state: .delivered,
            text: question
        )
        let assistantMessage = ChatMessage(
            role: .assistant,
            state: .pending,
            text: "Analyzing transcript locally...",
            groundingNote: "Grounded in this transcript."
        )
        appendChatMessage(userMessage, for: transcriptionID)
        appendChatMessage(assistantMessage, for: transcriptionID)

        generatingTranscriptionIDs.insert(transcriptionID)
        activeChatTaskByTranscriptionID[transcriptionID]?.cancel()

        let context = TranscriptContextAssembler.assemble(transcript: transcriptBody)
        let payload = TranscriptChatPromptComposer.compose(
            question: question,
            transcriptContext: context
        )
        let request = LLMRequest(
            prompt: payload.prompt,
            systemPrompt: payload.defaultSystemPrompt,
            options: Self.chatGenerationOptions
        )

        let assistantMessageID = assistantMessage.id
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await llmService.generate(request: request)
                await MainActor.run {
                    self.updateChatMessage(
                        for: transcriptionID,
                        messageID: assistantMessageID
                    ) { message in
                        message.state = .delivered
                        message.text = response.text
                        message.modelID = response.modelID
                        message.durationSeconds = response.durationSeconds
                        message.errorDescription = nil
                    }
                    self.generatingTranscriptionIDs.remove(transcriptionID)
                    self.activeChatTaskByTranscriptionID[transcriptionID] = nil
                    self.chatRuntimeStatus = .ready
                    self.chatRuntimeStatusDetail = "Model is loaded and ready."
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.removePendingAssistantMessage(for: transcriptionID, messageID: assistantMessageID)
                    self.generatingTranscriptionIDs.remove(transcriptionID)
                    self.activeChatTaskByTranscriptionID[transcriptionID] = nil
                }
            } catch {
                await MainActor.run {
                    self.updateChatMessage(
                        for: transcriptionID,
                        messageID: assistantMessageID
                    ) { message in
                        message.state = .failed
                        message.text = "I couldn't generate an answer right now."
                        message.errorDescription = error.localizedDescription
                    }
                    self.chatErrorMessage = error.localizedDescription
                    self.generatingTranscriptionIDs.remove(transcriptionID)
                    self.activeChatTaskByTranscriptionID[transcriptionID] = nil
                    self.chatRuntimeStatusDetail = "Last request failed. You can retry."
                }
            }
        }

        activeChatTaskByTranscriptionID[transcriptionID] = task
    }

    private func cancelChatGeneration(for transcriptionID: UUID) {
        activeChatTaskByTranscriptionID[transcriptionID]?.cancel()
        activeChatTaskByTranscriptionID[transcriptionID] = nil
    }

    private func appendChatMessage(_ message: ChatMessage, for transcriptionID: UUID) {
        var existing = chatMessagesByTranscriptionID[transcriptionID] ?? []
        existing.append(message)
        chatMessagesByTranscriptionID[transcriptionID] = existing
    }

    private func updateChatMessage(
        for transcriptionID: UUID,
        messageID: UUID,
        mutate: (inout ChatMessage) -> Void
    ) {
        guard var messages = chatMessagesByTranscriptionID[transcriptionID],
              let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        mutate(&messages[index])
        chatMessagesByTranscriptionID[transcriptionID] = messages
    }

    private func removePendingAssistantMessage(for transcriptionID: UUID, messageID: UUID) {
        guard var messages = chatMessagesByTranscriptionID[transcriptionID] else { return }
        messages.removeAll { $0.id == messageID && $0.state == .pending && $0.role == .assistant }
        chatMessagesByTranscriptionID[transcriptionID] = messages
    }

    private func transcriptBody(for transcription: Transcription) -> String? {
        let primary = transcription.cleanTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let primary, !primary.isEmpty { return primary }
        let fallback = transcription.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !fallback.isEmpty { return fallback }
        return nil
    }

    // MARK: - Progress State

    private func beginTranscription(source: SourceKind) {
        sourceKind = source
        isTranscribing = true
        progress = "Preparing..."
        transcriptionProgress = nil
        progressPhase = .preparing
        progressHeadline = Self.headline(for: .preparing)
        errorMessage = nil
    }

    private func endTranscription() {
        isTranscribing = false
        progress = ""
        transcriptionProgress = nil
        progressPhase = .preparing
        progressHeadline = Self.headline(for: .preparing)
    }

    private func updateProgress(with phaseText: String) {
        progress = phaseText
        transcriptionProgress = Self.parseProgressFraction(from: phaseText)
        progressPhase = Self.parsePhase(from: phaseText)
        progressHeadline = Self.headline(for: progressPhase)
    }

    private static func parsePhase(from phaseText: String) -> ProgressPhase {
        let normalized = phaseText.lowercased()
        if normalized.contains("download") {
            return .downloading
        }
        if normalized.contains("convert") {
            return .converting
        }
        if normalized.contains("transcrib") {
            return .transcribing
        }
        if normalized.contains("saving") || normalized.contains("final") {
            return .finalizing
        }
        if normalized.contains("prepar") {
            return .preparing
        }
        return .transcribing
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
        case .finalizing:
            return "Finalizing transcript"
        }
    }

    private static func parseProgressFraction(from phaseText: String) -> Double? {
        let range = NSRange(phaseText.startIndex..., in: phaseText)
        guard let match = progressPercentRegex.firstMatch(in: phaseText, options: [], range: range),
              match.numberOfRanges >= 2,
              let numberRange = Range(match.range(at: 1), in: phaseText),
              let percent = Double(phaseText[numberRange]),
              percent >= 0 else {
            return nil
        }

        return min(percent, 100) / 100
    }
}
