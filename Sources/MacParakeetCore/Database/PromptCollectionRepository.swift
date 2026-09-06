import Foundation
import GRDB

public enum PromptCollectionRepositoryError: Error, LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)
    case invalidOrder
    case collectionNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Collection name can't be empty."
        case .duplicateName(let name):
            return "A prompt collection named \(name) already exists."
        case .invalidOrder:
            return "The collection order must contain every collection exactly once."
        case .collectionNotFound(let id):
            return "Prompt collection \(id) doesn't exist."
        }
    }
}

public protocol PromptCollectionRepositoryProtocol: Sendable {
    func save(_ collection: PromptCollection) throws
    func fetch(id: UUID) throws -> PromptCollection?
    func fetchAll() throws -> [PromptCollection]
    func reorder(ids: [UUID]) throws
    func delete(id: UUID) throws -> Bool
}

public final class PromptCollectionRepository: PromptCollectionRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ collection: PromptCollection) throws {
        try dbQueue.write { db in
            var normalized = collection
            normalized.name = try Self.normalizedName(collection.name)
            normalized.colorToken = Self.normalizedOptional(collection.colorToken)
            normalized.updatedAt = Date()

            let duplicate =
                try PromptCollection
                .filter(sql: "name = ? COLLATE NOCASE", arguments: [normalized.name])
                .filter(PromptCollection.Columns.id != normalized.id)
                .fetchCount(db)
            guard duplicate == 0 else {
                throw PromptCollectionRepositoryError.duplicateName(normalized.name)
            }
            try normalized.save(db)
        }
    }

    public func fetch(id: UUID) throws -> PromptCollection? {
        try dbQueue.read { db in
            try PromptCollection.fetchOne(db, key: id)
        }
    }

    public func fetchAll() throws -> [PromptCollection] {
        try dbQueue.read { db in
            try PromptCollection
                .order(
                    PromptCollection.Columns.sortOrder.asc,
                    PromptCollection.Columns.name.collating(.nocase).asc
                )
                .fetchAll(db)
        }
    }

    /// Replaces the complete user-defined display order atomically.
    ///
    /// Requiring the full set prevents a stale drag-and-drop view from
    /// silently moving or dropping collections created by another process.
    public func reorder(ids: [UUID]) throws {
        try dbQueue.write { db in
            let existing = try UUID.fetchAll(db, sql: "SELECT id FROM prompt_collections")
            guard ids.count == Set(ids).count, Set(ids) == Set(existing) else {
                throw PromptCollectionRepositoryError.invalidOrder
            }

            let now = Date()
            for (index, id) in ids.enumerated() {
                guard var collection = try PromptCollection.fetchOne(db, key: id) else {
                    throw PromptCollectionRepositoryError.invalidOrder
                }
                collection.sortOrder = index
                collection.updatedAt = now
                try collection.update(db)
            }
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            // The schema's ON DELETE SET NULL owns membership cleanup. Prompt
            // rows and their version histories are never deleted here.
            try PromptCollection.deleteOne(db, key: id)
        }
    }

    private static func normalizedName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PromptCollectionRepositoryError.emptyName }
        return trimmed
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// Cross-table operation that changes prompt organization without creating a
/// content version. Collection membership is mutable prompt metadata.
public protocol PromptCollectionAssignmentServiceProtocol: Sendable {
    @discardableResult
    func assign(promptId: UUID, to collectionId: UUID?) throws -> Bool
}

public final class PromptCollectionAssignmentService: PromptCollectionAssignmentServiceProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Assigns an active prompt to one collection, replacing any previous
    /// assignment. Passing nil moves the prompt back to the unfiled group.
    @discardableResult
    public func assign(promptId: UUID, to collectionId: UUID?) throws -> Bool {
        try dbQueue.write { db in
            if let collectionId,
                try PromptCollection.fetchOne(db, key: collectionId) == nil
            {
                throw PromptCollectionRepositoryError.collectionNotFound(collectionId)
            }

            try db.execute(
                sql: """
                    UPDATE prompts
                    SET collectionId = ?, updatedAt = ?
                    WHERE id = ? AND deletedAt IS NULL
                    """,
                arguments: [collectionId, Date(), promptId]
            )
            return db.changesCount > 0
        }
    }
}
