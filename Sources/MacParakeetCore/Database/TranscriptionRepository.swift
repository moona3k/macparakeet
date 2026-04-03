import Foundation
import GRDB

public protocol TranscriptionRepositoryProtocol: Sendable {
    func save(_ transcription: Transcription) throws
    func fetch(id: UUID) throws -> Transcription?
    func fetchAll(limit: Int?) throws -> [Transcription]
    func fetchCompletedByVideoID(_ videoID: String) throws -> Transcription?
    func count() throws -> Int
    func search(query: String, limit: Int?) throws -> [Transcription]
    func delete(id: UUID) throws -> Bool
    func deleteAll() throws
    func updateStatus(id: UUID, status: Transcription.TranscriptionStatus, errorMessage: String?) throws
    func updateSummary(id: UUID, summary: String?) throws
    func updateChatMessages(id: UUID, chatMessages: [ChatMessage]?) throws
    func updateSpeakers(id: UUID, speakers: [SpeakerInfo]?) throws
    func clearStoredAudioPathsForURLTranscriptions() throws
    func updateFavorite(id: UUID, isFavorite: Bool) throws
    func fetchFavorites() throws -> [Transcription]
}

extension TranscriptionRepositoryProtocol {
    public func fetchCompletedByVideoID(_ videoID: String) throws -> Transcription? { nil }
    public func count() throws -> Int { try fetchAll(limit: nil).count }
    public func search(query: String, limit: Int?) throws -> [Transcription] { [] }
    public func clearStoredAudioPathsForURLTranscriptions() throws {}
    public func updateSummary(id: UUID, summary: String?) throws {}
    public func updateChatMessages(id: UUID, chatMessages: [ChatMessage]?) throws {}
    public func updateSpeakers(id: UUID, speakers: [SpeakerInfo]?) throws {}
    public func updateFavorite(id: UUID, isFavorite: Bool) throws {}
    public func fetchFavorites() throws -> [Transcription] { [] }
}

public final class TranscriptionRepository: TranscriptionRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ transcription: Transcription) throws {
        try dbQueue.write { db in
            try transcription.save(db)
        }
    }

    public func fetch(id: UUID) throws -> Transcription? {
        try dbQueue.read { db in
            try Transcription.fetchOne(db, key: id)
        }
    }

    public func fetchAll(limit: Int? = nil) throws -> [Transcription] {
        try dbQueue.read { db in
            var request = Transcription
                .order(Transcription.Columns.createdAt.desc)
            if let limit {
                request = request.limit(limit)
            }
            return try request.fetchAll(db)
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in
            try Transcription.fetchCount(db)
        }
    }

    public func search(query: String, limit: Int? = nil) throws -> [Transcription] {
        try dbQueue.read { db in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }

            let normalizedQuery = UnicodeSearch.makeKey(trimmed)
            let cursor = try Transcription
                .order(Transcription.Columns.createdAt.desc)
                .fetchCursor(db)

            var results: [Transcription] = []
            while let transcription = try cursor.next() {
                guard UnicodeSearch.contains(transcription.fileName, normalizedQuery: normalizedQuery)
                    || (transcription.rawTranscript.map { UnicodeSearch.contains($0, normalizedQuery: normalizedQuery) } ?? false)
                    || (transcription.cleanTranscript.map { UnicodeSearch.contains($0, normalizedQuery: normalizedQuery) } ?? false)
                else { continue }

                results.append(transcription)
                if let limit, results.count >= limit {
                    break
                }
            }
            return results
        }
    }

    public func fetchCompletedByVideoID(_ videoID: String) throws -> Transcription? {
        let trimmed = videoID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Escape LIKE wildcards (% and _) so video IDs containing _ match literally
        let escaped = trimmed
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")

        return try dbQueue.read { db in
            try Transcription
                .filter(Transcription.Columns.sourceURL != nil)
                .filter(Transcription.Columns.status == Transcription.TranscriptionStatus.completed.rawValue)
                .filter(Transcription.Columns.sourceURL.like("%\(escaped)%", escape: "\\"))
                .order(Transcription.Columns.createdAt.desc)
                .fetchOne(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try Transcription.deleteOne(db, key: id)
        }
    }

    public func deleteAll() throws {
        try dbQueue.write { db in
            _ = try Transcription.deleteAll(db)
        }
    }

    public func updateStatus(
        id: UUID,
        status: Transcription.TranscriptionStatus,
        errorMessage: String? = nil
    ) throws {
        try dbQueue.write { db in
            guard var transcription = try Transcription.fetchOne(db, key: id) else { return }
            transcription.status = status
            transcription.errorMessage = errorMessage
            transcription.updatedAt = Date()
            try transcription.update(db)
        }
    }

    public func updateSummary(id: UUID, summary: String?) throws {
        try dbQueue.write { db in
            guard var transcription = try Transcription.fetchOne(db, key: id) else { return }
            transcription.summary = summary
            transcription.updatedAt = Date()
            try transcription.update(db)
        }
    }

    public func updateChatMessages(id: UUID, chatMessages: [ChatMessage]?) throws {
        try dbQueue.write { db in
            guard var transcription = try Transcription.fetchOne(db, key: id) else { return }
            transcription.chatMessages = chatMessages
            transcription.updatedAt = Date()
            try transcription.update(db)
        }
    }

    public func updateSpeakers(id: UUID, speakers: [SpeakerInfo]?) throws {
        try dbQueue.write { db in
            guard var transcription = try Transcription.fetchOne(db, key: id) else { return }
            transcription.speakers = speakers
            transcription.updatedAt = Date()
            try transcription.update(db)
        }
    }

    public func clearStoredAudioPathsForURLTranscriptions() throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE transcriptions SET filePath = NULL WHERE sourceURL IS NOT NULL"
            )
        }
    }

    public func updateFavorite(id: UUID, isFavorite: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE transcriptions SET isFavorite = ?, updatedAt = ? WHERE id = ?",
                arguments: [isFavorite, Date(), id]
            )
        }
    }

    public func fetchFavorites() throws -> [Transcription] {
        try dbQueue.read { db in
            try Transcription
                .filter(Transcription.Columns.isFavorite == true)
                .order(Transcription.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }
}
