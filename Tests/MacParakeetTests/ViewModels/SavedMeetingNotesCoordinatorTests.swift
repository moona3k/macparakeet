import XCTest
@testable import MacParakeetViewModels

@MainActor
final class SavedMeetingNotesCoordinatorTests: XCTestCase {
    func testFailedOldSaveCannotBindNewMeetingToOldDraft() async {
        let coordinator = SavedMeetingNotesCoordinator()
        let meetingA = UUID()
        let meetingB = UUID()
        var writesA: [String] = []
        var writesB: [String] = []
        let editorA = coordinator.editor(meetingID: meetingA, text: "A original") { text in
            writesA.append(text)
            return false
        }
        editorA.textBinding.wrappedValue = "A draft"
        let savedA = await editorA.flush()
        XCTAssertFalse(savedA)

        let editorB = coordinator.editor(meetingID: meetingB, text: "B original") { text in
            writesB.append(text)
            return true
        }
        XCTAssertEqual(editorB.text, "B original")
        editorB.textBinding(for: meetingB).wrappedValue = "B draft"
        let savedB = await editorB.flush()

        XCTAssertTrue(savedB)
        XCTAssertEqual(writesA, ["A draft"])
        XCTAssertEqual(writesB, ["B draft"])
        XCTAssertEqual(editorA.text, "A draft")
        XCTAssertTrue(coordinator.hasUnsavedChanges)
        let reopenedA = coordinator.editor(meetingID: meetingA, text: "A stale database value") { _ in
            XCTFail("The existing dirty draft must retain its persistence operation")
            return true
        }
        XCTAssertTrue(reopenedA === editorA)
        XCTAssertEqual(reopenedA.text, "A draft")
    }

    func testSwitchingAndReturningDuringSavePreservesLatestDraft() async {
        let coordinator = SavedMeetingNotesCoordinator()
        let meetingA = UUID()
        let saveStarted = expectation(description: "A save started")
        var releaseSave: (() -> Void)?
        var writesA: [String] = []
        let editorA = coordinator.editor(meetingID: meetingA, text: "A original") { text in
            writesA.append(text)
            if writesA.count == 1 {
                saveStarted.fulfill()
                await withCheckedContinuation { continuation in
                    releaseSave = { continuation.resume() }
                }
            }
            return true
        }
        editorA.textBinding.wrappedValue = "A updated"
        let savingA = Task { @MainActor in await editorA.flush() }
        await fulfillment(of: [saveStarted], timeout: 1)

        let editorB = coordinator.editor(meetingID: UUID(), text: "B original") { _ in true }
        let returnedA = coordinator.editor(meetingID: meetingA, text: "A original") { _ in true }
        XCTAssertTrue(returnedA === editorA)
        XCTAssertEqual(returnedA.text, "A updated")
        returnedA.textBinding.wrappedValue = "A latest"
        returnedA.cancelPendingSave()
        releaseSave?()
        let saved = await savingA.value

        XCTAssertTrue(saved)
        XCTAssertEqual(writesA, ["A updated", "A latest"])
        XCTAssertEqual(editorB.text, "B original")
        XCTAssertFalse(coordinator.hasUnsavedChanges)
    }

    func testCleanEditorsAreNotRetainedAndReopeningUsesCurrentDatabaseNotes() async {
        let coordinator = SavedMeetingNotesCoordinator()
        let meetingID = UUID()
        let editor = coordinator.editor(meetingID: meetingID, text: "Original") { _ in true }
        XCTAssertFalse(coordinator.hasUnsavedChanges)
        editor.textBinding.wrappedValue = "Updated"
        let saved = await editor.flush()
        XCTAssertTrue(saved)
        XCTAssertFalse(coordinator.hasUnsavedChanges)

        let reopened = coordinator.editor(meetingID: meetingID, text: "Edited through CLI") { _ in true }
        XCTAssertFalse(reopened === editor)
        XCTAssertEqual(reopened.text, "Edited through CLI")
    }

    func testQuitWaitsForDraftAfterViewHasReleasedEditorAndRepliesOnlyOnce() async {
        let coordinator = SavedMeetingNotesCoordinator()
        let saveStarted = expectation(description: "Save started")
        let quitReplied = expectation(description: "Quit replied")
        var releaseSave: (() -> Void)?
        var writes: [String] = []
        var replies: [Bool] = []
        var editor: SavedMeetingNotesViewModel? = coordinator.editor(meetingID: UUID(), text: nil) { text in
            writes.append(text)
            saveStarted.fulfill()
            await withCheckedContinuation { continuation in
                releaseSave = { continuation.resume() }
            }
            return true
        }
        weak var retainedDraft = editor
        editor?.textBinding.wrappedValue = "Last keystroke before quit"
        editor = nil
        XCTAssertNotNil(retainedDraft)

        XCTAssertTrue(
            coordinator.prepareToQuit { saved in
                replies.append(saved)
                quitReplied.fulfill()
            })
        await fulfillment(of: [saveStarted], timeout: 1)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertTrue(coordinator.isPreparingToQuit)
        XCTAssertTrue(
            coordinator.prepareToQuit { _ in
                XCTFail("A duplicate quit request must not schedule another reply")
            })
        releaseSave?()
        await fulfillment(of: [quitReplied], timeout: 1)

        XCTAssertEqual(replies, [true])
        XCTAssertFalse(coordinator.isPreparingToQuit)
        XCTAssertEqual(writes, ["Last keystroke before quit"])
        XCTAssertFalse(coordinator.hasUnsavedChanges)
    }

