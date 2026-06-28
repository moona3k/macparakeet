import XCTest
@testable import MacParakeetViewModels

@MainActor
final class TranscriptFindModelTests: XCTestCase {

    private func model(_ blocks: [String], query: String) -> TranscriptFindModel {
        let m = TranscriptFindModel()
        m.setBlocks(blocks)
        m.setQuery(query)
        return m
    }

    // MARK: - Empty / no-op queries

    func testEmptyQueryHasNoMatches() {
        let m = model(["the quick brown fox"], query: "")
        XCTAssertTrue(m.matches.isEmpty)
        XCTAssertNil(m.currentMatchIndex)
        XCTAssertNil(m.current)
        XCTAssertNil(m.displayPosition)
        XCTAssertFalse(m.hasMatches)
    }

    func testWhitespaceOnlyQueryHasNoMatches() {
        let m = model(["the quick brown fox"], query: "   \n\t")
        XCTAssertTrue(m.matches.isEmpty)
        XCTAssertNil(m.currentMatchIndex)
    }

    func testQueryWithEdgeSpacesMatchesLiterally() {
        // A query that is non-empty after trimming is searched untrimmed, so
        // " the " (trailing space) matches the word "the " in block 0 but not
        // the "the" inside "there" (followed by "r") in block 1.
        let m = model(["the cat sat", "there it is"], query: "the ")
        XCTAssertEqual(m.matches, [.init(blockIndex: 0, range: NSRange(location: 0, length: 4))])
    }

    func testQueryWithNoMatchesIsEmptyButHasQuery() {
        let m = model(["the quick brown fox"], query: "zebra")
        XCTAssertTrue(m.matches.isEmpty)
        XCTAssertEqual(m.query, "zebra")
        XCTAssertNil(m.displayPosition)
    }

    // MARK: - Basic matching

    func testSingleMatchRangeAndPosition() {
        let m = model(["the quick brown fox"], query: "quick")
        XCTAssertEqual(m.matches, [.init(blockIndex: 0, range: NSRange(location: 4, length: 5))])
        XCTAssertEqual(m.currentMatchIndex, 0)
        XCTAssertEqual(m.displayPosition?.current, 1)
        XCTAssertEqual(m.displayPosition?.total, 1)
    }

    func testMultipleMatchesWithinOneBlockAreOrdered() {
        let m = model(["hello Hello HELLO"], query: "hello")
        XCTAssertEqual(m.matches.map(\.range), [
            NSRange(location: 0, length: 5),
            NSRange(location: 6, length: 5),
            NSRange(location: 12, length: 5)
        ])
        XCTAssertTrue(m.matches.allSatisfy { $0.blockIndex == 0 })
        XCTAssertEqual(m.matchCount, 3)
    }

    func testMatchesAcrossBlocksAreGloballyOrdered() {
        let m = model(["alpha match", "no hit here", "match beta match"], query: "match")
        XCTAssertEqual(m.matches, [
            .init(blockIndex: 0, range: NSRange(location: 6, length: 5)),
            .init(blockIndex: 2, range: NSRange(location: 0, length: 5)),
            .init(blockIndex: 2, range: NSRange(location: 11, length: 5))
        ])
    }

    func testOverlappingCandidatesDoNotDoubleCount() {
        // "aa" inside "aaaa" yields non-overlapping matches at 0 and 2.
        let m = model(["aaaa"], query: "aa")
        XCTAssertEqual(m.matches.map(\.range), [
            NSRange(location: 0, length: 2),
            NSRange(location: 2, length: 2)
        ])
    }

    // MARK: - Insensitivity

    func testCaseInsensitive() {
        let lower = model(["Title TITLE title"], query: "title")
        let upper = model(["Title TITLE title"], query: "TITLE")
        XCTAssertEqual(lower.matches, upper.matches)
        XCTAssertEqual(lower.matchCount, 3)
    }

    func testDiacriticInsensitive() {
        let m = model(["café cafe Café"], query: "cafe")
        XCTAssertEqual(m.matchCount, 3)
        XCTAssertEqual(m.matches.first?.range, NSRange(location: 0, length: 4))
    }

    // MARK: - Navigation

    func testNextWrapsAround() {
        let m = model(["a a a"], query: "a")
        XCTAssertEqual(m.currentMatchIndex, 0)
        m.next(); XCTAssertEqual(m.currentMatchIndex, 1)
        m.next(); XCTAssertEqual(m.currentMatchIndex, 2)
        m.next(); XCTAssertEqual(m.currentMatchIndex, 0)
    }

    func testPrevWrapsAround() {
        let m = model(["a a a"], query: "a")
        XCTAssertEqual(m.currentMatchIndex, 0)
        m.prev(); XCTAssertEqual(m.currentMatchIndex, 2)
        m.prev(); XCTAssertEqual(m.currentMatchIndex, 1)
    }

    func testNavigationNoOpWhenNoMatches() {
        let m = model(["nothing here"], query: "zzz")
        m.next()
        XCTAssertNil(m.currentMatchIndex)
        m.prev()
        XCTAssertNil(m.currentMatchIndex)
    }

    func testCurrentMatchTracksCursor() {
        let m = model(["one two", "two three"], query: "two")
        XCTAssertEqual(m.current, .init(blockIndex: 0, range: NSRange(location: 4, length: 3)))
        m.next()
        XCTAssertEqual(m.current, .init(blockIndex: 1, range: NSRange(location: 0, length: 3)))
    }

    // MARK: - Re-running on content / query change

    func testChangingQueryResetsCursorToFirst() {
        let m = model(["one one", "two two two"], query: "one")
        m.next()
        XCTAssertEqual(m.currentMatchIndex, 1)
        m.setQuery("two")
        XCTAssertEqual(m.currentMatchIndex, 0)
        XCTAssertEqual(m.matchCount, 3)
    }

    func testSettingBlocksReRunsQuery() {
        let m = TranscriptFindModel()
        m.setQuery("fox")
        XCTAssertTrue(m.matches.isEmpty)
        m.setBlocks(["the fox", "another fox"])
        XCTAssertEqual(m.matchCount, 2)
        XCTAssertEqual(m.currentMatchIndex, 0)
    }

    func testClearEmptiesEverything() {
        let m = model(["a a a"], query: "a")
        XCTAssertEqual(m.matchCount, 3)
        m.clear()
        XCTAssertTrue(m.matches.isEmpty)
        XCTAssertEqual(m.query, "")
        XCTAssertNil(m.currentMatchIndex)
    }

    func testMatchesInBlockFilter() {
        let m = model(["match here match", "no", "match"], query: "match")
        XCTAssertEqual(m.matches(inBlock: 0).count, 2)
        XCTAssertEqual(m.matches(inBlock: 1).count, 0)
        XCTAssertEqual(m.matches(inBlock: 2).count, 1)
    }
}
