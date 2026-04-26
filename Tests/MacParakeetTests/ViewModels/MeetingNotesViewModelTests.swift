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

    // MARK: - Slash menu (ADR-020 §7)

    func testSlashAtStartActivatesMenu() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "/"

        XCTAssertTrue(viewModel.isSlashMenuActive)
        XCTAssertEqual(viewModel.slashQuery, "")
        XCTAssertEqual(viewModel.matchingCommands.count, MeetingNotesViewModel.allCommands.count)
    }

    func testSlashAfterWhitespaceActivatesMenu() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "Some preamble /"

        XCTAssertTrue(viewModel.isSlashMenuActive)
    }

    func testSlashAfterNewlineActivatesMenu() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "Some heading\n/"

        XCTAssertTrue(viewModel.isSlashMenuActive)
    }

    func testMidWordSlashDoesNotActivateMenu() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "https:/"

        XCTAssertFalse(viewModel.isSlashMenuActive, "Slash inside a URL/word must not trigger the menu")
    }

    func testSlashMenuFiltersByQuery() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "/dec"

        XCTAssertTrue(viewModel.isSlashMenuActive)
        XCTAssertEqual(viewModel.slashQuery, "dec")
        XCTAssertEqual(viewModel.matchingCommands.map { $0.trigger }, ["/decision"])
    }

    func testSlashMenuQueryIsCaseInsensitive() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "/AC"

        XCTAssertEqual(viewModel.matchingCommands.map { $0.trigger }, ["/action"])
    }

    func testSlashMenuDismissesOnNoMatch() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "/zzz"

        XCTAssertFalse(viewModel.isSlashMenuActive, "Typing a query that matches no command dismisses the menu")
    }

    func testSlashMenuDismissesOnTrailingWhitespace() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "/act"
        XCTAssertTrue(viewModel.isSlashMenuActive)

        viewModel.notesBinding.wrappedValue = "/act "
        XCTAssertFalse(viewModel.isSlashMenuActive, "Space after the slash token closes the menu — typed-out commit, not a menu select")
    }

    func testMoveSelectionClampsToBounds() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "/"
        XCTAssertEqual(viewModel.slashSelection, 0)

        viewModel.moveSlashSelection(by: -5)
        XCTAssertEqual(viewModel.slashSelection, 0, "Selection clamps at top boundary")

        viewModel.moveSlashSelection(by: 100)
        XCTAssertEqual(viewModel.slashSelection, MeetingNotesViewModel.allCommands.count - 1, "Selection clamps at bottom boundary")
    }

    func testAcceptCommandReplacesTokenWithLiteralInsertion() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "/action"
        // /action is index 0 (default selection)
        viewModel.acceptSlashCommand(elapsedSeconds: 0)

        XCTAssertEqual(viewModel.notesText, "**Action:** ")
        XCTAssertFalse(viewModel.isSlashMenuActive)
    }

    func testAcceptCommandPreservesPrefix() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "Discussed roadmap.\n/action"
        viewModel.acceptSlashCommand(elapsedSeconds: 0)

        XCTAssertEqual(viewModel.notesText, "Discussed roadmap.\n**Action:** ")
    }

    func testAcceptCommandAfterArrowMovesToDecision() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "/"
        viewModel.moveSlashSelection(by: 1)  // → /decision

        viewModel.acceptSlashCommand(elapsedSeconds: 0)

        XCTAssertEqual(viewModel.notesText, "**Decision:** ")
    }

    func testAcceptTimestampCommandFormatsElapsedSeconds() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "Topic A\n/now"
        // /now is index 2
        viewModel.moveSlashSelection(by: 2)

        viewModel.acceptSlashCommand(elapsedSeconds: 125)

        XCTAssertEqual(viewModel.notesText, "Topic A\n[2:05] ")
    }

    func testAcceptTimestampCommandHandlesZeroElapsed() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "/now"
        viewModel.moveSlashSelection(by: 2)

        viewModel.acceptSlashCommand(elapsedSeconds: 0)

        XCTAssertEqual(viewModel.notesText, "[0:00] ")
    }

    func testAcceptCommandSchedulesPersist() async {
        let viewModel = MeetingNotesViewModel()
        let recorder = AsyncRecorder()
        viewModel.bindPersist { notes in
            await recorder.record(notes)
        }

        viewModel.notesBinding.wrappedValue = "/action"
        viewModel.acceptSlashCommand(elapsedSeconds: 0)

        try? await Task.sleep(for: .milliseconds(800))
        let snapshots = await recorder.snapshots
        // The applyEdit fires once on initial set ("/action" → debounced),
        // then acceptSlashCommand reschedules with the substituted text.
        // Cancellation collapses the first into the second, so we get one
        // final persist of the post-substitution text.
        XCTAssertEqual(snapshots.last, "**Action:** ")
    }

    func testDismissSlashMenuClearsState() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "/dec"
        XCTAssertTrue(viewModel.isSlashMenuActive)

        viewModel.dismissSlashMenu()

        XCTAssertFalse(viewModel.isSlashMenuActive)
        XCTAssertEqual(viewModel.slashQuery, "")
        XCTAssertEqual(viewModel.slashSelection, 0)
    }

    func testTrailingSlashTokenHelper() {
        XCTAssertEqual(MeetingNotesViewModel.trailingSlashToken(in: "/"), "/")
        XCTAssertEqual(MeetingNotesViewModel.trailingSlashToken(in: "hello /act"), "/act")
        XCTAssertEqual(MeetingNotesViewModel.trailingSlashToken(in: "hello\n/decision"), "/decision")
        XCTAssertNil(MeetingNotesViewModel.trailingSlashToken(in: "hello"))
        XCTAssertNil(MeetingNotesViewModel.trailingSlashToken(in: "/action "), "Trailing space means token is closed")
        XCTAssertNil(MeetingNotesViewModel.trailingSlashToken(in: ""))
    }

    func testAcceptCommandIsNoOpWhenMenuInactive() {
        let viewModel = MeetingNotesViewModel()
        viewModel.notesBinding.wrappedValue = "Plain text"

        viewModel.acceptSlashCommand(elapsedSeconds: 100)

        XCTAssertEqual(viewModel.notesText, "Plain text", "Accept must no-op when the menu isn't active")
    }

    /// Regression for the latent debounce-leak caught in Codex fresh-eye review
    /// of PR #143. `bindPersist` was replacing the persist target without
    /// cancelling any pending debounce — so a snapshot scheduled against the
    /// previous session could fire against the new session's persist callback.
    /// The current code path always recreates the panel VM tree per session,
    /// so this was latent rather than active, but the invariant is worth pinning.
    func testBindPersistCancelsPendingDebounceFromPreviousTarget() async {
        let viewModel = MeetingNotesViewModel()
        let firstTarget = AsyncRecorder()
        let secondTarget = AsyncRecorder()

        viewModel.bindPersist { notes in
            await firstTarget.record(notes)
        }

        // Schedule a debounced write against the first target, then re-bind
        // BEFORE the debounce window elapses.
        viewModel.notesBinding.wrappedValue = "queued for first target"
        viewModel.bindPersist { notes in
            await secondTarget.record(notes)
        }

        // Wait past the debounce window. The cancelled task must NOT fire
        // against either target — there's nothing new to persist; the rebind
        // semantics are "clean slate."
        try? await Task.sleep(for: .milliseconds(800))

        let first = await firstTarget.snapshots
        let second = await secondTarget.snapshots
        XCTAssertTrue(first.isEmpty, "First persist target must not receive a write after rebind cancels its scheduled debounce")
        XCTAssertTrue(second.isEmpty, "Second target should not receive the cancelled write either — only fresh edits should reach it")
    }
}

/// Thread-safe sink for async persist callbacks.
private actor AsyncRecorder {
    private(set) var snapshots: [String] = []

    func record(_ value: String) {
        snapshots.append(value)
    }
}
