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

    func testSettingBlocksPreservesCurrentMatchWhenStillPresent() {
        let m = model(["one", "two one", "three one"], query: "one")
        m.next()
        XCTAssertEqual(m.current, .init(blockIndex: 1, range: NSRange(location: 4, length: 3)))

        m.setBlocks(["one changed", "two one changed", "three one"])

        XCTAssertEqual(m.currentMatchIndex, 1)
        XCTAssertEqual(m.current, .init(blockIndex: 1, range: NSRange(location: 4, length: 3)))
    }

    func testSettingBlocksKeepsCurrentOrdinalWhenExactMatchDisappears() {
        let m = model(["one", "one", "one"], query: "one")
        m.next()
        XCTAssertEqual(m.currentMatchIndex, 1)

        m.setBlocks(["one", "missing", "one"])

        XCTAssertEqual(m.matchCount, 2)
        XCTAssertEqual(m.currentMatchIndex, 1)
        XCTAssertEqual(m.current, .init(blockIndex: 2, range: NSRange(location: 0, length: 3)))
    }

    func testSettingBlocksEmptyClearsMatchesWhileKeepingQuery() {
        let m = model(["fox", "another fox"], query: "fox")
        XCTAssertEqual(m.matchCount, 2)

        m.setBlocks([])

        XCTAssertEqual(m.query, "fox")
        XCTAssertTrue(m.matches.isEmpty)
        XCTAssertNil(m.currentMatchIndex)
        XCTAssertNil(m.current)
        XCTAssertNil(m.displayPosition)
    }

    func testClearEmptiesEverything() {
        let m = model(["a a a"], query: "a")
        XCTAssertEqual(m.matchCount, 3)
        m.clear()
        XCTAssertTrue(m.matches.isEmpty)
        XCTAssertEqual(m.query, "")
        XCTAssertNil(m.currentMatchIndex)
    }

    // MARK: - Replacement

    func testReplacingCurrentReplacesOnlyThatMatch() {
        let m = model(["the cat and the dog", "the end"], query: "the")
        m.next()

        let result = m.replacingCurrent(with: "a")

        XCTAssertEqual(result, .init(blockIndex: 0, text: "the cat and a dog", count: 1))
        XCTAssertEqual(m.matchCount, 3, "computing a replacement must not mutate the model")
    }

    func testReplacingCurrentWithoutMatchIsNil() {
        let m = model(["the cat"], query: "zebra")
        XCTAssertNil(m.replacingCurrent(with: "a"))
    }

    func testReplacingAllCoversEveryBlockInOrder() {
        let m = model(["The cat saw the cat", "no match", "cat"], query: "cat")

        let result = m.replacingAll(with: "dog")

        XCTAssertEqual(result, [
            .init(blockIndex: 0, text: "The dog saw the dog", count: 2),
            .init(blockIndex: 2, text: "dog", count: 1),
        ])
    }

    func testReplacingAllMatchesCaseAndDiacriticsInsensitively() {
        let m = model(["Café, CAFE and cafe"], query: "cafe")

        XCTAssertEqual(m.replacingAll(with: "tea").first?.text, "tea, tea and tea")
    }

    func testReplacingAllDoesNotCascadeWhenReplacementContainsQuery() {
        let m = model(["cat cat"], query: "cat")

        XCTAssertEqual(m.replacingAll(with: "cats").first?.text, "cats cats")
    }

    func testReplacingAllWithEmptyStringDeletesMatches() {
        let m = model(["um so um yes"], query: "um ")

        XCTAssertEqual(m.replacingAll(with: "").first?.text, "so yes")
    }

    func testReplacingKeepsNonASCIIRangesIntact() {
        let m = model(["日本 👋 hello 👋 hello"], query: "hello")

        XCTAssertEqual(m.replacingAll(with: "bye").first?.text, "日本 👋 bye 👋 bye")
    }

    func testMoveToFirstMatchAtOrAfterResumesPastReplacement() {
        // After "cat" -> "cats" at offset 0, the rebuilt text still matches
        // "cat" at 0; resuming after the inserted text skips it.
        let m = model(["cats cat", "cat"], query: "cat")

        m.moveToFirstMatch(atOrAfter: 0, utf16Offset: 4)

        XCTAssertEqual(m.current, .init(blockIndex: 0, range: NSRange(location: 5, length: 3)))
    }

    func testMoveToFirstMatchAtOrAfterAdvancesToLaterBlockAndWraps() {
        let m = model(["cat", "dog", "cat"], query: "cat")

        m.moveToFirstMatch(atOrAfter: 1, utf16Offset: 0)
        XCTAssertEqual(m.currentMatchIndex, 1)

        m.moveToFirstMatch(atOrAfter: 2, utf16Offset: 3)
        XCTAssertEqual(m.currentMatchIndex, 0, "past the last match wraps to the first")
    }

    func testResumeOffsetAccountsForTrimmedLeadingWhitespace() throws {
        // "foo" -> " " at the line start saves "foo foo", not "  foo foo".
        let m = model(["foo foo foo"], query: "foo")
        let current = try XCTUnwrap(m.current)
        let replaced = try XCTUnwrap(m.replacingCurrent(with: " "))

        let offset = TranscriptFindReplaceEdit.resumeOffset(after: current, replacement: " ", in: replaced)
        m.setBlocks(["foo foo"])
        m.moveToFirstMatch(atOrAfter: 0, utf16Offset: offset)

        XCTAssertEqual(m.current, .init(blockIndex: 0, range: NSRange(location: 0, length: 3)))
    }

    func testResumeOffsetIsZeroWhenTheLineIsOmitted() throws {
        let m = model(["foo", "foo bar"], query: "foo")
        let current = try XCTUnwrap(m.current)
        let replaced = try XCTUnwrap(m.replacingCurrent(with: " "))

        XCTAssertEqual(
            TranscriptFindReplaceEdit.resumeOffset(after: current, replacement: " ", in: replaced), 0,
            "the next line takes the omitted line's index; resume at its start"
        )
    }
}
