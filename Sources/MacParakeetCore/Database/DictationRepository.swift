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
    /// Zero the lifetime stats counter row without touching any dictation rows.
    /// Symmetric counterpart to `deleteAll()` (rows deleted, stats preserved).
    func resetLifetimeStats() throws

    /// "Undo AI edit" toggle. Persists the per-row `displayRawTranscript`
    /// override that controls whether downstream surfaces display
    /// `rawTranscript` over `cleanTranscript`. Does not touch lifetime/daily
    /// stats — the dictation's `durationMs` / `wordCount` are unchanged and a
    /// view-only flag should not perturb counters.
    ///
    /// Returns `true` if the row was found and updated, `false` if no
    /// matching dictation exists.
    @discardableResult
    func setDisplayRawTranscript(id: UUID, value: Bool) throws -> Bool

    // Daily rollup reads (Stats tab). The rollup is private write-side state —
    // only the read surface is exposed here. Conformers MUST implement these
    // explicitly: no default no-op implementations, because a "silently returns
    // empty" default would let a mock or alternate conformer ship a blank Stats
    // tab with no compile-time signal.
    func dailyStats(daysBack days: Int) throws -> [DailyDictationStat]
    func currentDailyStreak() throws -> Int
    func longestDailyStreak() throws -> Int
    func topApps(limit: Int) throws -> [(app: String, count: Int, words: Int)]
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
            var persisted = dictation
            if persisted.hidden {
                persisted.rawTranscript = ""
                persisted.cleanTranscript = nil
                persisted.audioPath = nil
                persisted.pastedToApp = nil
                persisted.aiFormatterProfileID = nil
                persisted.aiFormatterProfileName = nil
                persisted.aiFormatterProfileMatchKind = nil
            }
            try persisted.save(db)

            switch (existing?.status, persisted.status) {
            case (.some(.completed), .completed):
                // Mutating an already-counted row (e.g. a future "edit transcript" path).
                // Apply the delta. longestDurationMs is a high-water mark — never decrements.
                let prior = existing!  // guaranteed by .some(.completed) match
                try Self.applyLifetimeDelta(
                    db: db,
                    durationDelta: persisted.durationMs - prior.durationMs,
                    wordDelta: persisted.wordCount - prior.wordCount,
                    newDurationMs: persisted.durationMs
                )
                // Daily stats: apply the delta to the row's original day. The
                // app treats `Dictation.createdAt` as immutable once a row is
                // .completed (no current code path mutates it). If a future
                // feature ever changes createdAt across a day boundary, this
                // path would leave the old day's count stale and never bump
                // the new day — add a same-day move handler before shipping
                // that feature.
                try Self.applyDailyDelta(
                    db: db,
                    day: prior.createdAt,
                    durationDelta: persisted.durationMs - prior.durationMs,
                    wordDelta: persisted.wordCount - prior.wordCount
                )
            case (_, .completed):
                // Fresh insert at .completed, or transition (.recording / .processing /
                // .error → .completed). Increment by the full row.
                try Self.incrementLifetimeStats(
                    db: db,
                    durationMs: persisted.durationMs,
                    wordCount: persisted.wordCount
                )
                try Self.incrementDailyStats(
                    db: db,
                    day: persisted.createdAt,
                    durationMs: persisted.durationMs,
                    wordCount: persisted.wordCount
                )
            default:
                // Target status isn't .completed — no-op. In practice the app
                // only saves dictations at .completed (DictationService.save),
                // so this branch is defensive: if a future code path ever writes
                // a non-completed status it won't perturb lifetime counters.
                // Note: "lifetime totalCount" is defined as rows that reached
                // .completed — consistent with `recomputeLifetimeStats`, which
                // filters on `status = 'completed'`.
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
        // Launch-time cleanup: project just (id, audioPath) in a read
        // transaction so the per-row file-system checks below never decode
        // full transcripts or hold the write lock.
        struct AudioPathRow: Decodable, FetchableRecord {
            var id: UUID
            var audioPath: String
        }

        let candidates = try dbQueue.read { db in
            try Dictation
                .filter(Dictation.Columns.audioPath != nil)
                .filter(Dictation.Columns.hidden == false)
                .select(Dictation.Columns.id, Dictation.Columns.audioPath)
                .asRequest(of: AudioPathRow.self)
                .fetchAll(db)
        }

        let missingIDs = candidates
            .filter { !FileManager.default.fileExists(atPath: $0.audioPath) }
            .map(\.id)
        guard !missingIDs.isEmpty else { return }

        // SQLite caps bound variables per statement (32,766 on modern
        // builds, 999 historically); chunk to stay far below any
        // deployment's limit.
        let batchSize = 500
        try dbQueue.write { db in
            var index = 0
            while index < missingIDs.count {
                let batch = Array(missingIDs[index..<min(index + batchSize, missingIDs.count)])
                _ = try Dictation
                    .filter(batch.contains(Dictation.Columns.id))
                    .updateAll(db, Dictation.Columns.audioPath.set(to: nil))
                index += batchSize
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

    /// Persists the per-row `displayRawTranscript` override ("Undo AI edit").
    /// Uses GRDB's keyed update path (not raw SQL with UUID) per the project
    /// gotcha note in CLAUDE.md: GRDB stores UUIDs via Codable encoding which
    /// can differ from `uuidString`. Also bumps `updatedAt` so the change is
    /// reflected if anything downstream sorts by it.
    @discardableResult
    public func setDisplayRawTranscript(id: UUID, value: Bool) throws -> Bool {
        try dbQueue.write { db in
            guard var dictation = try Dictation.fetchOne(db, key: id) else {
                return false
            }
            // No-op short-circuit so we don't bump updatedAt for repeat clicks.
            guard dictation.displayRawTranscript != value else { return true }
            dictation.displayRawTranscript = value
            dictation.updatedAt = Date()
            try dictation.update(db)
            return true
        }
    }

    public func stats() throws -> DictationStats {
        // Write transaction (not read) so we can self-heal if the singleton row is
        // missing. Migration seeds the row and nothing in code deletes it, so the
        // heal path should never fire — but if it does (manual DB surgery, partial
        // migration, etc.) we'd rather rebuild from `dictations` than silently show
        // zeros and mask a broken invariant. See also `incrementLifetimeStats`,
        // which throws on the write path for the same reason.
        try dbQueue.write { db in
            var lifetime = try Row.fetchOne(db, sql: """
                SELECT totalCount, totalDurationMs, totalWords, longestDurationMs
                FROM lifetime_dictation_stats WHERE id = 1
                """)
            if lifetime == nil {
                try Self.recomputeLifetimeStats(db: db)
                lifetime = try Row.fetchOne(db, sql: """
                    SELECT totalCount, totalDurationMs, totalWords, longestDurationMs
                    FROM lifetime_dictation_stats WHERE id = 1
                    """)
            }
            let totalCount: Int = lifetime?["totalCount"] ?? 0
            let totalDuration: Int = lifetime?["totalDurationMs"] ?? 0
            let totalWords: Int = lifetime?["totalWords"] ?? 0
            let longestDuration: Int = lifetime?["longestDurationMs"] ?? 0
            let averageDuration = totalCount > 0
                ? Int((Double(totalDuration) / Double(totalCount)).rounded())
                : 0

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
    ///
    /// Counts only `status = 'completed'` rows — this matches the write-path
    /// definition in `save()`, which increments lifetime counters only when the
    /// row transitions to `.completed`. Keep the two filters in sync if the
    /// "lifetime" definition ever broadens.
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

    // MARK: - Daily stats helpers (Stats tab heatmap, current/longest streak)

    /// Formats a date as `YYYY-MM-DD` in the user's local calendar. The day
    /// rollup uses local time so the heatmap reflects "what days did you
    /// dictate" as the user experienced them — not UTC days, which would split
    /// a late-night session in PT across two squares.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Hot-path increment for a newly-completed dictation. UPSERT — creates the
    /// day row if absent or bumps the existing one. No invariant guard like
    /// lifetime stats: the row's absence is the expected initial state.
    static func incrementDailyStats(
        db: Database,
        day date: Date,
        durationMs: Int,
        wordCount: Int,
        now: Date = Date()
    ) throws {
        let key = dayKey(for: date)
        try db.execute(
            sql: """
                INSERT INTO daily_dictation_stats (day, count, words, durationMs, updatedAt)
                VALUES (?, 1, ?, ?, ?)
                ON CONFLICT(day) DO UPDATE SET
                    count       = count + 1,
                    words       = words + excluded.words,
                    durationMs  = durationMs + excluded.durationMs,
                    updatedAt   = excluded.updatedAt
                """,
            arguments: [key, wordCount, durationMs, now]
        )
    }

    /// Delta apply for an already-counted row whose duration / wordCount
    /// changed (e.g. a future "edit transcript" path). Total `count` for the
    /// day is unchanged — only words and duration move. If the day row is
    /// somehow missing (a row was inserted before this migration shipped and
    /// the backfill didn't catch it) we silently no-op rather than throw.
    static func applyDailyDelta(
        db: Database,
        day date: Date,
        durationDelta: Int,
        wordDelta: Int,
        now: Date = Date()
    ) throws {
        let key = dayKey(for: date)
        try db.execute(
            sql: """
                UPDATE daily_dictation_stats
                SET words       = MAX(0, words + ?),
                    durationMs  = MAX(0, durationMs + ?),
                    updatedAt   = ?
                WHERE day = ?
                """,
            arguments: [wordDelta, durationDelta, now, key]
        )
    }

    /// Migration helper: rebuild the daily rollup from existing completed
    /// dictations. Grouped in Swift (rather than SQL `date(..., 'localtime')`)
    /// so the bucketing matches `Calendar.current` exactly.
    ///
    /// Intentionally module-internal: the function opens with
    /// `DELETE FROM daily_dictation_stats` and an external caller could wipe a
    /// user's preserved streak history. Reachable from tests via
    /// `@testable import MacParakeetCore`.
    static func backfillDailyStats(db: Database, now: Date = Date()) throws {
        // Wipe any prior rows so re-running this is idempotent.
        try db.execute(sql: "DELETE FROM daily_dictation_stats")

        let rows = try Row.fetchAll(db, sql: """
            SELECT createdAt, durationMs, wordCount
            FROM dictations
            WHERE status = 'completed'
        """)

        var buckets: [String: (count: Int, words: Int, durationMs: Int)] = [:]
        for row in rows {
            guard let createdAt = Date.fromDatabaseValue(row["createdAt"] as DatabaseValue) else { continue }
            let key = dayKey(for: createdAt)
            let durationMs: Int = row["durationMs"] ?? 0
            let wordCount: Int = row["wordCount"] ?? 0
            var bucket = buckets[key] ?? (0, 0, 0)
            bucket.count += 1
            bucket.words += wordCount
            bucket.durationMs += durationMs
            buckets[key] = bucket
        }

        for (key, bucket) in buckets {
            try db.execute(
                sql: """
                    INSERT INTO daily_dictation_stats (day, count, words, durationMs, updatedAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [key, bucket.count, bucket.words, bucket.durationMs, now]
            )
        }
    }

    // MARK: - Daily stats reads (Stats tab)

    /// Fetches the per-day rollup for the trailing `days` window ending today
    /// (inclusive). Returns a dense array of length `days` with zero-filled
    /// entries for days that had no dictations — the view can map this 1:1 to
    /// heatmap cells without re-keying.
    public func dailyStats(daysBack days: Int) throws -> [DailyDictationStat] {
        try dailyStats(daysBack: days, now: Date(), calendar: .current)
    }

    func dailyStats(daysBack days: Int, now: Date, calendar: Calendar) throws -> [DailyDictationStat] {
        guard days > 0 else { return [] }

        return try dbQueue.read { db in
            let today = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
            let startKey = Self.dayKey(for: start, calendar: calendar)

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT day, count, words, durationMs
                    FROM daily_dictation_stats
                    WHERE day >= ?
                    """,
                arguments: [startKey]
            )

            var byKey: [String: (count: Int, words: Int, durationMs: Int)] = [:]
            for row in rows {
                let key: String = row["day"] ?? ""
                byKey[key] = (row["count"] ?? 0, row["words"] ?? 0, row["durationMs"] ?? 0)
            }

            var result: [DailyDictationStat] = []
            result.reserveCapacity(days)
            for offset in 0..<days {
                guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
                let bucket = byKey[Self.dayKey(for: day, calendar: calendar)] ?? (0, 0, 0)
                result.append(DailyDictationStat(
                    day: day,
                    count: bucket.count,
                    words: bucket.words,
                    durationMs: bucket.durationMs
                ))
            }
            return result
        }
    }

    /// Current daily streak. Walks back from today (or yesterday if today has
    /// no dictation yet) counting consecutive days with `count > 0`. Matches
    /// the typical "don't break the chain" semantic where missing today
    /// doesn't immediately reset.
    public func currentDailyStreak() throws -> Int {
        try currentDailyStreak(now: Date(), calendar: .current)
    }

    func currentDailyStreak(now: Date, calendar: Calendar) throws -> Int {
        try dbQueue.read { db in
            let activeDays = try Self.fetchActiveDays(db: db)
            return Self.computeCurrentDailyStreak(activeDays: activeDays, now: now, calendar: calendar)
        }
    }

    /// Longest all-time daily streak. Computed across every day in
    /// `daily_dictation_stats` — survives history deletion.
    public func longestDailyStreak() throws -> Int {
        try longestDailyStreak(calendar: .current)
    }

    func longestDailyStreak(calendar: Calendar) throws -> Int {
        try dbQueue.read { db in
            let activeDays = try Self.fetchActiveDays(db: db)
            return Self.computeLongestDailyStreak(activeDays: activeDays, calendar: calendar)
        }
    }

    /// Top apps by completed-dictation count, derived from `pastedToApp`.
    /// Live data — reflects only currently-present dictation rows (clears
    /// after `Clear History`). Per-app rollup is intentionally not persisted;
    /// the heatmap is the privileged surface that survives deletion.
    public func topApps(limit: Int) throws -> [(app: String, count: Int, words: Int)] {
        let safeLimit = min(max(limit, 0), 1_000)
        guard safeLimit > 0 else { return [] }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT pastedToApp, COUNT(*) AS cnt, COALESCE(SUM(wordCount), 0) AS words
                FROM dictations
                WHERE status = 'completed'
                  AND hidden = 0
                  AND pastedToApp IS NOT NULL
                  AND TRIM(pastedToApp) != ''
                GROUP BY pastedToApp
                ORDER BY cnt DESC, pastedToApp ASC
                LIMIT ?
            """, arguments: [safeLimit])
            return rows.map { row in
                let app: String = row["pastedToApp"] ?? ""
                let cnt: Int = row["cnt"] ?? 0
                let words: Int = row["words"] ?? 0
                return (app: app, count: cnt, words: words)
            }
        }
    }

    private static func fetchActiveDays(db: Database) throws -> Set<String> {
        let keys = try String.fetchAll(
            db,
            sql: "SELECT day FROM daily_dictation_stats WHERE count > 0"
        )
        return Set(keys)
    }

    /// Pure function for unit tests. Walks back from today (or yesterday if
    /// today is absent) counting consecutive day keys present in `activeDays`.
    static func computeCurrentDailyStreak(
        activeDays: Set<String>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let todayKey = dayKey(for: now, calendar: calendar)
        var cursor: Date
        if activeDays.contains(todayKey) {
            cursor = calendar.startOfDay(for: now)
        } else {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else {
                return 0
            }
            cursor = yesterday
        }

        var streak = 0
        while activeDays.contains(dayKey(for: cursor, calendar: calendar)) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    /// Pure function for unit tests. Longest consecutive-day run across the
    /// full set of active day keys.
    static func computeLongestDailyStreak(
        activeDays: Set<String>,
        calendar: Calendar = .current
    ) -> Int {
        guard !activeDays.isEmpty else { return 0 }

        // Parse keys back to dates once, sort ascending, then scan.
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let dates = activeDays.compactMap { formatter.date(from: $0) }.sorted()
        guard !dates.isEmpty else { return 0 }

        var longest = 1
        var run = 1
        for i in 1..<dates.count {
            if let nextDay = calendar.date(byAdding: .day, value: 1, to: dates[i - 1]),
               calendar.isDate(nextDay, inSameDayAs: dates[i]) {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }
        return longest
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
