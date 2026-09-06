import XCTest
@testable import MacParakeetViewModels

@MainActor
final class SavedMeetingNotesViewModelTests: XCTestCase {
    private let meetingID = UUID()

    func testFlushRetiresDraftOnlyAfterConfirmedMeetingDeletion() async {
        let viewModel = SavedMeetingNotesViewModel()
        viewModel.configure(meetingID: meetingID, text: "Original", isMeetingDeleted: { true }) { _ in
            XCTFail("Do not recreate or update a deleted meeting")
            return false
        }
        viewModel.textBinding.wrappedValue = "Still available to copy"

        let flushed = await viewModel.flush()

        XCTAssertTrue(flushed)
        XCTAssertFalse(viewModel.hasUnsavedChanges)
        XCTAssertEqual(viewModel.saveState, .deleted)
        XCTAssertEqual(viewModel.text, "Still available to copy")
        viewModel.textBinding.wrappedValue = "New edit after deletion"
        XCTAssertEqual(viewModel.text, "Still available to copy")
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    func testFlushRecognizesDeletionBetweenExistenceCheckAndWrite() async {
        let viewModel = SavedMeetingNotesViewModel()
        var deleted = false
        viewModel.configure(meetingID: meetingID, text: "Original", isMeetingDeleted: { deleted }) { _ in
            deleted = true
            return false
        }
        viewModel.textBinding.wrappedValue = "Draft"

        let flushed = await viewModel.flush()

        XCTAssertTrue(flushed)
        XCTAssertEqual(viewModel.saveState, .deleted)
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    func testDeletionReadFailureRetainsDraftAndBlocksFlush() async {
        let viewModel = SavedMeetingNotesViewModel()
        viewModel.configure(meetingID: meetingID, text: "Original", isMeetingDeleted: {
            throw NSError(domain: "database-read", code: 1)
        }) { _ in
            XCTFail("A failed existence read must not discard the draft")
            return true
        }
        viewModel.textBinding.wrappedValue = "Keep this draft"

        let flushed = await viewModel.flush()

        XCTAssertFalse(flushed)
        XCTAssertEqual(viewModel.saveState, .failed)
        XCTAssertTrue(viewModel.hasUnsavedChanges)
        XCTAssertEqual(viewModel.text, "Keep this draft")
    }

    func testObsoleteDeletionCheckCannotRetireOrFailNewMeeting() async {
        for failRead in [false, true] {
            let viewModel = SavedMeetingNotesViewModel()
            let readStarted = expectation(description: "Old meeting read started")
            var releaseRead: (() -> Void)?
            viewModel.configure(meetingID: meetingID, text: "A", isMeetingDeleted: {
                readStarted.fulfill()
                await withCheckedContinuation { continuation in
                    releaseRead = { continuation.resume() }
                }
                if failRead { throw NSError(domain: "database-read", code: 1) }
                return true
            }) { _ in false }
            viewModel.textBinding.wrappedValue = "A draft"
            let oldFlush = Task { @MainActor in await viewModel.flush() }
            await fulfillment(of: [readStarted], timeout: 1)

            let nextMeetingID = UUID()
            var newMeetingWrites: [String] = []
            viewModel.configure(meetingID: nextMeetingID, text: "B") { text in
                newMeetingWrites.append(text)
                return true
            }
            viewModel.textBinding.wrappedValue = "B draft"
            viewModel.cancelPendingSave()
            releaseRead?()
            let obsoleteFlushSucceeded = await oldFlush.value

            XCTAssertFalse(obsoleteFlushSucceeded)
            XCTAssertEqual(viewModel.meetingID, nextMeetingID)
            XCTAssertEqual(viewModel.text, "B draft")
            XCTAssertEqual(viewModel.saveState, .saving)
            XCTAssertTrue(viewModel.hasUnsavedChanges)
            XCTAssertTrue(newMeetingWrites.isEmpty)
            let newFlushSucceeded = await viewModel.flush()
            XCTAssertTrue(newFlushSucceeded)
            XCTAssertEqual(newMeetingWrites, ["B draft"])
        }
    }

    func testBindingForNewSelectionCannotReadOrEditPreviousMeeting() async {
        let viewModel = SavedMeetingNotesViewModel()
        var writes: [String] = []
        viewModel.configure(meetingID: meetingID, text: "Meeting A") { text in
            writes.append(text)
            return true
        }
        let otherMeetingBinding = viewModel.textBinding(for: UUID())
        XCTAssertEqual(otherMeetingBinding.wrappedValue, "")
        otherMeetingBinding.wrappedValue = "Typed under meeting B"
        XCTAssertEqual(viewModel.text, "Meeting A")
        XCTAssertFalse(viewModel.hasUnsavedChanges)
        let saved = await viewModel.flush()
        XCTAssertTrue(saved)
        XCTAssertTrue(writes.isEmpty)
    }

    @MainActor
    private final class ManualDebounceClock {
        private let ticks: AsyncStream<Void>
        private let tickContinuation: AsyncStream<Void>.Continuation
        var onSleep: (() -> Void)?
        var onWake: (() -> Void)?

        init() {
            var continuation: AsyncStream<Void>.Continuation?
            ticks = AsyncStream { continuation = $0 }
            tickContinuation = continuation!
        }

        func sleep(for _: Duration) async throws {
            try Task.checkCancellation()
            onSleep?()
            defer { onWake?() }
            var iterator = ticks.makeAsyncIterator()
            guard await iterator.next() != nil else { throw CancellationError() }
            try Task.checkCancellation()
        }

        func advance() {
            tickContinuation.yield()
        }
    }

    func testConfigureRestoresTextWithoutWriting() async {
        let viewModel = SavedMeetingNotesViewModel()
        var writes: [String] = []

        viewModel.configure(meetingID: meetingID, text: "Existing notes") { text in
            writes.append(text)
            return true
        }

        XCTAssertEqual(viewModel.text, "Existing notes")
        XCTAssertEqual(viewModel.wordCount, 2)
        XCTAssertEqual(viewModel.saveState, .saved)
        XCTAssertTrue(writes.isEmpty)
    }

    func testRapidEditsAutosaveOnlyLatestDraft() async {
        let clock = ManualDebounceClock()
        let debounceStarted = expectation(description: "Debounce started")
        let autosaveCompleted = expectation(description: "Autosave completed")
        clock.onSleep = { debounceStarted.fulfill() }
        let viewModel = SavedMeetingNotesViewModel(waitForDebounce: clock.sleep)
        var writes: [String] = []
        viewModel.configure(meetingID: meetingID, text: nil) { text in
            writes.append(text)
            autosaveCompleted.fulfill()
            return true
        }

        viewModel.textBinding.wrappedValue = "First"
        viewModel.textBinding.wrappedValue = "First second"

        await fulfillment(of: [debounceStarted], timeout: 1)
        clock.advance()
        await fulfillment(of: [autosaveCompleted], timeout: 1)

        XCTAssertEqual(writes, ["First second"])
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    func testFlushPersistsImmediatelyAndCancelsDebounce() async {
        let clock = ManualDebounceClock()
        let debounceStarted = expectation(description: "Debounce started")
        let debounceFinished = expectation(description: "Debounce finished")
        clock.onSleep = { debounceStarted.fulfill() }
        clock.onWake = { debounceFinished.fulfill() }
        let viewModel = SavedMeetingNotesViewModel(waitForDebounce: clock.sleep)
        var writes: [String] = []
        viewModel.configure(meetingID: meetingID, text: nil) { text in
            writes.append(text)
            return true
        }
        viewModel.textBinding.wrappedValue = "Latest context"
        await fulfillment(of: [debounceStarted], timeout: 1)

        let flushed = await viewModel.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(writes, ["Latest context"])

        clock.advance()
        await fulfillment(of: [debounceFinished], timeout: 1)
        XCTAssertEqual(writes, ["Latest context"])
    }

    func testFailedSaveKeepsDraftAndRetryPersistsIt() async {
        let viewModel = SavedMeetingNotesViewModel()
        var shouldSucceed = false
        var writes: [String] = []
        viewModel.configure(meetingID: meetingID, text: nil) { text in
            writes.append(text)
            return shouldSucceed
        }
        viewModel.textBinding.wrappedValue = "Keep this draft"

        let firstFlush = await viewModel.flush()
        XCTAssertFalse(firstFlush)
        XCTAssertEqual(viewModel.text, "Keep this draft")
        XCTAssertEqual(viewModel.saveState, .failed)

        shouldSucceed = true
        let retried = await viewModel.retry()
        XCTAssertTrue(retried)
        XCTAssertEqual(writes, ["Keep this draft", "Keep this draft"])
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    func testFlushDuringSlowAutosaveDoesNotDuplicateWrite() async {
        let clock = ManualDebounceClock()
        let debounceStarted = expectation(description: "Debounce started")
        let saveStarted = expectation(description: "Save started")
        var releaseSave: (() -> Void)?
        clock.onSleep = { debounceStarted.fulfill() }
        let viewModel = SavedMeetingNotesViewModel(waitForDebounce: clock.sleep)
        var writes: [String] = []
        viewModel.configure(meetingID: meetingID, text: nil) { text in
            writes.append(text)
            saveStarted.fulfill()
            await withCheckedContinuation { continuation in
                releaseSave = { continuation.resume() }
            }
            return true
        }
        viewModel.textBinding.wrappedValue = "One write"

        await fulfillment(of: [debounceStarted], timeout: 1)
        clock.advance()
        await fulfillment(of: [saveStarted], timeout: 1)
        let flushTask = Task { @MainActor in await viewModel.flush() }
        releaseSave?()
        let flushed = await flushTask.value

        XCTAssertTrue(flushed)
        XCTAssertEqual(writes, ["One write"])
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    func testNewEditPersistsAfterOlderInFlightSaveFails() async {
        let viewModel = SavedMeetingNotesViewModel()
        var writes: [String] = []
        let oldSaveStarted = expectation(description: "Old save started")
        var releaseOldSave: (() -> Void)?
        viewModel.configure(meetingID: meetingID, text: nil) { text in
            writes.append(text)
            if text == "Old draft" {
                oldSaveStarted.fulfill()
                await withCheckedContinuation { continuation in
                    releaseOldSave = { continuation.resume() }
                }
                return false
            }
            return true
        }
        viewModel.textBinding.wrappedValue = "Old draft"
        let oldFlush = Task { @MainActor in
            await viewModel.flush()
        }
        await fulfillment(of: [oldSaveStarted], timeout: 1)
        viewModel.textBinding.wrappedValue = "Latest draft"
        releaseOldSave?()

        let flushed = await viewModel.flush()
        let oldFlushed = await oldFlush.value

        XCTAssertFalse(oldFlushed)
        XCTAssertTrue(flushed)
        XCTAssertEqual(writes, ["Old draft", "Latest draft"])
        XCTAssertEqual(viewModel.saveState, .saved)
    }

    func testFlushesWaitingOnOldWriteCannotPersistReconfiguredMeeting() async {
        for editNewMeeting in [false, true] {
            let viewModel = SavedMeetingNotesViewModel()
            let oldSaveStarted = expectation(description: "Old write started")
            let secondFlushStarted = expectation(description: "Second flush started")
            var releaseOldSave: (() -> Void)?
            viewModel.configure(meetingID: meetingID, text: "A") { _ in
                oldSaveStarted.fulfill()
                await withCheckedContinuation { continuation in
                    releaseOldSave = { continuation.resume() }
                }
                return true
            }
            viewModel.textBinding.wrappedValue = "A draft"
            let firstFlush = Task { @MainActor in await viewModel.flush() }
            await fulfillment(of: [oldSaveStarted], timeout: 1)
            let secondFlush = Task { @MainActor in
                secondFlushStarted.fulfill()
                return await viewModel.flush()
            }
            await fulfillment(of: [secondFlushStarted], timeout: 1)

            let nextMeetingID = UUID()
            var newWrites: [String] = []
            viewModel.configure(meetingID: nextMeetingID, text: "B") { text in
                newWrites.append(text)
                return true
            }
            if editNewMeeting {
                viewModel.textBinding.wrappedValue = "B draft"
                viewModel.cancelPendingSave()
            }
            releaseOldSave?()
            let firstSaved = await firstFlush.value
            let secondSaved = await secondFlush.value

            XCTAssertFalse(firstSaved)
            XCTAssertFalse(secondSaved)
            XCTAssertTrue(newWrites.isEmpty, "An obsolete flush must not write the replacement meeting")
            XCTAssertEqual(viewModel.meetingID, nextMeetingID)
            XCTAssertEqual(viewModel.text, editNewMeeting ? "B draft" : "B")
            XCTAssertEqual(viewModel.hasUnsavedChanges, editNewMeeting)
            XCTAssertEqual(viewModel.saveState, editNewMeeting ? .saving : .saved)

            let currentSaved = await viewModel.flush()
            XCTAssertTrue(currentSaved)
            XCTAssertEqual(newWrites, editNewMeeting ? ["B draft"] : [])
        }
    }
}
