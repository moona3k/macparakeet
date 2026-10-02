import XCTest
@testable import MacParakeetCore

final class PromptResultMeetingNotesStatusTests: XCTestCase {
    private func makeResult(
        promptId: UUID? = UUID(),
        promptContent: String = "Summarize.",
        userNotesSnapshot: String? = nil,
        includeMeetingNotesSnapshot: Bool = false
    ) -> PromptResult {
        PromptResult(
            transcriptionId: UUID(),
            promptId: promptId,
            promptName: "Summary",
            promptContent: promptContent,
            content: "Result",
            userNotesSnapshot: userNotesSnapshot,
            includeMeetingNotesSnapshot: includeMeetingNotesSnapshot
        )
    }

    func testRecordedNotesAreSentWhenThePromptConsumedThem() {
        XCTAssertEqual(
            makeResult(userNotesSnapshot: "Spell it Siobhan.", includeMeetingNotesSnapshot: true)
                .meetingNotesStatus,
            .sent("Spell it Siobhan."))
        XCTAssertEqual(
            makeResult(promptContent: "Notes: {{userNotes}}", userNotesSnapshot: "Agenda")
                .meetingNotesStatus,
            .sent("Agenda"))
    }

    func testEnabledResultWithoutNotesReportsNoneRecorded() {
        XCTAssertEqual(
            makeResult(includeMeetingNotesSnapshot: true).meetingNotesStatus,
            .enabledWithoutNotes)
        XCTAssertEqual(
            makeResult(userNotesSnapshot: " \n", includeMeetingNotesSnapshot: true).meetingNotesStatus,
            .enabledWithoutNotes)
        XCTAssertEqual(
            makeResult(promptContent: "Notes: {{userNotes}}").meetingNotesStatus,
            .enabledWithoutNotes)
    }

    func testLibraryResultWithNotesDisabledReportsOff() {
        XCTAssertEqual(makeResult().meetingNotesStatus, .off)
    }

    func testImportedResultWithoutReceiptIsNotRecordedRatherThanOff() {
        XCTAssertEqual(makeResult(promptId: nil).meetingNotesStatus, .notRecorded)
        XCTAssertEqual(
            makeResult(
                promptId: nil,
                promptContent: "External result imported with `macparakeet-cli meetings results add`."
            ).meetingNotesStatus,
            .notRecorded)
    }

    func testUnlinkedResultStillReportsKnownReceipts() {
        XCTAssertEqual(
            makeResult(promptId: nil, userNotesSnapshot: "Agenda", includeMeetingNotesSnapshot: true)
                .meetingNotesStatus,
            .sent("Agenda"))
        XCTAssertEqual(
            makeResult(promptId: nil, includeMeetingNotesSnapshot: true).meetingNotesStatus,
            .enabledWithoutNotes)
    }
}
