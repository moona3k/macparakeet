import Foundation
import GRDB

public protocol DictationRepositoryProtocol: Sendable {
    func save(_ dictation: Dictation) throws
    func fetch(id: UUID) throws -> Dictation?
    func fetchAll(limit: Int?) throws -> [Dictation]
    func search(query: String, limit: Int?) throws -> [Dictation]
    func delete(id: UUID) throws -> Bool
    func deleteAll() throws
    func deleteEmpty() throws -> Int
    func stats() throws -> DictationStats
}

public struct DictationStats: Sendable {
    public let totalCount: Int
    public let totalDurationMs: Int

    public init(totalCount: Int, totalDurationMs: Int) {
        self.totalCount = totalCount
        self.totalDurationMs = totalDurationMs
    }
}

public final class DictationRepository: DictationRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ dictation: Dictation) throws {
        try dbQueue.write { db in
            try dictation.save(db)
        }
    }

    public func fetch(id: UUID) throws -> Dictation? {
        try dbQueue.read { db in
            try Dictation.fetchOne(db, key: id)
        }
    }

    public func fetchAll(limit: Int? = nil) throws -> [Dictation] {
        try dbQueue.read { db in
            var request = Dictation
                .order(Dictation.Columns.createdAt.desc)
            if let limit {
                request = request.limit(limit)
            }
            return try request.fetchAll(db)
        }
    }

    public func search(query: String, limit: Int? = nil) throws -> [Dictation] {
        try dbQueue.read { db in
            let pattern = FTS5Pattern(matchingAnyTokenIn: query)
            guard let pattern else { return [] }

            let sql: String
            if let limit {
                sql = """
                    SELECT dictations.* FROM dictations
                    JOIN dictations_fts ON dictations_fts.rowid = dictations.rowid
                    WHERE dictations_fts MATCH ?
                    ORDER BY dictations.createdAt DESC
                    LIMIT ?
                """
                return try Dictation.fetchAll(db, sql: sql, arguments: [pattern.rawPattern, limit])
            } else {
                sql = """
                    SELECT dictations.* FROM dictations
                    JOIN dictations_fts ON dictations_fts.rowid = dictations.rowid
                    WHERE dictations_fts MATCH ?
                    ORDER BY dictations.createdAt DESC
                """
                return try Dictation.fetchAll(db, sql: sql, arguments: [pattern.rawPattern])
            }
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try Dictation.deleteOne(db, key: id)
        }
    }

    public func deleteAll() throws {
        try dbQueue.write { db in
            _ = try Dictation.deleteAll(db)
        }
    }

    public func deleteEmpty() throws -> Int {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM dictations WHERE TRIM(rawTranscript) = '' OR rawTranscript IS NULL"
            )
            return db.changesCount
        }
    }

    public func stats() throws -> DictationStats {
        try dbQueue.read { db in
            let count = try Dictation.fetchCount(db)
            let totalDuration = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(durationMs), 0) FROM dictations"
            ) ?? 0
            return DictationStats(totalCount: count, totalDurationMs: totalDuration)
        }
    }
}
