import XCTest
import GRDB
@testable import MacParakeetCore

final class DictationStatsQueryTests: XCTestCase {
    var repo: DictationRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = DictationRepository(dbQueue: manager.dbQueue)
    }

    // MARK: - Aggregate Stats

    func testStatsEmptyDatabase() throws {
        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 0)
        XCTAssertEqual(stats.totalDurationMs, 0)
        XCTAssertEqual(stats.totalWords, 0)
        XCTAssertEqual(stats.longestDurationMs, 0)
        XCTAssertEqual(stats.averageDurationMs, 0)
        XCTAssertTrue(stats.isEmpty)
    }

    func testStatsOnlyCountsCompleted() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "Hello world", status: .completed, wordCount: 2))
        try repo.save(Dictation(durationMs: 2000, rawTranscript: "Recording in progress", status: .recording, wordCount: 3))
        try repo.save(Dictation(durationMs: 3000, rawTranscript: "Had an error", status: .error, wordCount: 3))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalCount, 1)
        XCTAssertEqual(stats.totalDurationMs, 1000)
    }

    func testStatsWordCount() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "Hello world", wordCount: 2))
        try repo.save(Dictation(durationMs: 2000, rawTranscript: "One two three four", wordCount: 4))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalWords, 6) // 2 + 4
    }

    func testStatsPrefersCleanTranscriptForWordCount() throws {
        // wordCount should reflect the clean transcript word count (set by caller)
        try repo.save(Dictation(
            durationMs: 1000,
            rawTranscript: "uh um like hello world you know",
            cleanTranscript: "hello world",
            wordCount: 2
        ))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalWords, 2)
    }

    func testStatsLongestDuration() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "Short"))
        try repo.save(Dictation(durationMs: 5000, rawTranscript: "Longer"))
        try repo.save(Dictation(durationMs: 3000, rawTranscript: "Medium"))

        let stats = try repo.stats()
        XCTAssertEqual(stats.longestDurationMs, 5000)
    }

    func testStatsAverageDuration() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "One"))
        try repo.save(Dictation(durationMs: 3000, rawTranscript: "Two"))

        let stats = try repo.stats()
        XCTAssertEqual(stats.averageDurationMs, 2000)
    }

    func testStatsEmptyTranscriptCountsZeroWords() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: ""))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalWords, 0)
    }

    func testStatsWhitespaceOnlyTranscriptCountsZeroWords() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "   "))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalWords, 0)
    }

    func testStatsMultipleConsecutiveSpacesCountCorrectly() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "hello   world", wordCount: 2))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalWords, 2)
    }

    func testStatsLongWhitespaceRunCountsCorrectly() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "hello          world", wordCount: 2))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalWords, 2)
    }

    func testStatsNewlinesCountAsWordBoundaries() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "hello\nworld", wordCount: 2))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalWords, 2)
    }

    func testStatsTabsCountAsWordBoundaries() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "hello\tworld\tfoo", wordCount: 3))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalWords, 3)
    }

    func testStatsMixedWhitespaceCountsCorrectly() throws {
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "hello \n\t  world", wordCount: 2))

        let stats = try repo.stats()
        XCTAssertEqual(stats.totalWords, 2)
    }

    // MARK: - Weekly Streak

    func testWeeklyStreakEmpty() {
        let (streak, thisWeek) = DictationRepository.computeWeeklyStreak(from: [])
        XCTAssertEqual(streak, 0)
        XCTAssertEqual(thisWeek, 0)
    }

    func testWeeklyStreakCurrentWeekOnly() {
        let now = Date()
        let (streak, thisWeek) = DictationRepository.computeWeeklyStreak(
            from: [now, now.addingTimeInterval(-3600)],
            now: now
        )
        XCTAssertEqual(streak, 1)
        XCTAssertEqual(thisWeek, 2)
    }

    func testWeeklyStreakConsecutiveWeeks() {
        let calendar = Calendar.current
        let now = Date()
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now)!
        let twoWeeksAgo = calendar.date(byAdding: .weekOfYear, value: -2, to: now)!

        let (streak, _) = DictationRepository.computeWeeklyStreak(
            from: [now, lastWeek, twoWeeksAgo],
            calendar: calendar,
            now: now
        )
        XCTAssertEqual(streak, 3)
    }

    func testWeeklyStreakGapBreaks() {
        let calendar = Calendar.current
        let now = Date()
        // Skip last week, have activity two weeks ago
        let twoWeeksAgo = calendar.date(byAdding: .weekOfYear, value: -2, to: now)!

        let (streak, _) = DictationRepository.computeWeeklyStreak(
            from: [now, twoWeeksAgo],
            calendar: calendar,
            now: now
        )
        XCTAssertEqual(streak, 1) // Only current week counts, gap breaks streak
    }

    func testDictationsThisWeekFromDatabase() throws {
        // Save a dictation with "now" date
        try repo.save(Dictation(durationMs: 1000, rawTranscript: "Today", wordCount: 1))

        let stats = try repo.stats()
        XCTAssertGreaterThanOrEqual(stats.dictationsThisWeek, 1)
    }

    func testWeeklyStreakExcludesFutureDates() {
        let now = Date()
        let futureDate = now.addingTimeInterval(86400 * 30) // 30 days from now

        let (streak, thisWeek) = DictationRepository.computeWeeklyStreak(
            from: [now, futureDate],
            now: now
        )
        XCTAssertEqual(streak, 1)
        XCTAssertEqual(thisWeek, 1, "Future-dated row should not count in this week")
    }
}
