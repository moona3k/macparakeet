import Foundation
@testable import MacParakeetCore

// MARK: - MockDictationRepository

final class MockDictationRepository: DictationRepositoryProtocol, @unchecked Sendable {
    var dictations: [Dictation] = []
    var deleteCalledWith: [UUID] = []
    var deleteAllCalled = false
    var deleteHiddenCalled = false
    var savedDictations: [Dictation] = []
    var statsCallCount = 0

    func save(_ dictation: Dictation) throws {
        savedDictations.append(dictation)
        // Also insert/update in the working list
        if let idx = dictations.firstIndex(where: { $0.id == dictation.id }) {
            dictations[idx] = dictation
        } else {
            dictations.append(dictation)
        }
    }

    func fetch(id: UUID) throws -> Dictation? {
        dictations.first(where: { $0.id == id })
    }

    func fetchAll(limit: Int?) throws -> [Dictation] {
        let sorted = dictations.filter { !$0.hidden }.sorted { $0.createdAt > $1.createdAt }
        if let limit { return Array(sorted.prefix(limit)) }
        return sorted
    }

    func search(query: String, limit: Int?) throws -> [Dictation] {
        let filtered = dictations.filter {
            !$0.hidden && (
                $0.rawTranscript.localizedCaseInsensitiveContains(query)
                || ($0.cleanTranscript?.localizedCaseInsensitiveContains(query) ?? false)
            )
        }
        let sorted = filtered.sorted { $0.createdAt > $1.createdAt }
        if let limit { return Array(sorted.prefix(limit)) }
        return sorted
    }

    func delete(id: UUID) throws -> Bool {
        deleteCalledWith.append(id)
        dictations.removeAll { $0.id == id }
        return true
    }

    func deleteAll() throws {
        deleteAllCalled = true
        dictations.removeAll { !$0.hidden }
    }

    func clearMissingAudioPaths() throws {
        // No-op in mock
    }

    func deleteEmpty() throws -> Int {
        let before = dictations.count
        dictations.removeAll {
            !$0.hidden && $0.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return before - dictations.count
    }

    func deleteHidden() throws {
        deleteHiddenCalled = true
        dictations.removeAll { $0.hidden }
    }

    func stats() throws -> DictationStats {
        statsCallCount += 1
        let completed = dictations.filter { $0.status == .completed }
        let totalDuration = completed.reduce(0) { $0 + $1.durationMs }
        let totalWords = completed.reduce(0) { $0 + $1.wordCount }
        let maxDuration = completed.map(\.durationMs).max() ?? 0
        let avgDuration = completed.isEmpty ? 0 : totalDuration / completed.count

        let dates = completed.map(\.createdAt)
        let (streak, thisWeek) = DictationRepository.computeWeeklyStreak(from: dates)

        let visible = completed.filter { !$0.hidden }
        return DictationStats(
            totalCount: completed.count,
            visibleCount: visible.count,
            totalDurationMs: totalDuration,
            totalWords: totalWords,
            longestDurationMs: maxDuration,
            averageDurationMs: avgDuration,
            weeklyStreak: streak,
            dictationsThisWeek: thisWeek
        )
    }
}

// MARK: - MockTranscriptionRepository

final class MockTranscriptionRepository: TranscriptionRepositoryProtocol, @unchecked Sendable {
    var transcriptions: [Transcription] = []
    var deleteCalledWith: [UUID] = []
    var deleteAllCalled = false
    var updateSummaryCalls: [(id: UUID, summary: String?)] = []
    var updateChatMessagesCalls: [(id: UUID, chatMessages: [ChatMessage]?)] = []
    var updateSpeakersCalls: [(id: UUID, speakers: [SpeakerInfo]?)] = []

    func save(_ transcription: Transcription) throws {
        if let idx = transcriptions.firstIndex(where: { $0.id == transcription.id }) {
            transcriptions[idx] = transcription
        } else {
            transcriptions.append(transcription)
        }
    }

    func fetch(id: UUID) throws -> Transcription? {
        transcriptions.first(where: { $0.id == id })
    }

