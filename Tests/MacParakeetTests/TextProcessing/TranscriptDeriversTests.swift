import XCTest
@testable import MacParakeetCore

final class TitleDeriverTests: XCTestCase {
    func testEmptyAndNilReturnNil() {
        XCTAssertNil(TitleDeriver.derive(from: nil))
        XCTAssertNil(TitleDeriver.derive(from: ""))
        XCTAssertNil(TitleDeriver.derive(from: "   \n  "))
    }

    func testPicksFirstSubstantiveSentence() {
        let transcript = """
        So um okay. Yeah. The new dress structure looks great for tomorrow's runway show.
        We should review the lighting cues with the production team this afternoon.
        """
        let title = TitleDeriver.derive(from: transcript)
        XCTAssertEqual(title, "The new dress structure looks great for tomorrow's runway show")
    }

    func testStripsLeadingFillers() {
        let transcript = "Yeah so um the budget meeting starts at three o'clock with the partners."
        let title = TitleDeriver.derive(from: transcript)
        XCTAssertNotNil(title)
        XCTAssertFalse(title!.hasPrefix("Yeah"))
        XCTAssertFalse(title!.hasPrefix("So"))
        XCTAssertFalse(title!.hasPrefix("Um"))
        XCTAssertTrue(title!.localizedCaseInsensitiveContains("budget meeting"))
    }

    func testTruncatesLongSentence() {
        let long = "The quarterly business review covers revenue growth across all five product lines, marketing investment ROI, customer acquisition costs by channel, and the new hiring plan for engineering."
        let title = TitleDeriver.derive(from: long)
        XCTAssertNotNil(title)
        XCTAssertLessThanOrEqual(title!.count, TitleDeriver.maxLength + 1)
    }

    func testCapitalizesFirstLetter() {
        let transcript = "the meeting starts at three."
        let title = TitleDeriver.derive(from: transcript)
        XCTAssertEqual(title?.first, "T")
    }

    func testTrimsTrailingPunctuation() {
        let transcript = "Reviewing the new product launch strategy with the team."
        let title = TitleDeriver.derive(from: transcript)
        XCTAssertNotNil(title)
        XCTAssertNotEqual(title?.last, ".")
    }

    func testPreservesEllipsisFromTruncation() {
        let long = "The quarterly business review covers revenue growth across all five product lines, marketing investment ROI, customer acquisition costs by channel, and the new hiring plan for engineering."
        let title = TitleDeriver.derive(from: long)
        XCTAssertNotNil(title)
        // Truncation marker should survive `clean()` even though `clean`
        // strips other trailing punctuation.
        XCTAssertEqual(title?.last, "…")
    }

    func testHandlesShortTranscriptWithFallback() {
        let transcript = "Hello there."
        let title = TitleDeriver.derive(from: transcript)
        XCTAssertNotNil(title)
    }

    func testRunsFastOnLargeTranscript() {
        let sentence = "We need to discuss the quarterly review and align on next steps. "
        let big = String(repeating: sentence, count: 1000)
        measure {
            _ = TitleDeriver.derive(from: big)
        }
    }
}

final class SnippetDeriverTests: XCTestCase {
    func testEmptyAndNilReturnNil() {
        XCTAssertNil(SnippetDeriver.derive(from: nil))
        XCTAssertNil(SnippetDeriver.derive(from: ""))
    }

    func testPicksLongerSentenceForSnippet() {
        let transcript = """
        Hi. The dress structure looks great. We have concerns about the bodice fit on Anya's gown — \
        it needs to be re-pinned before the runway show tomorrow morning at eight a.m.
        """
        let snippet = SnippetDeriver.derive(from: transcript)
        XCTAssertNotNil(snippet)
        XCTAssertTrue(snippet!.contains("bodice"))
    }

    func testExcludesTitleSentence() {
        let transcript = """
        The new dress structure looks great. We have concerns about the bodice fit on Anya's gown — \
        it needs to be re-pinned before tomorrow morning's show.
        """
        let title = "The new dress structure looks great"
        let snippet = SnippetDeriver.derive(from: transcript, excluding: title)
        XCTAssertNotNil(snippet)
        XCTAssertFalse(snippet!.lowercased().contains("dress structure looks great"))
    }

    func testFallsBackForShortTranscript() {
        let transcript = "Hello there friend"
        let snippet = SnippetDeriver.derive(from: transcript)
        XCTAssertNotNil(snippet)
    }

    func testRunsFastOnLargeTranscript() {
        let sentence = "We need to discuss the quarterly review and align on next steps. "
        let big = String(repeating: sentence, count: 1000)
        measure {
            _ = SnippetDeriver.derive(from: big)
        }
    }
}
