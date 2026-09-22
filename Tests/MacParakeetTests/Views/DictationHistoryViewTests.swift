import XCTest
@testable import MacParakeet

final class DictationHistoryViewTests: XCTestCase {
    func testFullyVisibleTranscriptNeedsNoExpansionControl() {
        XCTAssertFalse(
            DictationTranscriptPresentation.isExpandable(
                fullHeight: 42,
                collapsedHeight: 42
            )
        )
    }

    func testTranscriptTallerThanCollapsedPreviewCanExpand() {
        XCTAssertTrue(
            DictationTranscriptPresentation.isExpandable(
                fullHeight: 84,
                collapsedHeight: 42
            )
        )
    }

    func testSubPointMeasurementNoiseDoesNotOfferExpansion() {
        XCTAssertFalse(
            DictationTranscriptPresentation.isExpandable(
                fullHeight: 42.4,
                collapsedHeight: 42
            )
        )
    }

    func testTranscriptDoesNotCollapseWithoutToggleSupport() {
        XCTAssertFalse(
            DictationTranscriptPresentation.isExpandable(
                fullHeight: 84,
                collapsedHeight: 42,
                canToggleExpansion: false
            )
        )
        XCTAssertNil(
            DictationTranscriptPresentation.previewLineLimit(canToggleExpansion: false)
        )
    }

    func testToggleSupportUsesThreeLinePreviewWhileMeasuring() {
        XCTAssertEqual(
            DictationTranscriptPresentation.previewLineLimit(canToggleExpansion: true),
            DictationTranscriptPresentation.collapsedLineLimit
        )
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
        let pendingHeight =
            DictationTranscriptPresentation
            .resetMeasuredExpandedContentHeight(isCurrentlyExpanded: true)

        XCTAssertEqual(
            DictationTranscriptPresentation.expandedViewportHeight(forMeasuredContentHeight: pendingHeight),
            DictationTranscriptPresentation.expandedBoxMaxHeight
        )
    }
}