    func fetchAll(limit: Int?) throws -> [Transcription] {
        let sorted = transcriptions.sorted { $0.createdAt > $1.createdAt }
        if let limit { return Array(sorted.prefix(limit)) }
        return sorted
    }

    func fetchCompletedByVideoID(_ videoID: String) throws -> Transcription? {
        transcriptions.first { t in
            t.status == .completed
                && t.sourceURL != nil
                && (t.sourceURL?.contains(videoID) ?? false)
        }
    }

    func delete(id: UUID) throws -> Bool {
        deleteCalledWith.append(id)
        transcriptions.removeAll { $0.id == id }
        return true
    }

    func deleteAll() throws {
        deleteAllCalled = true
        transcriptions.removeAll()
    }

    func updateStatus(id: UUID, status: Transcription.TranscriptionStatus, errorMessage: String?) throws {
        if let idx = transcriptions.firstIndex(where: { $0.id == id }) {
            transcriptions[idx].status = status
            transcriptions[idx].errorMessage = errorMessage
        }
    }

    func updateSummary(id: UUID, summary: String?) throws {
        updateSummaryCalls.append((id: id, summary: summary))
        if let idx = transcriptions.firstIndex(where: { $0.id == id }) {
            transcriptions[idx].summary = summary
            transcriptions[idx].updatedAt = Date()
        }
    }

    func updateChatMessages(id: UUID, chatMessages: [ChatMessage]?) throws {
        updateChatMessagesCalls.append((id: id, chatMessages: chatMessages))
        if let idx = transcriptions.firstIndex(where: { $0.id == id }) {
            transcriptions[idx].chatMessages = chatMessages
            transcriptions[idx].updatedAt = Date()
        }
    }

    func updateSpeakers(id: UUID, speakers: [SpeakerInfo]?) throws {
        updateSpeakersCalls.append((id: id, speakers: speakers))
        if let idx = transcriptions.firstIndex(where: { $0.id == id }) {
            transcriptions[idx].speakers = speakers
            transcriptions[idx].updatedAt = Date()
        }
    }

    func clearStoredAudioPathsForURLTranscriptions() throws {
        for i in transcriptions.indices {
            if transcriptions[i].sourceURL != nil {
                transcriptions[i].filePath = nil
            }
        }
    }
}

// MARK: - MockLaunchAtLoginService

final class MockLaunchAtLoginService: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus
    var setEnabledCalls: [Bool] = []
    var errorToThrow: Error?

    init(status: LaunchAtLoginStatus = .disabled, errorToThrow: Error? = nil) {
        self.status = status
        self.errorToThrow = errorToThrow
    }

    func currentStatus() -> LaunchAtLoginStatus {
        status
    }

    func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginStatus {
        setEnabledCalls.append(enabled)
        if let errorToThrow {
            throw errorToThrow
        }
        status = enabled ? .enabled : .disabled
        return status
    }
}

// MARK: - MockTranscriptionService

