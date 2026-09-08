import XCTest
import MacParakeetViewModels
@testable import MacParakeet

@MainActor
final class SavedMeetingNotesSaveStatusPresentationTests: XCTestCase {
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

    func testShowsOnlySuccessfulSaveDuringVisiblePaneAndThenExpires() async {
        let timer = ManualTimer()
        let confirmationStarted = expectation(description: "Confirmation timer started")
        timer.onSleep = { confirmationStarted.fulfill() }
        let presentation = SavedMeetingNotesSaveStatusPresentation(
            duration: .seconds(1),
            waitForConfirmation: timer.sleep
        )
        let meetingID = UUID()

        presentation.beginPresentation(
            meetingID: meetingID,
            displayedMeetingID: meetingID,
            saveState: .saved
        )
        XCTAssertFalse(presentation.showsSaveConfirmation)

        presentation.observeSaveStateChange(
            from: .saved,
            to: .saving,
            meetingID: meetingID,
            displayedMeetingID: meetingID
        )
        XCTAssertFalse(presentation.showsSaveConfirmation)

        presentation.observeSaveStateChange(
            from: .saving,
            to: .saved,
            meetingID: meetingID,
            displayedMeetingID: meetingID
        )
        XCTAssertTrue(presentation.showsSaveConfirmation)
        await fulfillment(of: [confirmationStarted], timeout: 1)

        timer.advance()
        let deadline = ContinuousClock.now + .seconds(1)
        while presentation.showsSaveConfirmation, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(presentation.showsSaveConfirmation)
    }

    func testNewEditFailureOrReplacementEditorCannotLeaveStaleConfirmation() async {
        let timer = ManualTimer()
        let confirmationStarted = expectation(description: "Confirmation timer started")
        timer.onSleep = { confirmationStarted.fulfill() }
        let presentation = SavedMeetingNotesSaveStatusPresentation(
            duration: .seconds(1),
            waitForConfirmation: timer.sleep
        )
        let firstMeetingID = UUID()
        let replacementMeetingID = UUID()

        presentation.beginPresentation(
            meetingID: firstMeetingID,
            displayedMeetingID: firstMeetingID,
            saveState: .saving
        )
        presentation.observeSaveStateChange(
            from: .saving,
            to: .saved,
            meetingID: firstMeetingID,
            displayedMeetingID: firstMeetingID
        )
        XCTAssertTrue(presentation.showsSaveConfirmation)
        await fulfillment(of: [confirmationStarted], timeout: 1)

        presentation.observeSaveStateChange(
            from: .saved,
            to: .saving,
            meetingID: firstMeetingID,
            displayedMeetingID: firstMeetingID
        )
        presentation.observeSaveStateChange(
            from: .saving,
            to: .failed,
            meetingID: firstMeetingID,
            displayedMeetingID: firstMeetingID
        )
        XCTAssertFalse(presentation.showsSaveConfirmation)

        timer.advance()
        await Task.yield()
        XCTAssertFalse(presentation.showsSaveConfirmation)

        presentation.observeSaveStateChange(
            from: .saving,
            to: .saved,
            meetingID: replacementMeetingID,
            displayedMeetingID: replacementMeetingID
        )
        XCTAssertFalse(presentation.showsSaveConfirmation)
    }
}
