import XCTest
import MacParakeetCore
@testable import MacParakeet

final class PromptManagementPresentationTests: XCTestCase {
    func testPromptLibraryOnlyIncludesTranscriptPromptsInEveryPresentation() {
        for presentation in [
            PromptLibraryPresentation.library,
            PromptLibraryPresentation.meetingAutoNotes,
        ] {
            XCTAssertTrue(presentation.includes(category: .result))
            XCTAssertFalse(presentation.includes(category: .transform))
            XCTAssertEqual(presentation.creationCategory, .result)
        }
    }

    func testPromptsWorkspaceDefaultsToTranscriptPrompts() {
        XCTAssertEqual(PromptsWorkspaceSection.defaultSection, .transcriptPrompts)
        XCTAssertEqual(
            PromptsWorkspaceSection.allCases,
            [.transcriptPrompts, .liveAsk]
        )
    }

    func testPromptLibraryDropsSheetMinimumSizeWhenEmbedded() {
        // Default window is 860pt; sidebar ideal is 200pt, so the detail
        // column is ~660pt. The 720pt sheet floor overflows that column and
        // clips Transcript prompts while Live Ask (already embedded) does not.
        let detailColumnWidth =
            860 - DesignSystem.Layout.sidebarMinWidth
        XCTAssertLessThan(detailColumnWidth, PromptLibraryView.sheetMinWidth)

        XCTAssertNil(PromptLibraryView.minimumWidth(isEmbedded: true))
        XCTAssertNil(PromptLibraryView.minimumHeight(isEmbedded: true))
        XCTAssertEqual(PromptLibraryView.minimumWidth(isEmbedded: false), 720)
        XCTAssertEqual(PromptLibraryView.minimumHeight(isEmbedded: false), 560)
    }
}