actor MockTranscriptionService: TranscriptionServiceProtocol {
    var transcribeResult: Transcription?
    var transcribeError: Error?
    var transcribeCallCount = 0
    var lastFileURL: URL?
    var lastSource: TelemetryTranscriptionSource?
    var transcribeProgressPhases: [TranscriptionProgress] = []
    var transcribeDelayMs: UInt64 = 0
    var transcribeURLCallCount = 0
    var lastURLString: String?
    var transcribeURLProgressPhases: [TranscriptionProgress] = []
    var transcribeURLDelayMs: UInt64 = 0

    func configure(result: Transcription) {
        self.transcribeResult = result
        self.transcribeError = nil
    }

    func configure(error: Error) {
        self.transcribeError = error
        self.transcribeResult = nil
    }

    func configureURLProgress(phases: [TranscriptionProgress]) {
        self.transcribeURLProgressPhases = phases
    }

    func configureProgress(phases: [TranscriptionProgress]) {
        self.transcribeProgressPhases = phases
    }

    func configureDelay(milliseconds: UInt64) {
        self.transcribeDelayMs = milliseconds
    }

    func configureURLDelay(milliseconds: UInt64) {
        self.transcribeURLDelayMs = milliseconds
    }

    func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> Transcription {
        transcribeCallCount += 1
        lastFileURL = fileURL
        lastSource = source

        for phase in transcribeProgressPhases {
            onProgress?(phase)
        }

        if transcribeDelayMs > 0 {
            try await Task.sleep(nanoseconds: transcribeDelayMs * 1_000_000)
        }

        if let error = transcribeError {
            throw error
        }

        return transcribeResult ?? Transcription(
            fileName: fileURL.lastPathComponent,
            rawTranscript: "Mock transcription",
            status: .completed
        )
    }

    func transcribeURL(urlString: String, onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil) async throws -> Transcription {
        transcribeURLCallCount += 1
        lastURLString = urlString

        for phase in transcribeURLProgressPhases {
            onProgress?(phase)
        }

        if transcribeURLDelayMs > 0 {
            try await Task.sleep(nanoseconds: transcribeURLDelayMs * 1_000_000)
        }

        if let error = transcribeError {
            throw error
        }

        return transcribeResult ?? Transcription(
            fileName: "YouTube Video",
            rawTranscript: "Mock transcription",
            status: .completed,
            sourceURL: urlString
        )
    }
}

// MARK: - MockCustomWordRepository

final class MockCustomWordRepository: CustomWordRepositoryProtocol, @unchecked Sendable {
    var words: [CustomWord] = []

    func save(_ word: CustomWord) throws {
        if let idx = words.firstIndex(where: { $0.id == word.id }) {
            words[idx] = word
        } else {
            words.append(word)
        }
    }

    func fetch(id: UUID) throws -> CustomWord? {
        words.first(where: { $0.id == id })
    }

    func fetchAll() throws -> [CustomWord] {
        words.sorted { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
    }

    func fetchEnabled() throws -> [CustomWord] {
        words.filter { $0.isEnabled }
            .sorted { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
    }

    func delete(id: UUID) throws -> Bool {
        let before = words.count
        words.removeAll { $0.id == id }
        return words.count < before
    }

    func deleteAll() throws {
        words.removeAll()
    }
}

// MARK: - MockTextSnippetRepository

final class MockTextSnippetRepository: TextSnippetRepositoryProtocol, @unchecked Sendable {
    var snippets: [TextSnippet] = []
    var incrementedIDs: [Set<UUID>] = []

    func save(_ snippet: TextSnippet) throws {
        if let idx = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[idx] = snippet
        } else {
            snippets.append(snippet)
        }
    }

    func fetch(id: UUID) throws -> TextSnippet? {
        snippets.first(where: { $0.id == id })
    }

    func fetchAll() throws -> [TextSnippet] {
        snippets.sorted { $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending }
    }

    func fetchEnabled() throws -> [TextSnippet] {
        snippets.filter { $0.isEnabled }
            .sorted { $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending }
    }

    func delete(id: UUID) throws -> Bool {
        let before = snippets.count
        snippets.removeAll { $0.id == id }
        return snippets.count < before
    }

    func deleteAll() throws {
        snippets.removeAll()
    }

    func incrementUseCount(ids: Set<UUID>) throws {
        incrementedIDs.append(ids)
        for id in ids {
            if let idx = snippets.firstIndex(where: { $0.id == id }) {
                snippets[idx].useCount += 1
            }
        }
    }
}

// MARK: - MockLLMService

final class MockLLMService: LLMServiceProtocol, @unchecked Sendable {
    var summarizeResult = "Mock summary"
    var chatResult = "Mock chat response"
    var streamTokens: [String] = ["Hello", " world"]
    var streamDelayNs: UInt64 = 0
    var errorToThrow: Error?
    var summarizeCallCount = 0
    var chatCallCount = 0
    var lastChatQuestion: String?
    var lastChatHistory: [ChatMessage]?

