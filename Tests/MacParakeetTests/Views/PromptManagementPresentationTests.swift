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
}
