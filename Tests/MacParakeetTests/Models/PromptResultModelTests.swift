import XCTest
@testable import MacParakeetCore

final class PromptResultModelTests: XCTestCase {
    func testDisplayableUserNotesSnapshotOmitsNilAndBlankValues() {
        XCTAssertNil(
            PromptResult(
                transcriptionId: UUID(),
                promptName: "Prompt",
                promptContent: "Prompt content",
                content: "Result"
            ).displayableUserNotesSnapshot
        )

        XCTAssertNil(
            PromptResult(
                transcriptionId: UUID(),
                promptName: "Prompt",
                promptContent: "Prompt content",
                content: "Result",
                userNotesSnapshot: " \n\t "
            ).displayableUserNotesSnapshot
        )
    }

    func testDisplayableUserNotesSnapshotPreservesOriginalFormatting() {
        let notes = """
            ## Plan

            - Ship Friday
              - QA owns smoke
            """.replacingOccurrences(of: "            ", with: "")

        let result = PromptResult(
            transcriptionId: UUID(),
            promptName: "Prompt",
            promptContent: "Prompt content",
            content: "Result",
            userNotesSnapshot: notes
        )

        XCTAssertEqual(result.displayableUserNotesSnapshot, notes)
    }
}
