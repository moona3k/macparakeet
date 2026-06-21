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

    func testLongDictationTextDoesNotCollapseWithoutToggleSupport() {
        let text = Array(repeating: "This is a longer dictated note that cannot be expanded in this context.", count: 5)
            .joined(separator: " ")

        XCTAssertFalse(DictationTranscriptPresentation.isExpandable(text, canToggleExpansion: false))
        XCTAssertNil(
            DictationTranscriptPresentation.lineLimit(
                for: text,
                isExpanded: false,
                canToggleExpansion: false
            )
        )
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

    func testWindowsLineEndingsDoNotDoubleCountParagraphBreaks() {
        let text = "First paragraph.\r\nSecond paragraph.\r\nThird paragraph."

        XCTAssertFalse(DictationTranscriptPresentation.isExpandable(text))
        XCTAssertNil(DictationTranscriptPresentation.lineLimit(for: text, isExpanded: false))
    }

    func testExpandedViewportDoesNotForceCapBeforeContentIsMeasured() {
        XCTAssertNil(
            DictationTranscriptPresentation.expandedViewportHeight(forMeasuredContentHeight: 0)
        )
    }

    func testExpandedViewportIsUnfixedWhenMeasuredContentFits() {
        XCTAssertNil(
            DictationTranscriptPresentation.expandedViewportHeight(forMeasuredContentHeight: 120)
        )
    }

    func testExpandedViewportCapsMeasuredContentWhenTallerThanCap() {
        XCTAssertEqual(
            DictationTranscriptPresentation.expandedViewportHeight(forMeasuredContentHeight: 640),
            DictationTranscriptPresentation.expandedBoxMaxHeight
        )
    }

    func testCollapsedTextChangesResetMeasurementToUnknownNaturalHeight() {
        XCTAssertEqual(
            DictationTranscriptPresentation.resetMeasuredExpandedContentHeight(isCurrentlyExpanded: false),
            0
        )
    }

    func testExpandedTextChangesStayCappedWhileRemeasuring() {
        let pendingHeight = DictationTranscriptPresentation
            .resetMeasuredExpandedContentHeight(isCurrentlyExpanded: true)

        XCTAssertEqual(
            DictationTranscriptPresentation.expandedViewportHeight(forMeasuredContentHeight: pendingHeight),
            DictationTranscriptPresentation.expandedBoxMaxHeight
        )
    }
}
