import XCTest
import MacParakeetCore
import MacParakeetViewModels
@testable import MacParakeet

/// Covers the end-of-meeting workspace invariant: with "Open app when meeting
/// ends" off, a finished meeting must be saved and refreshed without selecting
/// the transcript, because selection is what drives a mounted main window to
/// Library and pulls the user off their current tab.
@MainActor
final class MeetingCompletionRouterTests: XCTestCase {
    private func makeMeeting(title: String = "Weekly sync") -> Transcription {
        Transcription(
            fileName: title,
            rawTranscript: "We shipped the thing",
            status: .completed,
            sourceType: .meeting
        )
    }

    /// Records everything the router did, in order.
    private struct Recorder {
        var selectionRequests: [Bool] = []
        var reloadCount = 0
        var refreshCount = 0
        var navigateCount = 0
        var openWindowCount = 0
        var signals: [TranscriptionCompletionNotifier.Content] = []
    }

    private final class Box: @unchecked Sendable {
        var recorder = Recorder()
    }

    private func makeRouter(_ box: Box) -> MeetingCompletionRouter {
        MeetingCompletionRouter(
            presentCompleted: { _, select in box.recorder.selectionRequests.append(select) },
            reloadLibrary: { box.recorder.reloadCount += 1 },
            refreshRecentMeetings: { box.recorder.refreshCount += 1 },
            navigateToTranscription: { box.recorder.navigateCount += 1 },
            openMainWindow: { box.recorder.openWindowCount += 1 },
            presentSignal: { box.recorder.signals.append($0) }
        )
    }

    // MARK: - Quiet path preserves the workspace

    func testQuietCompletionDoesNotSelectTranscript() {
        let box = Box()

        makeRouter(box).handle(
            makeMeeting(),
            openAppEnabled: false,
            notifyEnabled: true,
            canPresent: true
        )

        XCTAssertEqual(box.recorder.selectionRequests, [false])
        XCTAssertEqual(box.recorder.navigateCount, 0)
        XCTAssertEqual(box.recorder.openWindowCount, 0)
        XCTAssertEqual(box.recorder.signals.count, 1)
        XCTAssertEqual(box.recorder.signals.first?.title, "Weekly sync")
    }

    func testSilentCompletionDoesNotSelectTranscript() {
        let box = Box()

        makeRouter(box).handle(
            makeMeeting(),
            openAppEnabled: false,
            notifyEnabled: false,
            canPresent: true
        )

        XCTAssertEqual(box.recorder.selectionRequests, [false])
        XCTAssertEqual(box.recorder.navigateCount, 0)
        XCTAssertEqual(box.recorder.openWindowCount, 0)
        XCTAssertTrue(box.recorder.signals.isEmpty)
    }

    func testQuietCompletionStillSavesAndRefreshes() {
        let box = Box()

        makeRouter(box).handle(
            makeMeeting(),
            openAppEnabled: false,
            notifyEnabled: false,
            canPresent: true
        )

        XCTAssertEqual(box.recorder.selectionRequests.count, 1, "The transcript must still be persisted")
        XCTAssertEqual(box.recorder.reloadCount, 1)
        XCTAssertEqual(box.recorder.refreshCount, 1)
    }

    // MARK: - Auto-open path

    func testAutoOpenSelectsAndNavigates() {
        let box = Box()

        makeRouter(box).handle(
            makeMeeting(),
            openAppEnabled: true,
            notifyEnabled: false,
            canPresent: true
        )

        XCTAssertEqual(box.recorder.selectionRequests, [true])
        XCTAssertEqual(box.recorder.navigateCount, 1)
        XCTAssertEqual(box.recorder.openWindowCount, 1)
        XCTAssertTrue(box.recorder.signals.isEmpty, "Opening the app replaces the banner")
    }

    // MARK: - Queue guard

    func testQueueGuardSuppressesSelectionEvenWithAutoOpenOn() {
        let box = Box()

        makeRouter(box).handle(
            makeMeeting(),
            openAppEnabled: true,
            notifyEnabled: true,
            canPresent: false
        )

        XCTAssertEqual(box.recorder.selectionRequests, [false], "A live meeting must not be interrupted")
        XCTAssertEqual(box.recorder.navigateCount, 0)
        XCTAssertEqual(box.recorder.openWindowCount, 0)
        XCTAssertTrue(box.recorder.signals.isEmpty)
        XCTAssertEqual(box.recorder.reloadCount, 1, "The transcript is still saved and listed")
        XCTAssertEqual(box.recorder.refreshCount, 1)
    }

    // MARK: - Integration with the real view model and window state

    /// Mirrors `MainWindowView`'s `.onChange(of: currentTranscription?.id)`,
    /// which sets `selectedItem = .library` whenever a transcript becomes the
    /// current one. Kept here so the test fails if the router ever selects on
    /// the quiet path again.
    private func applyMountedWindowReaction(
        from previousID: UUID?,
        viewModel: TranscriptionViewModel,
        state: MainWindowState
    ) {
        let newID = viewModel.currentTranscription?.id
        guard newID != previousID, newID != nil else { return }
        state.selectedItem = .library
    }

    private func makeConfiguredViewModel(suite: String) -> (TranscriptionViewModel, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        let viewModel = TranscriptionViewModel(defaults: defaults)
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository()
        )
        return (viewModel, defaults)
    }

    private func makeProductionRouter(
        viewModel: TranscriptionViewModel,
        state: MainWindowState
    ) -> MeetingCompletionRouter {
        MeetingCompletionRouter(
            presentCompleted: { transcription, select in
                viewModel.presentCompletedTranscription(
                    transcription,
                    autoSave: true,
                    runAutoPrompts: false,
                    applyMeetingRetention: false,
                    selectTranscription: select
                )
            },
            reloadLibrary: {},
            refreshRecentMeetings: {},
            navigateToTranscription: { state.navigateToTranscription(from: .library) },
            openMainWindow: {},
            presentSignal: { _ in }
        )
    }

    func testQuietCompletionLeavesForegroundedUserOnTheirTab() {
        let suite = "meeting-completion-router-quiet-\(UUID().uuidString)"
        let (viewModel, defaults) = makeConfiguredViewModel(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = MainWindowState()
        state.selectedItem = .transforms
        let previousID = viewModel.currentTranscription?.id

        makeProductionRouter(viewModel: viewModel, state: state).handle(
            makeMeeting(),
            openAppEnabled: false,
            notifyEnabled: true,
            canPresent: true
        )
        applyMountedWindowReaction(from: previousID, viewModel: viewModel, state: state)

        XCTAssertNil(viewModel.currentTranscription, "Quiet completion must not change the current transcript")
        XCTAssertEqual(state.selectedItem, .transforms, "Quiet completion must not move the user to Library")
    }

    func testAutoOpenCompletionSelectsTranscriptAndLandsOnLibrary() {
        let suite = "meeting-completion-router-open-\(UUID().uuidString)"
        let (viewModel, defaults) = makeConfiguredViewModel(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = MainWindowState()
        state.selectedItem = .transforms
        let meeting = makeMeeting()
        let previousID = viewModel.currentTranscription?.id

        makeProductionRouter(viewModel: viewModel, state: state).handle(
            meeting,
            openAppEnabled: true,
            notifyEnabled: false,
            canPresent: true
        )
        applyMountedWindowReaction(from: previousID, viewModel: viewModel, state: state)

        XCTAssertEqual(viewModel.currentTranscription?.id, meeting.id)
        XCTAssertEqual(state.selectedItem, .library)
    }
}
