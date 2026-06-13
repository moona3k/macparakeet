import XCTest
@testable import MacParakeetCore

final class DictationStatsTests: XCTestCase {

    // MARK: - isEmpty

    func testEmptyStatsIsEmpty() {
        XCTAssertTrue(DictationStats.empty.isEmpty)
    }

    func testNonEmptyStatsIsNotEmpty() {
        let stats = DictationStats(totalCount: 1, totalDurationMs: 1000, totalWords: 10)
        XCTAssertFalse(stats.isEmpty)
    }

    // MARK: - averageWPM

    func testAverageWPMNormal() {
        // 150 words in 1 minute (60000ms) = 150 WPM
        let stats = DictationStats(totalCount: 1, totalDurationMs: 60_000, totalWords: 150)
        XCTAssertEqual(stats.averageWPM, 150.0, accuracy: 0.1)
    }

    func testAverageWPMZeroDuration() {
        let stats = DictationStats(totalCount: 1, totalDurationMs: 0, totalWords: 100)
        XCTAssertEqual(stats.averageWPM, 0)
    }

    func testAverageWPMZeroWords() {
        let stats = DictationStats(totalCount: 1, totalDurationMs: 60_000, totalWords: 0)
        XCTAssertEqual(stats.averageWPM, 0, accuracy: 0.01)
    }

    // MARK: - timeSavedMs

    func testTimeSavedPositive() {
        // 100 words spoken in 30 seconds (30000ms)
        // Typing: 100 / 40 * 60000 = 150000ms
        // Saved: 150000 - 30000 = 120000ms
        let stats = DictationStats(totalCount: 1, totalDurationMs: 30_000, totalWords: 100)
        XCTAssertEqual(stats.timeSavedMs, 120_000)
    }

    func testTimeSavedZeroWords() {
        let stats = DictationStats(totalCount: 1, totalDurationMs: 5000, totalWords: 0)
        XCTAssertEqual(stats.timeSavedMs, 0)
    }

    func testTimeSavedNeverNegative() {
        // Edge case: extremely slow speech (1 word in 10 minutes)
        let stats = DictationStats(totalCount: 1, totalDurationMs: 600_000, totalWords: 1)
        XCTAssertGreaterThanOrEqual(stats.timeSavedMs, 0)
    }

    // MARK: - booksEquivalent

    func testBooksEquivalent() {
        let stats = DictationStats(totalCount: 10, totalDurationMs: 100_000, totalWords: 160_000)
        XCTAssertEqual(stats.booksEquivalent, 2.0, accuracy: 0.01)
    }

    // MARK: - emailsEquivalent

    func testEmailsEquivalent() {
        let stats = DictationStats(totalCount: 5, totalDurationMs: 50_000, totalWords: 1000)
        XCTAssertEqual(stats.emailsEquivalent, 5.0, accuracy: 0.01)
    }

    // MARK: - Equatable

    func testEquatable() {
        let a = DictationStats(totalCount: 1, totalDurationMs: 1000, totalWords: 10)
        let b = DictationStats(totalCount: 1, totalDurationMs: 1000, totalWords: 10)
        XCTAssertEqual(a, b)
    }
}
