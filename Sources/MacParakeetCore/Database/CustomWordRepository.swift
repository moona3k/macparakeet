import Foundation
import GRDB

public protocol CustomWordRepositoryProtocol: Sendable {
    func save(_ word: CustomWord) throws
    func fetch(id: UUID) throws -> CustomWord?
    func fetchAll() throws -> [CustomWord]
    func fetchEnabled() throws -> [CustomWord]
    func delete(id: UUID) throws -> Bool
    func delete(ids: Set<UUID>) async throws -> Int
    func deleteAll() throws
}

public final class CustomWordRepository: CustomWordRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ word: CustomWord) throws {
        try dbQueue.write { db in
            try word.save(db)
        }
    }

    public func fetch(id: UUID) throws -> CustomWord? {
        try dbQueue.read { db in
            try CustomWord.fetchOne(db, key: id)
        }
    }

    public func fetchAll() throws -> [CustomWord] {
        try dbQueue.read { db in
            try CustomWord
                .order(Column("word").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }
    }

    public func fetchEnabled() throws -> [CustomWord] {
        try dbQueue.read { db in
            try CustomWord
                .filter(Column("isEnabled") == true)
                .order(Column("word").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try CustomWord.deleteOne(db, key: id)
        }
    }

    /// Deletes the selected entries atomically and returns the number of rows removed.
    public func delete(ids: Set<UUID>) async throws -> Int {
        guard !ids.isEmpty else { return 0 }

        return try await dbQueue.write { db in
            let keys = Array(ids)
            // Stay below SQLite's parameter limit, while keeping every chunk in one transaction.
            let batchSize = 500
            var deletedCount = 0
            for start in stride(from: 0, to: keys.count, by: batchSize) {
                let end = min(start + batchSize, keys.count)
                deletedCount += try CustomWord.deleteAll(db, keys: keys[start..<end])
            }
            return deletedCount
        }
    }

    public func deleteAll() throws {
        try dbQueue.write { db in
            _ = try CustomWord.deleteAll(db)
        }
    }
}
