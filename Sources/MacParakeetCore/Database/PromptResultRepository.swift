import Foundation
import GRDB

public protocol PromptResultRepositoryProtocol: Sendable {
    func save(_ promptResult: PromptResult) throws
    func replace(_ promptResult: PromptResult, deletingExistingID: UUID?) throws
    func fetchAll(transcriptionId: UUID) throws -> [PromptResult]
    func delete(id: UUID) throws -> Bool
    func deleteAll(transcriptionId: UUID) throws
    func hasPromptResults(transcriptionId: UUID) throws -> Bool
}

public extension PromptResultRepositoryProtocol {
    func replace(_ promptResult: PromptResult, deletingExistingID: UUID?) throws {
        try save(promptResult)
        if let deletingExistingID, deletingExistingID != promptResult.id {
            _ = try delete(id: deletingExistingID)
        }
    }
}

public final class PromptResultRepository: PromptResultRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ promptResult: PromptResult) throws {
        try dbQueue.write { db in
            try promptResult.save(db)
        }
    }

    public func replace(_ promptResult: PromptResult, deletingExistingID: UUID?) throws {
        try dbQueue.write { db in
            try promptResult.save(db)
            if let deletingExistingID, deletingExistingID != promptResult.id {
                _ = try PromptResult.deleteOne(db, key: deletingExistingID)
            }
        }
    }

    public func fetchAll(transcriptionId: UUID) throws -> [PromptResult] {
        try dbQueue.read { db in
            try PromptResult
                .filter(PromptResult.Columns.transcriptionId == transcriptionId)
                .order(PromptResult.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try PromptResult.deleteOne(db, key: id)
        }
    }

    public func deleteAll(transcriptionId: UUID) throws {
        _ = try dbQueue.write { db in
            try PromptResult
                .filter(PromptResult.Columns.transcriptionId == transcriptionId)
                .deleteAll(db)
        }
    }

    public func hasPromptResults(transcriptionId: UUID) throws -> Bool {
        try dbQueue.read { db in
            try !PromptResult
                .filter(PromptResult.Columns.transcriptionId == transcriptionId)
                .isEmpty(db)
        }
    }
}
