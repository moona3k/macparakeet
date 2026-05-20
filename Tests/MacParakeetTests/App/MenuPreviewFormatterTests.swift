import XCTest
@testable import MacParakeet

final class MenuPreviewFormatterTests: XCTestCase {
    func testDictationTitleCollapsesWhitespaceAndTruncates() {
        let title = MenuPreviewFormatter.dictationTitle(
            text: "  one\n\ttwo   three four five six seven eight nine ten eleven  "
        )

        XCTAssertEqual(title, "one two three four five six seven eight…")
    }

    func testTransformTitleStripsMarkdownPresentation() {
        let title = MenuPreviewFormatter.transformTitle(
            outputText: "**The question** — Should `Option+2` own this?"
        )

        XCTAssertEqual(title, "The question — Should Option+2 own this?")
    }

    func testTransformTitleRemovesLeadingListMarkerAndCollapsesWhitespace() {
        let title = MenuPreviewFormatter.transformTitle(
            outputText: "• **Committed** `d5405686`\n\tto `origin/main`"
        )

        XCTAssertEqual(title, "Committed d5405686 to origin/main")
    }

    func testTransformTitleFallsBackWhenOutputHasOnlyPresentationMarkers() {
        let title = MenuPreviewFormatter.transformTitle(
            outputText: "  **  `  "
        )

        XCTAssertEqual(title, "Transform result")
    }
}
