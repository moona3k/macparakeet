import XCTest
import MacParakeetViewModels
@testable import MacParakeet

@MainActor
final class SavedMeetingNotesEditorPresentationTests: XCTestCase {
    private let meetingID = UUID()
    private let otherMeetingID = UUID()

    func testWritingPromptAppearsOnlyForAnEnabledEmptyDraft() {
        for saveState in editableSaveStates {
            XCTAssertTrue(
                SavedMeetingNotesEditorPresentation.showsWritingPrompt(
                    meetingID: meetingID,
                    displayedMeetingID: meetingID,
                    saveState: saveState,
                    draft: ""
                ),
                "Empty \(saveState) draft should invite writing"
            )
        }

        XCTAssertFalse(
            SavedMeetingNotesEditorPresentation.showsWritingPrompt(
                meetingID: meetingID,
                displayedMeetingID: meetingID,
                saveState: .saved,
                draft: " "
            )
        )
        XCTAssertFalse(
            SavedMeetingNotesEditorPresentation.showsWritingPrompt(
                meetingID: meetingID,
                displayedMeetingID: meetingID,
                saveState: .saved,
                draft: "Keep the pilot small"
            )
        )
        XCTAssertFalse(
            SavedMeetingNotesEditorPresentation.showsWritingPrompt(
                meetingID: meetingID,
                displayedMeetingID: meetingID,
                saveState: .deleted,
                draft: ""
            )
        )
        XCTAssertFalse(
            SavedMeetingNotesEditorPresentation.showsWritingPrompt(
                meetingID: otherMeetingID,
                displayedMeetingID: meetingID,
                saveState: .saved,
                draft: ""
            )
        )
    }

    func testCopyPayloadStaysWithTheDisplayedMeetingAndSkipsBlankDrafts() {
        XCTAssertEqual(
            SavedMeetingNotesEditorPresentation.copyPayload(
                meetingID: meetingID,
                displayedMeetingID: meetingID,
                draft: "  Keep the pilot small  "
            ),
            "  Keep the pilot small  "
        )
        XCTAssertNil(
            SavedMeetingNotesEditorPresentation.copyPayload(
                meetingID: meetingID,
                displayedMeetingID: meetingID,
                draft: " \n\t "
            )
        )
        XCTAssertNil(
            SavedMeetingNotesEditorPresentation.copyPayload(
                meetingID: otherMeetingID,
                displayedMeetingID: meetingID,
                draft: "Notes from the previous meeting"
            )
        )
    }

    func testAccessibilityHintMatchesWhetherTheEditorCanBeEdited() {
        for saveState in editableSaveStates {
            XCTAssertEqual(
                SavedMeetingNotesEditorPresentation.accessibilityHint(
                    meetingID: meetingID,
                    displayedMeetingID: meetingID,
                    saveState: saveState
                ),
                SavedMeetingNotesEditorPresentation.editingHint
            )
            XCTAssertTrue(
                SavedMeetingNotesEditorPresentation.isEditorEnabled(
                    meetingID: meetingID,
                    displayedMeetingID: meetingID,
                    saveState: saveState
                )
            )
        }

        XCTAssertEqual(
            SavedMeetingNotesEditorPresentation.accessibilityHint(
                meetingID: meetingID,
                displayedMeetingID: meetingID,
                saveState: .deleted
            ),
            SavedMeetingNotesEditorPresentation.deletedStatus
        )
        XCTAssertFalse(
            SavedMeetingNotesEditorPresentation.isEditorEnabled(
                meetingID: meetingID,
                displayedMeetingID: meetingID,
                saveState: .deleted
            )
        )
        XCTAssertEqual(
            SavedMeetingNotesEditorPresentation.accessibilityHint(
                meetingID: otherMeetingID,
                displayedMeetingID: meetingID,
                saveState: .deleted
            ),
            SavedMeetingNotesEditorPresentation.unavailableHint
        )
        XCTAssertFalse(
            SavedMeetingNotesEditorPresentation.accessibilityHint(
                meetingID: nil,
                displayedMeetingID: meetingID,
                saveState: .saved
            ).contains("save automatically")
        )
    }

    private var editableSaveStates: [SavedMeetingNotesViewModel.SaveState] {
        [.saved, .saving, .failed]
    }
}

@MainActor
final class SavedMeetingNotesCopyFeedbackTests: XCTestCase {
    private final class ManualTimer {
        private let ticks: AsyncStream<Void>
        private let tickContinuation: AsyncStream<Void>.Continuation
        var onSleep: (() -> Void)?

        init() {
            var continuation: AsyncStream<Void>.Continuation?
            ticks = AsyncStream { continuation = $0 }
            tickContinuation = continuation!
        }

        func sleep(for _: Duration) async throws {
            try Task.checkCancellation()
            onSleep?()
            var iterator = ticks.makeAsyncIterator()
            guard await iterator.next() != nil else { throw CancellationError() }
            try Task.checkCancellation()
        }

        func advance() {
            tickContinuation.yield()
        }
    }

    func testCopiedConfirmationExpires() async {
        let timer = ManualTimer()
        let confirmationStarted = expectation(description: "Copy confirmation timer started")
        timer.onSleep = { confirmationStarted.fulfill() }
        let feedback = SavedMeetingNotesCopyFeedback(
            duration: .seconds(1),
            waitForConfirmation: timer.sleep
        )

        feedback.noteCopied()
        XCTAssertTrue(feedback.isCopied)
        await fulfillment(of: [confirmationStarted], timeout: 1)

        timer.advance()
        await waitUntil { !feedback.isCopied }
        XCTAssertFalse(feedback.isCopied)
    }

    func testResetClearsCopiedConfirmationBeforeTheTimerFires() async {
        let timer = ManualTimer()
        let confirmationStarted = expectation(description: "Copy confirmation timer started")
        timer.onSleep = { confirmationStarted.fulfill() }
        let feedback = SavedMeetingNotesCopyFeedback(
            duration: .seconds(1),
            waitForConfirmation: timer.sleep
        )

        feedback.noteCopied()
        await fulfillment(of: [confirmationStarted], timeout: 1)
        feedback.reset()
        XCTAssertFalse(feedback.isCopied)

        timer.advance()
        await Task.yield()
        XCTAssertFalse(feedback.isCopied)
    }

    func testALaterCopySurvivesResetOfThePreviousConfirmation() async {
        let timer = ManualTimer()
        let firstConfirmation = expectation(description: "First copy confirmation timer started")
        timer.onSleep = { firstConfirmation.fulfill() }
        let feedback = SavedMeetingNotesCopyFeedback(
            duration: .seconds(1),
            waitForConfirmation: timer.sleep
        )

        feedback.noteCopied()
        await fulfillment(of: [firstConfirmation], timeout: 1)
        feedback.reset()
        timer.advance()
        await Task.yield()

        let secondConfirmation = expectation(description: "Second copy confirmation timer started")
        timer.onSleep = { secondConfirmation.fulfill() }
        feedback.noteCopied()
        XCTAssertTrue(feedback.isCopied)
        await fulfillment(of: [secondConfirmation], timeout: 1)

        timer.advance()
        await waitUntil { !feedback.isCopied }
        XCTAssertFalse(feedback.isCopied)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(1)
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }
}
