import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class MeetingNotesViewModelTests: XCTestCase {
    func testInitialStateIsEmpty() {
        let viewModel = MeetingNotesViewModel()

        XCTAssertEqual(viewModel.notesText, "")
        XCTAssertEqual(viewModel.wordCount, 0)
        XCTAssertFalse(viewModel.isApproachingSoftCap)
    }

    func testApplyEditUpdatesTextSynchronously() {
        let viewModel = MeetingNotesViewModel()

        viewModel.notesBinding.wrappedValue = "Hello world"

        XCTAssertEqual(viewModel.notesText, "Hello world")
        XCTAssertEqual(viewModel.wordCount, 2)
    }

    func testDebouncedPersistFiresAfterIdleWindow() async {
        let viewModel = MeetingNotesViewModel()
        let recorder = AsyncRecorder()
        viewModel.bindPersist { notes in
            await recorder.record(notes)
        }

        viewModel.notesBinding.wrappedValue = "Final text"

        // Wait past the debounce window with generous slack for CI jitter.
        try? await Task.sleep(for: .milliseconds(800))

        let snapshots = await recorder.snapshots
        XCTAssertEqual(snapshots, ["Final text"])
    }

    func testRapidEditsCoalesceIntoSinglePersist() async {
        let viewModel = MeetingNotesViewModel()
        let recorder = AsyncRecorder()
        viewModel.bindPersist { notes in
            await recorder.record(notes)
        }

        // Five rapid edits inside the debounce window — only the last value
        // should reach `persist`.
        viewModel.notesBinding.wrappedValue = "a"
        viewModel.notesBinding.wrappedValue = "ab"
        viewModel.notesBinding.wrappedValue = "abc"
        viewModel.notesBinding.wrappedValue = "abcd"
        viewModel.notesBinding.wrappedValue = "abcde"

        try? await Task.sleep(for: .milliseconds(800))

        let snapshots = await recorder.snapshots
        XCTAssertEqual(snapshots.count, 1, "Debounce should collapse rapid edits to a single persist")
        XCTAssertEqual(snapshots.first, "abcde")
    }

    func testCommitFlushesPendingDebounceImmediately() async {
        let viewModel = MeetingNotesViewModel()
        let recorder = AsyncRecorder()
        viewModel.bindPersist { notes in
            await recorder.record(notes)
        }

        viewModel.notesBinding.wrappedValue = "Last typed"

        // Commit immediately — should fire without waiting the debounce
        // window AND should cancel the pending debounce so we don't get a
        // duplicate persist later.
        await viewModel.commit()

        let immediate = await recorder.snapshots
        XCTAssertEqual(immediate, ["Last typed"])

        try? await Task.sleep(for: .milliseconds(800))

        let afterDebounce = await recorder.snapshots
        XCTAssertEqual(afterDebounce, ["Last typed"], "commit() must cancel any in-flight debounce")
    }

    func testRestoreSetsTextWithoutPersisting() async {
        let viewModel = MeetingNotesViewModel()
        let recorder = AsyncRecorder()
        viewModel.bindPersist { notes in
            await recorder.record(notes)
        }

        viewModel.restore("Recovered notes")

        XCTAssertEqual(viewModel.notesText, "Recovered notes")

        try? await Task.sleep(for: .milliseconds(800))

        let snapshots = await recorder.snapshots
        XCTAssertTrue(
            snapshots.isEmpty,
            "restore() is for the recovery path — the lock file already has the notes; persisting again would round-trip the same value."
        )
    }

    func testRestoreWithNilClearsText() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "Some draft"

        viewModel.restore(nil)

        XCTAssertEqual(viewModel.notesText, "")
    }

    func testResetCancelsPendingPersistAndClearsText() async {
        let viewModel = MeetingNotesViewModel()
        let recorder = AsyncRecorder()
        viewModel.bindPersist { notes in
            await recorder.record(notes)
        }

        viewModel.notesBinding.wrappedValue = "Will be discarded"
        viewModel.reset()

        try? await Task.sleep(for: .milliseconds(800))

        let snapshots = await recorder.snapshots
        XCTAssertTrue(snapshots.isEmpty, "reset() must cancel pending persist tasks")
        XCTAssertEqual(viewModel.notesText, "")
    }

    func testApproachingSoftCapTriggersAtThreshold() {
        let viewModel = MeetingNotesViewModel()
        let belowThreshold = String(repeating: "word ", count: 7_499)
        viewModel.notesBinding.wrappedValue = belowThreshold

        XCTAssertFalse(viewModel.isApproachingSoftCap)

        let atThreshold = String(repeating: "word ", count: MeetingNotesViewModel.softCapWarningWordCount)
        viewModel.notesBinding.wrappedValue = atThreshold

        XCTAssertTrue(viewModel.isApproachingSoftCap)
    }

    func testBindPersistReplacesPreviousTarget() async {
        let viewModel = MeetingNotesViewModel()
        let firstTarget = AsyncRecorder()
        let secondTarget = AsyncRecorder()

        viewModel.bindPersist { notes in
            await firstTarget.record(notes)
        }
        viewModel.bindPersist { notes in
            await secondTarget.record(notes)
        }

        viewModel.notesBinding.wrappedValue = "Routed to second target"
        await viewModel.commit()

        let first = await firstTarget.snapshots
        let second = await secondTarget.snapshots
        XCTAssertTrue(first.isEmpty, "First persist target must be replaced by the second bindPersist call")
        XCTAssertEqual(second, ["Routed to second target"])
    }

    func testWordCountUsesWhitespaceSplit() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "  one\ttwo\nthree  four "

        XCTAssertEqual(viewModel.wordCount, 4)
    }
}

/// Thread-safe sink for async persist callbacks.
private actor AsyncRecorder {
    private(set) var snapshots: [String] = []

    func record(_ value: String) {
        snapshots.append(value)
    }
}
