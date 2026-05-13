import Foundation
import GRDB

public protocol TransformHistoryRepositoryProtocol: Sendable {
    func save(_ entry: TransformHistoryEntry) throws
    func fetchAll() throws -> [TransformHistoryEntry]
    func fetchRecent(limit: Int) throws -> [TransformHistoryEntry]
    func fetchRecent(transformId: UUID, limit: Int) throws -> [TransformHistoryEntry]
    func fetch(id: UUID) throws -> TransformHistoryEntry?
    func fetch(idPrefix: String) throws -> [TransformHistoryEntry]
    func count() throws -> Int
    func count(transformId: UUID) throws -> Int
    func delete(id: UUID) throws -> Bool
    func deleteAll(transformId: UUID) throws
    func deleteAll() throws
}

public final class TransformHistoryRepository: TransformHistoryRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ entry: TransformHistoryEntry) throws {
        try dbQueue.write { db in
            try entry.save(db)
        }
    }

    public func fetchAll() throws -> [TransformHistoryEntry] {
        try dbQueue.read { db in
            try TransformHistoryEntry
                .order(TransformHistoryEntry.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func fetchRecent(limit: Int = 200) throws -> [TransformHistoryEntry] {
        try dbQueue.read { db in
            try TransformHistoryEntry
                .order(TransformHistoryEntry.Columns.createdAt.desc)
                .limit(max(0, limit))
                .fetchAll(db)
        }
    }

    public func fetchRecent(transformId: UUID, limit: Int = 200) throws -> [TransformHistoryEntry] {
        try dbQueue.read { db in
            try TransformHistoryEntry
                .filter(TransformHistoryEntry.Columns.transformId == transformId)
                .order(TransformHistoryEntry.Columns.createdAt.desc)
                .limit(max(0, limit))
                .fetchAll(db)
        }
    }

    public func fetch(id: UUID) throws -> TransformHistoryEntry? {
        try dbQueue.read { db in
            try TransformHistoryEntry.fetchOne(db, key: id)
        }
    }

    public func fetch(idPrefix: String) throws -> [TransformHistoryEntry] {
        let escapedPrefix = Self.escapeLikePattern(
            idPrefix
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "")
        )
        guard !escapedPrefix.isEmpty else { return [] }
        let pattern = "\(escapedPrefix)%"

        return try dbQueue.read { db in
            try TransformHistoryEntry
                .filter(
                    sql: """
                        (lower(hex(id)) LIKE ? ESCAPE '\\'
                            OR replace(lower(id), '-', '') LIKE ? ESCAPE '\\')
                        """,
                    arguments: StatementArguments([pattern, pattern])
                )
                .order(TransformHistoryEntry.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in
            try TransformHistoryEntry.fetchCount(db)
        }
    }

    public func count(transformId: UUID) throws -> Int {
        try dbQueue.read { db in
            try TransformHistoryEntry
                .filter(TransformHistoryEntry.Columns.transformId == transformId)
                .fetchCount(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try TransformHistoryEntry.deleteOne(db, key: id)
        }
    }

    public func deleteAll(transformId: UUID) throws {
        _ = try dbQueue.write { db in
            try TransformHistoryEntry
                .filter(TransformHistoryEntry.Columns.transformId == transformId)
                .deleteAll(db)
        }
    }

    public func deleteAll() throws {
        _ = try dbQueue.write { db in
            try TransformHistoryEntry.deleteAll(db)
        }
    }

    private static func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
