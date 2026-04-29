import XCTest
import GRDB
@testable import MacParakeetCore

/// Tests for the lifetime_dictation_stats table that survives history deletion (issue #124).
final class LifetimeDictationStatsTests: XCTestCase {
    var manager: DatabaseManager!
    var repo: DictationRepository!

    override func setUp() async throws {
        manager = try DatabaseManager()
        repo = DictationRepository(dbQueue: manager.dbQueue)
    }

    // MARK: - Deletion preserves lifetime totals (the #124 bug)

    func testLifetimeStatsPersistAfterDeleteAll() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "one", wordCount: 1))
        try repo.save(Dictation(durationMs: 2000, rawTranscript: "two two", wordCount: 2))
        try repo.save(Dictation(durationMs: 3000, rawTranscript: "three three three", wordCount: 3))

        try repo.deleteAll()

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 3, "lifetime totalCount must survive deleteAll")
        XCTAssertEqual(stats.totalDurationMs, 6000)
        XCTAssertEqual(stats.totalWords, 6)
        XCTAssertEqual(stats.visibleCount, 0, "visibleCount reflects current rows, drops to 0")
    }

    func testLifetimeStatsPersistAfterDeleteHidden() throws {
        let visible = Dictation(durationMs: 1000, rawTranscript: "visible", wordCount: 1)
        var hidden = Dictation(durationMs: 4000, rawTranscript: "hidden", wordCount: 2)
        hidden.hidden = true

        try repo.save(visible)
        try repo.save(hidden)
        try repo.deleteHidden()

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 2, "hidden row contributed to lifetime, survives delete")
        XCTAssertEqual(stats.totalDurationMs, 5000)
        XCTAssertEqual(stats.totalWords, 3)
    }

    func testLifetimeStatsPersistAfterSingleDelete() throws {
        let d1 = Dictation(durationMs: 1000, rawTranscript: "one", wordCount: 1)
        let d2 = Dictation(durationMs: 2000, rawTranscript: "two", wordCount: 1)
        try repo.save(d1)
        try repo.save(d2)

        XCTAssertTrue(try repo.delete(id: d1.id))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 2)
        XCTAssertEqual(stats.totalDurationMs, 3000)
        XCTAssertEqual(stats.visibleCount, 1)
    }

    // MARK: - Idempotency

    func testReSavingCompletedDictationWithSameValuesDoesNotDoubleCount() throws {
        let d = Dictation(durationMs: 1000, rawTranscript: "hello", wordCount: 1)
        try repo.save(d)
        try repo.save(d)  // identical re-save → zero delta
        try repo.save(d)

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 1)
        XCTAssertEqual(stats.totalDurationMs, 1000)
        XCTAssertEqual(stats.totalWords, 1)
    }

    func testReSavingCompletedDictationWithChangedWordCountAppliesDelta() throws {
        var d = Dictation(durationMs: 2000, rawTranscript: "hello", wordCount: 5)
        try repo.save(d)

        d.wordCount = 8  // mutate as if a future "edit transcript" feature ran
        d.durationMs = 3000
        try repo.save(d)

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 1, "totalCount unchanged on delta path")
        XCTAssertEqual(stats.totalWords, 8, "delta lifted totalWords from 5 to 8 (not 13)")
        XCTAssertEqual(stats.totalDurationMs, 3000)
    }

    // MARK: - Status guards

    func testStatusTransitionToCompletedIncrementsExactlyOnce() throws {
        var d = Dictation(durationMs: 1000, rawTranscript: "hi", status: .recording, wordCount: 1)
        try repo.save(d)

        XCTAssertEqual(try repo.stats().totalCount, 0, ".recording does not increment")

        d.status = .completed
        try repo.save(d)

        XCTAssertEqual(try repo.stats().totalCount, 1)
    }

    func testErrorStatusDoesNotIncrementLifetime() throws {
        try repo.save(Dictation(durationMs: 5000, rawTranscript: "bad", status: .error, wordCount: 3))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 0)
        XCTAssertEqual(stats.totalWords, 0)
        XCTAssertEqual(stats.totalDurationMs, 0)
    }

    func testRecordingStatusDoesNotIncrementLifetime() throws {
        try repo.save(Dictation(durationMs: 5000, rawTranscript: "wip", status: .recording, wordCount: 3))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 0)
        XCTAssertEqual(stats.totalWords, 0)
    }

    // MARK: - Hidden rows

    func testHiddenDictationsContributeToLifetime() throws {
        var hidden = Dictation(durationMs: 4000, rawTranscript: "private", wordCount: 5)
        hidden.hidden = true
        try repo.save(hidden)

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 1, "hidden dictations count toward lifetime")
        XCTAssertEqual(stats.totalWords, 5)
        XCTAssertEqual(stats.totalDurationMs, 4000)
        XCTAssertEqual(stats.visibleCount, 0)
    }

    // MARK: - longestDurationMs as high-water mark

    func testLongestDurationIsLifetimeMax() throws {
        let big = Dictation(durationMs: 5000, rawTranscript: "long", wordCount: 1)
        try repo.save(big)
        XCTAssertTrue(try repo.delete(id: big.id))

        try repo.save(Dictation(durationMs: 1000, rawTranscript: "short", wordCount: 1))

        XCTAssertEqual(try repo.stats().longestDurationMs, 5000, "high-water mark survives deletion")
    }

    func testLongestDurationDoesNotDecreaseOnDelta() throws {
        var d = Dictation(durationMs: 5000, rawTranscript: "long", wordCount: 1)
        try repo.save(d)

        d.durationMs = 1000  // shrunk via re-save
        try repo.save(d)

        XCTAssertEqual(try repo.stats().longestDurationMs, 5000, "high-water mark — no decrement on delta")
    }

    // MARK: - Empty / fresh DB

    func testEmptyDatabaseLifetimeStatsAreZero() throws {
        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 0)
        XCTAssertEqual(stats.totalDurationMs, 0)
        XCTAssertEqual(stats.totalWords, 0)
        XCTAssertEqual(stats.longestDurationMs, 0)
        XCTAssertEqual(stats.averageDurationMs, 0)
    }

    // MARK: - Cross-check: incremental vs. recompute

    func testRecomputeMatchesIncrementalAccumulation() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "a a", wordCount: 2))
        try repo.save(Dictation(durationMs: 2500, rawTranscript: "b b b", wordCount: 3))
        try repo.save(Dictation(durationMs: 4000, rawTranscript: "c", wordCount: 1))

        let incremental = try repo.stats()

        // Recompute from current dictations — should produce identical lifetime totals
        // because no rows have been deleted yet.
        try manager.dbQueue.write { db in
            try DictationRepository.recomputeLifetimeStats(db: db)
        }
        let recomputed = try repo.stats()

        XCTAssertEqual(incremental.totalCount, recomputed.totalCount)
        XCTAssertEqual(incremental.totalDurationMs, recomputed.totalDurationMs)
        XCTAssertEqual(incremental.totalWords, recomputed.totalWords)
        XCTAssertEqual(incremental.longestDurationMs, recomputed.longestDurationMs)
    }

    // MARK: - Singleton-missing safety

    func testIncrementThrowsIfSingletonRowMissing() throws {
        // Manually wipe the singleton row to simulate corruption.
        try manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM lifetime_dictation_stats WHERE id = 1")
        }

        XCTAssertThrowsError(
            try repo.save(Dictation(durationMs: 1000, rawTranscript: "x", wordCount: 1))
        ) { error in
            guard case LifetimeStatsError.singletonMissing = error else {
                return XCTFail("expected singletonMissing, got \(error)")
            }
        }

        // Transaction rolled back — the dictation must not have been saved either.
        let count = try manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dictations") ?? 0
        }
        XCTAssertEqual(count, 0, "save() transaction must roll back when increment throws")
    }

    // MARK: - Recovery via recompute

    func testRecomputeSelfHealsAfterSingletonDeletion() throws {
        try repo.save(Dictation(durationMs: 1500, rawTranscript: "a", wordCount: 1))
        try repo.save(Dictation(durationMs: 2500, rawTranscript: "b b", wordCount: 2))

        // Wipe the lifetime row entirely.
        try manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM lifetime_dictation_stats WHERE id = 1")
            try DictationRepository.recomputeLifetimeStats(db: db)
        }

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 2)
        XCTAssertEqual(stats.totalDurationMs, 4000)
        XCTAssertEqual(stats.totalWords, 3)
    }

    func testStatsSelfHealsIfSingletonRowMissing() throws {
        // stats() must rebuild from `dictations` rather than silently reporting zeros
        // when the singleton row is absent — otherwise we'd mask the same invariant
        // violation the hot write path throws on.
        try repo.save(Dictation(durationMs: 1500, rawTranscript: "a", wordCount: 1))
        try repo.save(Dictation(durationMs: 2500, rawTranscript: "b b", wordCount: 2))

        try manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM lifetime_dictation_stats WHERE id = 1")
        }

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 2, "stats() must self-heal from dictations, not return 0")
        XCTAssertEqual(stats.totalDurationMs, 4000)
        XCTAssertEqual(stats.totalWords, 3)

        // Row is persisted after the heal — next save's UPDATE hot-path finds it.
        let countAfter = try manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lifetime_dictation_stats WHERE id = 1") ?? 0
        }
        XCTAssertEqual(countAfter, 1)
    }

    // MARK: - User-initiated reset

    func testResetLifetimeStatsZeroesCountersWithoutDeletingDictations() throws {
        try repo.save(Dictation(durationMs: 5000, rawTranscript: "hello world", wordCount: 2))
        try repo.save(Dictation(durationMs: 3000, rawTranscript: "again", wordCount: 1))
        XCTAssertEqual(try repo.stats().totalCount, 2)

        try repo.resetLifetimeStats()

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 0)
        XCTAssertEqual(stats.totalDurationMs, 0)
        XCTAssertEqual(stats.totalWords, 0)
        XCTAssertEqual(stats.longestDurationMs, 0)

        // Dictation rows are preserved — symmetric counterpart to deleteAll().
        XCTAssertEqual(try repo.fetchAll(limit: nil).count, 2)
        XCTAssertEqual(stats.visibleCount, 2)
    }

    func testResetLifetimeStatsThenSaveContinuesAccumulating() throws {
        try repo.save(Dictation(durationMs: 5000, rawTranscript: "old", wordCount: 1))
        try repo.resetLifetimeStats()
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "fresh start", wordCount: 2))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 1, "only the post-reset save counts")
        XCTAssertEqual(stats.totalWords, 2)
        XCTAssertEqual(stats.totalDurationMs, 1000)
    }

    func testResetLifetimeStatsSelfHealsIfSingletonRowMissing() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "x", wordCount: 1))
        try manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM lifetime_dictation_stats WHERE id = 1")
        }

        // Reset uses INSERT OR REPLACE — should not throw even with row missing.
        XCTAssertNoThrow(try repo.resetLifetimeStats())

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 0)
    }
}
