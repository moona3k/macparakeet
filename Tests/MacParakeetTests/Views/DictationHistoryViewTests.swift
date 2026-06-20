import XCTest
@testable import MacParakeet

final class DictationHistoryViewTests: XCTestCase {
    func testShortDictationTextHasNoCollapsedLineLimit() {
        let text = "Send the launch notes to Sarah before standup."

        XCTAssertFalse(DictationTranscriptPresentation.isExpandable(text))
        XCTAssertNil(DictationTranscriptPresentation.lineLimit(for: text, isExpanded: false))
    }

    func testLongDictationTextCollapsesToPreviewLineLimit() {
        let text = Array(repeating: "This is a longer dictated note that should stay compact in the history list.", count: 5)
            .joined(separator: " ")

        XCTAssertTrue(DictationTranscriptPresentation.isExpandable(text))
        XCTAssertEqual(
            DictationTranscriptPresentation.lineLimit(for: text, isExpanded: false),
            DictationTranscriptPresentation.collapsedLineLimit
        )
    }

    func testExpandedLongDictationTextRemovesLineLimit() {
        let text = Array(repeating: "Expanded text should be readable and selectable inside the note.", count: 6)
            .joined(separator: " ")

        XCTAssertTrue(DictationTranscriptPresentation.isExpandable(text))
        XCTAssertNil(DictationTranscriptPresentation.lineLimit(for: text, isExpanded: true))
    }

    func testMultiParagraphDictationTextIsExpandableEvenWhenBrief() {
        let text = """
        First thought.
        Second thought.
        Third thought.
        Fourth thought.
        """

        XCTAssertTrue(DictationTranscriptPresentation.isExpandable(text))
        XCTAssertEqual(
            DictationTranscriptPresentation.lineLimit(for: text, isExpanded: false),
            DictationTranscriptPresentation.collapsedLineLimit
        )
    }
}
