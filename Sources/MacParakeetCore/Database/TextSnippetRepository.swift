import Foundation
import GRDB

public protocol TextSnippetRepositoryProtocol: Sendable {
    func save(_ snippet: TextSnippet) throws
    func fetch(id: UUID) throws -> TextSnippet?
    func fetchAll() throws -> [TextSnippet]
    func fetchEnabled() throws -> [TextSnippet]
    func delete(id: UUID) throws -> Bool
    func deleteAll() throws
    func incrementUseCount(ids: Set<UUID>) throws
}

public final class TextSnippetRepository: TextSnippetRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ snippet: TextSnippet) throws {
        try dbQueue.write { db in
            try snippet.save(db)
        }
    }

    public func fetch(id: UUID) throws -> TextSnippet? {
        try dbQueue.read { db in
            try TextSnippet.fetchOne(db, key: id)
        }
    }

    public func fetchAll() throws -> [TextSnippet] {
        try dbQueue.read { db in
            try TextSnippet
                .order(Column("trigger").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }
    }

    public func fetchEnabled() throws -> [TextSnippet] {
        try dbQueue.read { db in
            try TextSnippet
                .filter(Column("isEnabled") == true)
                .order(Column("trigger").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try TextSnippet.deleteOne(db, key: id)
        }
    }

    public func deleteAll() throws {
        try dbQueue.write { db in
            _ = try TextSnippet.deleteAll(db)
        }
    }

    public func incrementUseCount(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            for id in ids {
                if var snippet = try TextSnippet.fetchOne(db, key: id) {
                    snippet.useCount += 1
                    snippet.updatedAt = Date()
                    try snippet.update(db)
                }
            }
        }
    }
}
