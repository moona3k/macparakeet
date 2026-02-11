import Foundation
import GRDB

public protocol DictationRepositoryProtocol: Sendable {
    func save(_ dictation: Dictation) throws
    func fetch(id: UUID) throws -> Dictation?
    func fetchAll(limit: Int?) throws -> [Dictation]
    func search(query: String, limit: Int?) throws -> [Dictation]
    func delete(id: UUID) throws -> Bool
    func deleteAll() throws
    func clearMissingAudioPaths() throws
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
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }

            // Use LIKE for substring matching (users expect "keet" to find "MacParakeet")
            let likePattern = "%\(trimmed)%"
            let sql: String
            if let limit {
                sql = """
                    SELECT * FROM dictations
                    WHERE rawTranscript LIKE ? OR cleanTranscript LIKE ?
                    ORDER BY createdAt DESC
                    LIMIT ?
                """
                return try Dictation.fetchAll(db, sql: sql, arguments: [likePattern, likePattern, limit])
            } else {
                sql = """
                    SELECT * FROM dictations
                    WHERE rawTranscript LIKE ? OR cleanTranscript LIKE ?
                    ORDER BY createdAt DESC
                """
                return try Dictation.fetchAll(db, sql: sql, arguments: [likePattern, likePattern])
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

    public func clearMissingAudioPaths() throws {
        try dbQueue.write { db in
            let dictations = try Dictation
                .filter(Dictation.Columns.audioPath != nil)
                .fetchAll(db)

            for var dictation in dictations {
                guard let path = dictation.audioPath,
                      !FileManager.default.fileExists(atPath: path) else { continue }
                dictation.audioPath = nil
                try dictation.update(db)
            }
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
