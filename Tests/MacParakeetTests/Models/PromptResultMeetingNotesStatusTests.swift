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

    func testOmissionNoticeAppearsOnlyWhenCurrentNotesWereLeftOut() throws {
        let off = makeResult()
        XCTAssertNil(MeetingResultNotesNotice.notice(status: off.meetingNotesStatus, currentNotes: nil))
        XCTAssertNil(MeetingResultNotesNotice.notice(status: off.meetingNotesStatus, currentNotes: " \n\t"))
        let disabled = try XCTUnwrap(
            MeetingResultNotesNotice.notice(status: off.meetingNotesStatus, currentNotes: "Spell it Siobhan.")
        )
        XCTAssertEqual(disabled, .disabled)
        XCTAssertTrue(disabled.explanation.contains("Regenerate keeps the original setting"))

        let enabled = makeResult(includeMeetingNotesSnapshot: true)
        XCTAssertNil(
            MeetingResultNotesNotice.notice(status: enabled.meetingNotesStatus, currentNotes: nil))
        let addedLater = try XCTUnwrap(
            MeetingResultNotesNotice.notice(status: enabled.meetingNotesStatus, currentNotes: "Agenda")
        )
        XCTAssertEqual(addedLater, .emptyWhenGenerated)
        XCTAssertTrue(addedLater.explanation.contains("Regenerate to use your current notes"))

        let sent = makeResult(userNotesSnapshot: "Agenda", includeMeetingNotesSnapshot: true)
        XCTAssertNil(
            MeetingResultNotesNotice.notice(status: sent.meetingNotesStatus, currentNotes: "Agenda"))

        let imported = makeResult(promptId: nil)
        XCTAssertNil(
            MeetingResultNotesNotice.notice(status: imported.meetingNotesStatus, currentNotes: "Agenda"))
        XCTAssertEqual(MeetingResultNotesNotice.title, "Notes not included")
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
