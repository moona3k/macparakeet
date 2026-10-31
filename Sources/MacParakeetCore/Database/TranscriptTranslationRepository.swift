import Foundation
import GRDB

public protocol TranscriptTranslationRepositoryProtocol: Sendable {
    /// Saves a translation, replacing any existing one for the same
    /// transcript and language.
    func save(_ translation: TranscriptTranslation) throws
    func fetchAll(transcriptionId: UUID) throws -> [TranscriptTranslation]
    func fetch(transcriptionId: UUID, languageCode: String) throws -> TranscriptTranslation?
    func delete(id: UUID) throws -> Bool
    func deleteAll(transcriptionId: UUID) throws
}

public final class TranscriptTranslationRepository: TranscriptTranslationRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ translation: TranscriptTranslation) throws {
        try dbQueue.write { db in
            try TranscriptTranslation
                .filter(TranscriptTranslation.Columns.transcriptionId == translation.transcriptionId)
                .filter(TranscriptTranslation.Columns.languageCode == translation.languageCode)
                .filter(TranscriptTranslation.Columns.id != translation.id)
                .deleteAll(db)
            try translation.save(db)
        }
    }

    public func fetchAll(transcriptionId: UUID) throws -> [TranscriptTranslation] {
        try dbQueue.read { db in
            try TranscriptTranslation
                .filter(TranscriptTranslation.Columns.transcriptionId == transcriptionId)
                .order(TranscriptTranslation.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    public func fetch(transcriptionId: UUID, languageCode: String) throws -> TranscriptTranslation? {
        try dbQueue.read { db in
            try TranscriptTranslation
                .filter(TranscriptTranslation.Columns.transcriptionId == transcriptionId)
                .filter(TranscriptTranslation.Columns.languageCode == languageCode)
                .fetchOne(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try TranscriptTranslation.deleteOne(db, key: id)
        }
    }

    public func deleteAll(transcriptionId: UUID) throws {
        _ = try dbQueue.write { db in
            try TranscriptTranslation
                .filter(TranscriptTranslation.Columns.transcriptionId == transcriptionId)
                .deleteAll(db)
        }
    }
}
