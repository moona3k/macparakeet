import Foundation
import GRDB

public protocol SummaryRepositoryProtocol: Sendable {
    func save(_ summary: Summary) throws
    func replace(_ summary: Summary, deletingExistingID: UUID?) throws
    func fetchAll(transcriptionId: UUID) throws -> [Summary]
    func delete(id: UUID) throws -> Bool
    func deleteAll(transcriptionId: UUID) throws
    func hasSummaries(transcriptionId: UUID) throws -> Bool
}

public extension SummaryRepositoryProtocol {
    func replace(_ summary: Summary, deletingExistingID: UUID?) throws {
        try save(summary)
        if let deletingExistingID, deletingExistingID != summary.id {
            _ = try delete(id: deletingExistingID)
        }
    }
}

public final class SummaryRepository: SummaryRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ summary: Summary) throws {
        try dbQueue.write { db in
            try summary.save(db)
        }
    }

    public func replace(_ summary: Summary, deletingExistingID: UUID?) throws {
        try dbQueue.write { db in
            try summary.save(db)
            if let deletingExistingID, deletingExistingID != summary.id {
                _ = try Summary.deleteOne(db, key: deletingExistingID)
            }
        }
    }

    public func fetchAll(transcriptionId: UUID) throws -> [Summary] {
        try dbQueue.read { db in
            try Summary
                .filter(Summary.Columns.transcriptionId == transcriptionId)
                .order(Summary.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try Summary.deleteOne(db, key: id)
        }
    }

    public func deleteAll(transcriptionId: UUID) throws {
        _ = try dbQueue.write { db in
            try Summary
                .filter(Summary.Columns.transcriptionId == transcriptionId)
                .deleteAll(db)
        }
    }

    public func hasSummaries(transcriptionId: UUID) throws -> Bool {
        try dbQueue.read { db in
            try !Summary
                .filter(Summary.Columns.transcriptionId == transcriptionId)
                .isEmpty(db)
        }
    }
}
