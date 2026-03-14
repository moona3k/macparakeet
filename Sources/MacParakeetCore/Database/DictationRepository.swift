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
    func deleteHidden() throws
    func stats() throws -> DictationStats
}

public struct DictationStats: Sendable, Equatable {
    public let totalCount: Int
    /// Count of non-hidden (visible) dictations only. Use for UI that operates on visible rows (e.g. "Clear All").
    public let visibleCount: Int
    public let totalDurationMs: Int
    public let totalWords: Int
    public let longestDurationMs: Int
    public let averageDurationMs: Int
    public let weeklyStreak: Int
    public let dictationsThisWeek: Int

    public static let empty = DictationStats(totalCount: 0, visibleCount: 0, totalDurationMs: 0)

    public init(
        totalCount: Int,
        visibleCount: Int = 0,
        totalDurationMs: Int,
        totalWords: Int = 0,
        longestDurationMs: Int = 0,
        averageDurationMs: Int = 0,
        weeklyStreak: Int = 0,
        dictationsThisWeek: Int = 0
    ) {
        self.totalCount = totalCount
        self.visibleCount = visibleCount
        self.totalDurationMs = totalDurationMs
        self.totalWords = totalWords
        self.longestDurationMs = longestDurationMs
        self.averageDurationMs = averageDurationMs
        self.weeklyStreak = weeklyStreak
        self.dictationsThisWeek = dictationsThisWeek
    }
}

// MARK: - DictationStats Computed Properties

public extension DictationStats {
    var isEmpty: Bool { totalCount == 0 }

    /// Average words per minute based on total words and total speaking time.
    var averageWPM: Double {
        let minutes = Double(totalDurationMs) / 60_000
        guard minutes > 0 else { return 0 }
        return Double(totalWords) / minutes
    }

    /// Estimated time saved in milliseconds (typing at 40 WPM vs speaking).
    var timeSavedMs: Int {
        guard totalWords > 0 else { return 0 }
        let typingTimeMs = Int(Double(totalWords) / 40.0 * 60_000)
        return max(0, typingTimeMs - totalDurationMs)
    }

    /// Approximate number of books equivalent (80,000 words per book).
    var booksEquivalent: Double {
        Double(totalWords) / 80_000
    }

    /// Approximate number of emails equivalent (200 words per email).
    var emailsEquivalent: Double {
        Double(totalWords) / 200
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
                .filter(Dictation.Columns.hidden == false)
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
                    WHERE hidden = 0 AND (rawTranscript LIKE ? OR cleanTranscript LIKE ?)
                    ORDER BY createdAt DESC
                    LIMIT ?
                """
                return try Dictation.fetchAll(db, sql: sql, arguments: [likePattern, likePattern, limit])
            } else {
                sql = """
                    SELECT * FROM dictations
                    WHERE hidden = 0 AND (rawTranscript LIKE ? OR cleanTranscript LIKE ?)
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
            try db.execute(sql: "DELETE FROM dictations WHERE hidden = 0")
        }
    }

    public func clearMissingAudioPaths() throws {
        try dbQueue.write { db in
            let dictations = try Dictation
                .filter(Dictation.Columns.audioPath != nil)
                .filter(Dictation.Columns.hidden == false)
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
                sql: "DELETE FROM dictations WHERE hidden = 0 AND (TRIM(rawTranscript) = '' OR rawTranscript IS NULL)"
            )
            return db.changesCount
        }
    }

    public func deleteHidden() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM dictations WHERE hidden = 1")
        }
    }

    public func stats() throws -> DictationStats {
        try dbQueue.read { db in
            // Numeric aggregates in SQL — includes hidden rows for complete stats
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    COUNT(*) AS cnt,
                    SUM(CASE WHEN hidden = 0 THEN 1 ELSE 0 END) AS visibleCnt,
                    COALESCE(SUM(durationMs), 0) AS totalDur,
                    COALESCE(MAX(durationMs), 0) AS maxDur,
                    CASE WHEN COUNT(*) > 0
                        THEN COALESCE(SUM(durationMs), 0) / COUNT(*)
                        ELSE 0
                    END AS avgDur,
                    COALESCE(SUM(wordCount), 0) AS totalWords
                FROM dictations
                WHERE status = 'completed'
                """)

            let count: Int = row?["cnt"] ?? 0
            let visibleCount: Int = row?["visibleCnt"] ?? 0
            let totalDuration: Int = row?["totalDur"] ?? 0
            let maxDuration: Int = row?["maxDur"] ?? 0
            let avgDuration: Int = row?["avgDur"] ?? 0
            let totalWords: Int = row?["totalWords"] ?? 0

            // Weekly streak includes all completed rows (hidden contribute to streak)
            let dates = try Date.fetchAll(
                db,
                sql: "SELECT createdAt FROM dictations WHERE status = 'completed' ORDER BY createdAt DESC"
            )
            let (streak, thisWeek) = Self.computeWeeklyStreak(from: dates)

            return DictationStats(
                totalCount: count,
                visibleCount: visibleCount,
                totalDurationMs: totalDuration,
                totalWords: totalWords,
                longestDurationMs: maxDuration,
                averageDurationMs: avgDuration,
                weeklyStreak: streak,
                dictationsThisWeek: thisWeek
            )
        }
    }

    /// Counts words by splitting on whitespace runs. Exact for any input.
    static func countWords(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Computes the weekly streak and this-week count from an array of distinct dates (descending).
    /// Exposed as static for testability.
    static func computeWeeklyStreak(
        from dates: [Date],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> (streak: Int, thisWeek: Int) {
        guard !dates.isEmpty else { return (0, 0) }

        // Find the start of the current week
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now

        // Count how many dates fall in the current week (cap at now to exclude future-dated rows)
        let thisWeek = dates.filter { $0 >= currentWeekStart && $0 <= now }.count

        // Build a set of week-start dates
        var weekStarts = Set<Date>()
        for date in dates {
            if let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start {
                weekStarts.insert(weekStart)
            }
        }

        // Walk backwards from current week, counting consecutive weeks
        var streak = 0
        var checkWeek = currentWeekStart
        while weekStarts.contains(checkWeek) {
            streak += 1
            guard let prevWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: checkWeek) else { break }
            checkWeek = prevWeek
        }

        return (streak, thisWeek)
    }
}