    func summarize(transcript: String) async throws -> String {
        summarizeCallCount += 1
        if let error = errorToThrow { throw error }
        return summarizeResult
    }

    func chat(question: String, transcript: String, history: [ChatMessage]) async throws -> String {
        chatCallCount += 1
        if let error = errorToThrow { throw error }
        return chatResult
    }

    func transform(text: String, prompt: String) async throws -> String {
        if let error = errorToThrow { throw error }
        return "Mock transform"
    }

    func summarizeStream(transcript: String) -> AsyncThrowingStream<String, Error> {
        summarizeCallCount += 1
        let tokens = streamTokens
        let error = errorToThrow
        let delay = streamDelayNs
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                for token in tokens {
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    guard !Task.isCancelled else { return }
                    continuation.yield(token)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func chatStream(question: String, transcript: String, history: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        chatCallCount += 1
        lastChatQuestion = question
        lastChatHistory = history
        let tokens = streamTokens
        let error = errorToThrow
        let delay = streamDelayNs
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                for token in tokens {
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    guard !Task.isCancelled else { return }
                    continuation.yield(token)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        let tokens = streamTokens
        return AsyncThrowingStream { continuation in
            let task = Task {
                for token in tokens {
                    if streamDelayNs > 0 {
                        try? await Task.sleep(nanoseconds: streamDelayNs)
                    }
                    guard !Task.isCancelled else { return }
                    continuation.yield(token)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - MockChatConversationRepository

final class MockChatConversationRepository: ChatConversationRepositoryProtocol, @unchecked Sendable {
    var conversations: [ChatConversation] = []
    var saveCalls: [ChatConversation] = []
    var deleteCalls: [UUID] = []
    var deleteEmptyCalls: [UUID] = []
    var updateMessagesCalls: [(id: UUID, messages: [ChatMessage]?)] = []
    var updateTitleCalls: [(id: UUID, title: String)] = []

    func save(_ conversation: ChatConversation) throws {
        saveCalls.append(conversation)
        if let idx = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[idx] = conversation
        } else {
            conversations.append(conversation)
        }
    }

    func fetch(id: UUID) throws -> ChatConversation? {
        conversations.first(where: { $0.id == id })
    }

    func fetchAll(transcriptionId: UUID) throws -> [ChatConversation] {
        conversations
            .filter { $0.transcriptionId == transcriptionId }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func delete(id: UUID) throws -> Bool {
        deleteCalls.append(id)
        let before = conversations.count
        conversations.removeAll { $0.id == id }
        return conversations.count < before
    }

    func deleteEmpty(transcriptionId: UUID) throws {
        deleteEmptyCalls.append(transcriptionId)
        conversations.removeAll {
            $0.transcriptionId == transcriptionId && $0.messages == nil
        }
    }

    func updateMessages(id: UUID, messages: [ChatMessage]?) throws {
        updateMessagesCalls.append((id: id, messages: messages))
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].messages = messages
            conversations[idx].updatedAt = Date()
        }
    }

    func updateTitle(id: UUID, title: String) throws {
        updateTitleCalls.append((id: id, title: title))
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].title = title
            conversations[idx].updatedAt = Date()
        }
    }

    func hasConversations(transcriptionId: UUID) throws -> Bool {
        conversations.contains { $0.transcriptionId == transcriptionId }
    }
}

// MARK: - MockPermissionService

final class MockPermissionService: PermissionServiceProtocol, @unchecked Sendable {
    var microphonePermission: PermissionStatus = .granted
    var accessibilityPermission: Bool = true
    var requestMicResult: Bool = true
    var requestAccessibilityResult: Bool = true

    func checkMicrophonePermission() async -> PermissionStatus {
        microphonePermission
    }

    func requestMicrophonePermission() async -> Bool {
        requestMicResult
    }

    func checkAccessibilityPermission() -> Bool {
        accessibilityPermission
    }

    func requestAccessibilityPermission(prompt: Bool) -> Bool {
        accessibilityPermission = requestAccessibilityResult
        return accessibilityPermission
    }
}