    func testQuitRefreshesDatabaseCleanEditorRetainedAfterAutosave() async {
        let coordinator = SavedMeetingNotesCoordinator()
        let meetingID = UUID()
        let saved = expectation(description: "Database autosave completed")
        let replied = expectation(description: "Quit replied after derived refresh")
        var refreshCount = 0
        var editor: SavedMeetingNotesViewModel? = coordinator.editor(
            meetingID: meetingID, text: nil,
            onFlush: { refreshCount += 1 }
        ) { _ in
            saved.fulfill()
            return true
        }
        editor?.textBinding.wrappedValue = "Durable notes"
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertFalse(editor?.hasUnsavedChanges ?? true)
        XCTAssertEqual(refreshCount, 0)
        XCTAssertTrue(coordinator.hasUnsavedChanges)
        weak var retained = editor
        editor = nil
        XCTAssertNotNil(retained)
        let reopened = coordinator.editor(meetingID: meetingID, text: "Durable notes") { _ in true }
        XCTAssertTrue(reopened === retained)
        XCTAssertTrue(coordinator.prepareToQuit { allowed in
            XCTAssertTrue(allowed)
            XCTAssertEqual(refreshCount, 1)
            replied.fulfill()
        })
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertFalse(coordinator.hasUnsavedChanges)
        XCTAssertFalse(reopened.hasPendingFlush)
    }

    func testFailedQuitKeepsDraftAvailableForRetry() async {
        let coordinator = SavedMeetingNotesCoordinator()
        let meetingID = UUID()
        var canSave = false
        var writes: [String] = []
        var editor: SavedMeetingNotesViewModel? = coordinator.editor(meetingID: meetingID, text: nil) { text in
            writes.append(text)
            return canSave
        }
        editor?.textBinding.wrappedValue = "Preserve after window close"
        editor = nil
        let firstReply = expectation(description: "Quit cancelled")
        XCTAssertTrue(
            coordinator.prepareToQuit { saved in
                XCTAssertFalse(saved)
                firstReply.fulfill()
            })
        await fulfillment(of: [firstReply], timeout: 1)
        XCTAssertTrue(coordinator.hasUnsavedChanges)
        XCTAssertFalse(coordinator.isPreparingToQuit)

        canSave = true
        let retryReply = expectation(description: "Quit allowed after retry")
        XCTAssertTrue(
            coordinator.prepareToQuit { saved in
                XCTAssertTrue(saved)
                retryReply.fulfill()
            })
        await fulfillment(of: [retryReply], timeout: 1)
        XCTAssertEqual(writes, ["Preserve after window close", "Preserve after window close"])
        XCTAssertFalse(coordinator.hasUnsavedChanges)
    }

    func testQuitAlsoFlushesEditsAndNewDraftsCreatedDuringPendingSave() async {
        let coordinator = SavedMeetingNotesCoordinator()
        let saveStarted = expectation(description: "First save started")
        let quitReplied = expectation(description: "All drafts saved")
        var releaseSave: (() -> Void)?
        var writes: [String] = []
        let editorA = coordinator.editor(meetingID: UUID(), text: nil) { text in
            writes.append(text)
            if text == "A first" {
                saveStarted.fulfill()
                await withCheckedContinuation { continuation in
                    releaseSave = { continuation.resume() }
                }
            }
            return true
        }
        editorA.textBinding.wrappedValue = "A first"
        XCTAssertTrue(
            coordinator.prepareToQuit { saved in
                XCTAssertTrue(saved)
                quitReplied.fulfill()
            })
        await fulfillment(of: [saveStarted], timeout: 1)
        editorA.textBinding.wrappedValue = "A latest"
        editorA.cancelPendingSave()
        let editorB = coordinator.editor(meetingID: UUID(), text: nil) { text in
            writes.append(text)
            return true
        }
        editorB.textBinding.wrappedValue = "B new"
        editorB.cancelPendingSave()
        releaseSave?()
        await fulfillment(of: [quitReplied], timeout: 1)

        XCTAssertEqual(writes, ["A first", "A latest", "B new"])
        XCTAssertFalse(coordinator.hasUnsavedChanges)
    }

    func testFlushAttemptsOtherDraftsEvenIfOneFails() async {
        let coordinator = SavedMeetingNotesCoordinator()
        var successfulWrites: [String] = []
        let failing = coordinator.editor(meetingID: UUID(), text: nil) { _ in false }
        let succeeding = coordinator.editor(meetingID: UUID(), text: nil) { text in
            successfulWrites.append(text)
            return true
        }
        failing.textBinding.wrappedValue = "Unsaved"
        succeeding.textBinding.wrappedValue = "Saved"
        let saved = await coordinator.flushAll()
        XCTAssertFalse(saved)
        XCTAssertEqual(successfulWrites, ["Saved"])
        XCTAssertTrue(failing.hasUnsavedChanges)
        XCTAssertFalse(succeeding.hasUnsavedChanges)
    }

    func testQuitWithoutDraftsDoesNotDeferOrReply() {
        let coordinator = SavedMeetingNotesCoordinator()
        XCTAssertFalse(
            coordinator.prepareToQuit { _ in
                XCTFail("The caller can continue its existing quit decision immediately")
            })
    }
}
