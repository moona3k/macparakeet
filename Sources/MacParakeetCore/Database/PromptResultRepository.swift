import Foundation
import GRDB

public enum PromptResultRepositoryError: LocalizedError, Equatable {
    case conditionalReplacementUnavailable

    public var errorDescription: String? {
        switch self {
        case .conditionalReplacementUnavailable:
            return "This result repository cannot safely replace an edited result."
        }
    }
}

public protocol PromptResultRepositoryProtocol: Sendable {
    func save(_ promptResult: PromptResult) throws
    /// Updates an existing result only if its content still matches the editor's starting text.
    func updateContent(id: UUID, expectedContent: String, content: String, editedAt: Date) throws -> PromptResult?
    func replace(_ promptResult: PromptResult, deletingExistingID: UUID?) throws
    /// Replaces a saved result only when its content and edit timestamp still match the caller's snapshot.
    /// Conformers without atomic replacement inherit a default that throws instead of deleting user edits.
    func replaceIfUnchanged(
        _ replacement: PromptResult,
        deletingExistingID: UUID,
        expectedContent: String,
        expectedContentEditedAt: Date?
    ) throws -> Bool
    func fetchAll(transcriptionId: UUID) throws -> [PromptResult]
    func delete(id: UUID) throws -> Bool
    func deleteAll(transcriptionId: UUID) throws
    func hasPromptResults(transcriptionId: UUID) throws -> Bool
    func count(transcriptionId: UUID) throws -> Int
    func counts(transcriptionIds: [UUID]) throws -> [UUID: Int]
}

public extension PromptResultRepositoryProtocol {
    func replaceIfUnchanged(
        _ replacement: PromptResult,
        deletingExistingID: UUID,
        expectedContent: String,
        expectedContentEditedAt: Date?
    ) throws -> Bool {
        // Keep external conformers source-compatible without risking a
        // non-atomic save-then-delete fallback that could lose user edits.
        throw PromptResultRepositoryError.conditionalReplacementUnavailable
    }

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
            var normalizedResult = promptResult
            normalizedResult.inferenceSettingsSnapshot = try promptResult.inferenceSettingsSnapshot?.validated()
            try normalizedResult.save(db)
        }
    }

    public func updateContent(
        id: UUID,
        expectedContent: String,
        content: String,
        editedAt: Date
    ) throws -> PromptResult? {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE summaries
                    SET content = ?, contentEditedAt = ?, updatedAt = ?
                    WHERE id = ? AND content = ?
                    """,
                arguments: [content, editedAt, editedAt, id, expectedContent]
            )
            guard db.changesCount == 1 else { return nil }
            return try PromptResult.fetchOne(db, key: id)
        }
    }

    public func replace(_ promptResult: PromptResult, deletingExistingID: UUID?) throws {
        try dbQueue.write { db in
            var normalizedResult = promptResult
            normalizedResult.inferenceSettingsSnapshot = try promptResult.inferenceSettingsSnapshot?.validated()
            try normalizedResult.save(db)
            if let deletingExistingID, deletingExistingID != promptResult.id {
                _ = try PromptResult.deleteOne(db, key: deletingExistingID)
            }
        }
    }

    public func replaceIfUnchanged(
        _ replacement: PromptResult,
        deletingExistingID: UUID,
        expectedContent: String,
        expectedContentEditedAt: Date?
    ) throws -> Bool {
        guard replacement.id != deletingExistingID else { return false }

        return try dbQueue.write { db in
            guard let existing = try PromptResult.fetchOne(db, key: deletingExistingID),
                existing.content == expectedContent,
                existing.contentEditedAt == expectedContentEditedAt,
                existing.transcriptionId == replacement.transcriptionId
            else {
                return false
            }

            var normalizedResult = replacement
            normalizedResult.inferenceSettingsSnapshot = try replacement.inferenceSettingsSnapshot?.validated()
            try normalizedResult.insert(db)
            _ = try PromptResult.deleteOne(db, key: deletingExistingID)
            return true
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
