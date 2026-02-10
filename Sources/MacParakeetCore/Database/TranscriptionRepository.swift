import Foundation
import GRDB

public protocol TranscriptionRepositoryProtocol: Sendable {
    func save(_ transcription: Transcription) throws
    func fetch(id: UUID) throws -> Transcription?
    func fetchAll(limit: Int?) throws -> [Transcription]
    func delete(id: UUID) throws -> Bool
    func deleteAll() throws
    func updateStatus(id: UUID, status: Transcription.TranscriptionStatus, errorMessage: String?) throws
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
}
