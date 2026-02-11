import Foundation
import GRDB

public protocol CustomWordRepositoryProtocol: Sendable {
    func save(_ word: CustomWord) throws
    func fetch(id: UUID) throws -> CustomWord?
    func fetchAll() throws -> [CustomWord]
    func fetchEnabled() throws -> [CustomWord]
    func delete(id: UUID) throws -> Bool
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

    public func deleteAll() throws {
        try dbQueue.write { db in
            _ = try CustomWord.deleteAll(db)
        }
    }
}
