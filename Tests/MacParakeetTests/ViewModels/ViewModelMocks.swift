import Foundation
@testable import MacParakeetCore

// MARK: - MockDictationRepository

final class MockDictationRepository: DictationRepositoryProtocol, @unchecked Sendable {
    var dictations: [Dictation] = []
    var deleteCalledWith: [UUID] = []
    var deleteAllCalled = false
    var savedDictations: [Dictation] = []

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
        let sorted = dictations.sorted { $0.createdAt > $1.createdAt }
        if let limit { return Array(sorted.prefix(limit)) }
        return sorted
    }

    func search(query: String, limit: Int?) throws -> [Dictation] {
        let filtered = dictations.filter {
            $0.rawTranscript.localizedCaseInsensitiveContains(query)
                || ($0.cleanTranscript?.localizedCaseInsensitiveContains(query) ?? false)
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
        dictations.removeAll()
    }

    func clearMissingAudioPaths() throws {
        // No-op in mock
    }

    func deleteEmpty() throws -> Int {
        let before = dictations.count
        dictations.removeAll { $0.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return before - dictations.count
    }

    func stats() throws -> DictationStats {
        DictationStats(
            totalCount: dictations.count,
            totalDurationMs: dictations.reduce(0) { $0 + $1.durationMs }
        )
    }
}

// MARK: - MockTranscriptionRepository

final class MockTranscriptionRepository: TranscriptionRepositoryProtocol, @unchecked Sendable {
    var transcriptions: [Transcription] = []
    var deleteCalledWith: [UUID] = []
    var deleteAllCalled = false

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
}

// MARK: - MockTranscriptionService

actor MockTranscriptionService: TranscriptionServiceProtocol {
    var transcribeResult: Transcription?
    var transcribeError: Error?
    var transcribeCallCount = 0
    var lastFileURL: URL?
    var transcribeURLCallCount = 0
    var lastURLString: String?

    func configure(result: Transcription) {
        self.transcribeResult = result
        self.transcribeError = nil
    }

    func configure(error: Error) {
        self.transcribeError = error
        self.transcribeResult = nil
    }

    func transcribe(fileURL: URL) async throws -> Transcription {
        transcribeCallCount += 1
        lastFileURL = fileURL

        if let error = transcribeError {
            throw error
        }

        return transcribeResult ?? Transcription(
            fileName: fileURL.lastPathComponent,
            rawTranscript: "Mock transcription",
            status: .completed
        )
    }

    func transcribeURL(urlString: String) async throws -> Transcription {
        transcribeURLCallCount += 1
        lastURLString = urlString

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
