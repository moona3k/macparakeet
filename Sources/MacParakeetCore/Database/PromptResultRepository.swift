import Foundation
import GRDB

public protocol PromptResultRepositoryProtocol: Sendable {
    func save(_ promptResult: PromptResult) throws
    func replace(_ promptResult: PromptResult, deletingExistingID: UUID?) throws
    func fetchAll(transcriptionId: UUID) throws -> [PromptResult]
    func delete(id: UUID) throws -> Bool
    func deleteAll(transcriptionId: UUID) throws
    func hasPromptResults(transcriptionId: UUID) throws -> Bool
    func count(transcriptionId: UUID) throws -> Int
    func counts(transcriptionIds: [UUID]) throws -> [UUID: Int]
}

public extension PromptResultRepositoryProtocol {
    func replace(_ promptResult: PromptResult, deletingExistingID: UUID?) throws {
        try save(promptResult)
        if let deletingExistingID, deletingExistingID != promptResult.id {
            _ = try delete(id: deletingExistingID)
        }
    }

    func counts(transcriptionIds: [UUID]) throws -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for transcriptionId in Set(transcriptionIds) {
            counts[transcriptionId] = try count(transcriptionId: transcriptionId)
        }
        return counts
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

    public func count(transcriptionId: UUID) throws -> Int {
        try dbQueue.read { db in
            try PromptResult
                .filter(PromptResult.Columns.transcriptionId == transcriptionId)
                .fetchCount(db)
        }
    }

    public func counts(transcriptionIds: [UUID]) throws -> [UUID: Int] {
        let ids = Array(Set(transcriptionIds))
        guard !ids.isEmpty else { return [:] }

        return try dbQueue.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT transcriptionId, COUNT(*) AS count
                    FROM summaries
                    WHERE transcriptionId IN (\(placeholders))
                    GROUP BY transcriptionId
                    """,
                arguments: StatementArguments(ids)
            )

            return rows.reduce(into: [:]) { result, row in
                let transcriptionId: UUID = row["transcriptionId"]
                let count: Int = row["count"]
                result[transcriptionId] = count
            }
        }
    }
}
