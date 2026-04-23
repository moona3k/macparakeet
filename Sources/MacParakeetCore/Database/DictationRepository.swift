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
    func resetLifetimeStats() throws
}

public struct DictationStats: Sendable, Equatable {
    /// Lifetime count of completed dictations. Survives history deletion (issue #124).
    public let totalCount: Int
    /// Currently-visible (non-hidden) completed dictations. Reflects the user's history right now,
    /// drops to 0 after "Clear All Dictations".
    public let visibleCount: Int
    /// Lifetime sum of dictation durations (ms). Survives history deletion.
    public let totalDurationMs: Int
    /// Lifetime sum of dictated words. Survives history deletion.
    public let totalWords: Int
    /// Lifetime longest single dictation (ms). High-water mark — only ever increases.
    public let longestDurationMs: Int
    /// Lifetime average duration (ms), derived from totalDurationMs / totalCount.
    public let averageDurationMs: Int
    /// Current weekly streak. Derived from existing dictation rows; resets when history is cleared
    /// (intentional — this is "are you on a streak right now?", not a lifetime metric).
    public let weeklyStreak: Int
    /// Dictations completed this calendar week, derived from existing rows.
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

public enum LifetimeStatsError: Error {
    /// Raised when the singleton lifetime_dictation_stats row is missing during a hot-path
    /// UPDATE. The recompute helper is the recovery path; the increment helpers fail loudly
    /// to surface invariant violations (e.g. someone manually truncated the table in tests).
    case singletonMissing
}

public final class DictationRepository: DictationRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ dictation: Dictation) throws {
        try dbQueue.write { db in
            // MUST fetch existing state BEFORE dictation.save(db). The delta path depends on
            // the pre-write durationMs / wordCount / status. Reordering would silently turn
            // every delta-path save into a zero-delta no-op.
            let existing = try Dictation.fetchOne(db, key: dictation.id)
            try dictation.save(db)

            switch (existing?.status, dictation.status) {
            case (.some(.completed), .completed):
                // Mutating an already-counted row (e.g. a future "edit transcript" path).
                // Apply the delta. longestDurationMs is a high-water mark — never decrements.
                let prior = existing!  // guaranteed by .some(.completed) match
                try Self.applyLifetimeDelta(
                    db: db,
                    durationDelta: dictation.durationMs - prior.durationMs,
                    wordDelta: dictation.wordCount - prior.wordCount,
                    newDurationMs: dictation.durationMs
                )
            case (_, .completed):
                // Fresh insert at .completed, or transition (.recording / .processing /
                // .error → .completed). Increment by the full row.
                try Self.incrementLifetimeStats(
                    db: db,
                    durationMs: dictation.durationMs,
                    wordCount: dictation.wordCount
                )
            default:
                break
            }
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

            // Escape LIKE wildcards so literal % and _ in user input are matched verbatim.
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let likePattern = "%\(escaped)%"

            var sql = """
                SELECT * FROM dictations
                WHERE hidden = 0 AND (rawTranscript LIKE ? ESCAPE '\\' OR cleanTranscript LIKE ? ESCAPE '\\')
                ORDER BY createdAt DESC
                """
            var args: [any DatabaseValueConvertible] = [likePattern, likePattern]
            if let limit {
                sql += " LIMIT ?"
                args.append(limit)
            }
            return try Dictation.fetchAll(db, sql: sql, arguments: StatementArguments(args))
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
            // Lifetime totals — survive history deletion (issue #124).
            let lifetime = try Row.fetchOne(db, sql: """
                SELECT totalCount, totalDurationMs, totalWords, longestDurationMs
                FROM lifetime_dictation_stats WHERE id = 1
                """)
            let totalCount: Int = lifetime?["totalCount"] ?? 0
            let totalDuration: Int = lifetime?["totalDurationMs"] ?? 0
            let totalWords: Int = lifetime?["totalWords"] ?? 0
            let longestDuration: Int = lifetime?["longestDurationMs"] ?? 0
            let averageDuration = totalCount > 0 ? totalDuration / totalCount : 0

            // visibleCount reflects what's currently in the user's history.
            let visibleCount: Int = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM dictations
                    WHERE status = 'completed' AND hidden = 0
                    """
            ) ?? 0

            // Weekly streak / this-week derived from current rows (intentionally
            // resets when the user clears history — it's "are you on a streak right
            // now?", not a lifetime metric).
            let dates = try Date.fetchAll(
                db,
                sql: "SELECT createdAt FROM dictations WHERE status = 'completed' ORDER BY createdAt DESC"
            )
            let (streak, thisWeek) = Self.computeWeeklyStreak(from: dates)

            return DictationStats(
                totalCount: totalCount,
                visibleCount: visibleCount,
                totalDurationMs: totalDuration,
                totalWords: totalWords,
                longestDurationMs: longestDuration,
                averageDurationMs: averageDuration,
                weeklyStreak: streak,
                dictationsThisWeek: thisWeek
            )
        }
    }

    // MARK: - Lifetime stats helpers (issue #124)

    /// Hot-path increment for a newly-completed dictation. UPDATE-only — asserts the
    /// singleton row exists; throws `LifetimeStatsError.singletonMissing` if not.
    static func incrementLifetimeStats(
        db: Database,
        durationMs: Int,
        wordCount: Int,
        now: Date = Date()
    ) throws {
        try db.execute(
            sql: """
                UPDATE lifetime_dictation_stats
                SET totalCount        = totalCount + 1,
                    totalDurationMs   = totalDurationMs + ?,
                    totalWords        = totalWords + ?,
                    longestDurationMs = MAX(longestDurationMs, ?),
                    updatedAt         = ?
                WHERE id = 1
                """,
            arguments: [durationMs, wordCount, durationMs, now]
        )
        guard db.changesCount == 1 else { throw LifetimeStatsError.singletonMissing }
    }

    /// Hot-path delta apply for an already-counted row whose duration / wordCount
    /// changed (e.g. a future "edit transcript" feature). Does not touch totalCount.
    /// longestDurationMs is a high-water mark and only ever increases.
    static func applyLifetimeDelta(
        db: Database,
        durationDelta: Int,
        wordDelta: Int,
        newDurationMs: Int,
        now: Date = Date()
    ) throws {
        try db.execute(
            sql: """
                UPDATE lifetime_dictation_stats
                SET totalDurationMs   = totalDurationMs + ?,
                    totalWords        = totalWords + ?,
                    longestDurationMs = MAX(longestDurationMs, ?),
                    updatedAt         = ?
                WHERE id = 1
                """,
            arguments: [durationDelta, wordDelta, newDurationMs, now]
        )
        guard db.changesCount == 1 else { throw LifetimeStatsError.singletonMissing }
    }

    /// User-initiated zeroing of lifetime stats. Independent of dictation deletion —
    /// the symmetric counterpart to `deleteAll()`: rows preserved, counters reset.
    /// Uses INSERT OR REPLACE so it self-heals if the singleton row is missing.
    public func resetLifetimeStats() throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO lifetime_dictation_stats
                      (id, totalCount, totalDurationMs, totalWords, longestDurationMs, updatedAt)
                    VALUES (1, 0, 0, 0, 0, ?)
                    """,
                arguments: [Date()]
            )
        }
    }

    /// Recovery / migration path: rebuild the singleton row from current dictations.
    /// Uses INSERT OR REPLACE so it self-heals even if the row was deleted. Caller
    /// must pass an open `Database` handle (already inside a write transaction).
    public static func recomputeLifetimeStats(db: Database, now: Date = Date()) throws {
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO lifetime_dictation_stats
                  (id, totalCount, totalDurationMs, totalWords, longestDurationMs, updatedAt)
                SELECT 1,
                       COUNT(*),
                       COALESCE(SUM(durationMs), 0),
                       COALESCE(SUM(wordCount), 0),
                       COALESCE(MAX(durationMs), 0),
                       ?
                FROM dictations
                WHERE status = 'completed'
                """,
            arguments: [now]
        )
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
