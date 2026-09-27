import XCTest
import MacParakeetCore
import MacParakeetViewModels
@testable import MacParakeet

@MainActor
final class MainWindowStateTests: XCTestCase {
    func testNavigateToSettingsSelectsSettingsAndRecordsRequestedTab() {
        let state = MainWindowState()

        state.navigateToSettings(tab: .ai)

        XCTAssertEqual(state.selectedItem, .settings)
        XCTAssertEqual(state.requestedSettingsTab, .ai)
        XCTAssertNil(state.requestedSettingsAnchor)
        XCTAssertEqual(state.requestedSettingsTabRevision, 1)
    }

    func testNavigateToSettingsCanRequestAnchor() {
        let state = MainWindowState()

        state.navigateToSettings(tab: .capture, anchor: "meeting")

        XCTAssertEqual(state.selectedItem, .settings)
        XCTAssertEqual(state.requestedSettingsTab, .capture)
        XCTAssertEqual(state.requestedSettingsAnchor, "meeting")
        XCTAssertEqual(state.requestedSettingsTabRevision, 1)
    }

    func testRepeatedSettingsTabNavigationAdvancesRevision() {
        let state = MainWindowState()

        state.navigateToSettings(tab: .ai)
        state.navigateToSettings(tab: .ai)

        XCTAssertEqual(state.requestedSettingsTab, .ai)
        XCTAssertEqual(state.requestedSettingsTabRevision, 2)
    }

    func testConsumeRequestedSettingsTabClearsTabWithoutChangingRevision() {
        let state = MainWindowState()
        state.navigateToSettings(tab: .ai)

        state.consumeRequestedSettingsTab()

        XCTAssertNil(state.requestedSettingsTab)
        XCTAssertNil(state.requestedSettingsAnchor)
        XCTAssertEqual(state.requestedSettingsTabRevision, 1)
        XCTAssertEqual(state.selectedItem, .settings)
    }

    func testNavigateSelectsRequestedSidebarItem() {
        let state = MainWindowState()

        state.navigate(to: .library)

        XCTAssertEqual(state.selectedItem, .library)
    }

    func testNavigateCanSelectMeetingsWorkspace() {
        let state = MainWindowState()

        state.navigate(to: .meetings)

        XCTAssertEqual(state.selectedItem, .meetings)
    }

    func testNavigateToAskSelectsWorkspaceWhenEnabled() {
        let state = MainWindowState(askWorkspaceAvailable: true)
        state.navigateToAsk()
        XCTAssertEqual(state.selectedItem, .ask)
    }

    func testDisabledAskNavigationFallsBackToLibrary() {
        let state = MainWindowState(askWorkspaceAvailable: false)
        state.navigateToAsk()
        XCTAssertEqual(state.selectedItem, .library)

        state.navigate(to: .ask)
        XCTAssertEqual(state.selectedItem, .library)

        state.selectedItem = .ask
        XCTAssertEqual(state.selectedItem, .library)
    }

    func testPrimarySidebarOrderRespectsFeatureFlags() {
        var expected: [SidebarItem] = [.transcribe, .library]
        if AppFeatures.isAskWorkspaceAvailable() { expected.append(.ask) }
        expected.append(.dictations)
        if AppFeatures.meetingRecordingEnabled {
            expected.append(.meetings)
        }
        if AppFeatures.isShareLinksAvailable() { expected.append(.sharedPages) }
        XCTAssertEqual(SidebarItem.primaryItems, expected)
        XCTAssertEqual(SidebarItem.primaryItems.contains(.ask), AppFeatures.isAskWorkspaceAvailable())
    }

    func testPromptsAreManagedInContextRatherThanFromTheSidebar() {
        XCTAssertNil(SidebarItem(rawValue: "Prompts"))
        var expected: [SidebarItem] = [.vocabulary, .feedback, .settings]
        if AppFeatures.transformsEnabled {
            expected.insert(.transforms, at: 0)
        }
        XCTAssertEqual(SidebarItem.configItems, expected)
    }

    func testStartNewTranscriptionReturnsToTranscribeAndHidesProgressDetail() {
        let state = MainWindowState()
        state.selectedItem = .library
        state.showingProgressDetail = true

        state.startNewTranscription()

        XCTAssertEqual(state.selectedItem, .transcribe)
        XCTAssertFalse(state.showingProgressDetail)
    }

    func testBeginCreatingTransformSelectsTransformsAndClearsEditTarget() {
        let state = MainWindowState()
        state.selectedItem = .settings
        state.editingTransform = Prompt.builtInPrompts().first { $0.category == .transform }
        XCTAssertNotNil(state.editingTransform)

        state.beginCreatingTransform()

        XCTAssertEqual(state.selectedItem, .transforms)
        XCTAssertNil(state.editingTransform)
        XCTAssertTrue(state.isCreatingTransform)
    }

    func testOpenTranscriptionLoadsDetailFromLibraryAndMeetings() async {
        for tab in [SidebarItem.library, .meetings] {
            let state = MainWindowState()
            state.selectedItem = tab
            let viewModel = TranscriptionViewModel()
            let load = SuspendedTranscriptionLoad()
            let stored = Transcription(fileName: "Stored", rawTranscript: "Full transcript", status: .completed)

            let open = state.openTranscription(from: tab, in: viewModel) { await load.fetch() }
            await load.waitUntilStarted()
            XCTAssertNil(viewModel.currentTranscription)
            load.complete(with: stored)

            let opened = await open.value
            XCTAssertTrue(opened)
            XCTAssertEqual(viewModel.currentTranscription?.id, stored.id)
            XCTAssertEqual(viewModel.currentTranscription?.rawTranscript, "Full transcript")
            XCTAssertEqual(state.selectedItem, .library)
        }
    }

    func testOpenTranscriptionPreservesMeetingCompletedDuringLoad() async {
        let state = MainWindowState()
        state.selectedItem = .library
        let viewModel = TranscriptionViewModel()
        let load = SuspendedTranscriptionLoad()
        let open = state.openTranscription(from: .library, in: viewModel) { await load.fetch() }
        await load.waitUntilStarted()

        let meeting = Transcription(fileName: "Completed meeting", status: .completed)
        viewModel.currentTranscription = meeting
        state.navigateToTranscription(from: .meetings)
        load.complete(with: Transcription(fileName: "Older Library click"))

        let opened = await open.value
        XCTAssertFalse(opened)
        XCTAssertEqual(viewModel.currentTranscription?.id, meeting.id)
    }

    func testOpenTranscriptionCapturesSelectionBeforeTaskStarts() async {
        let state = MainWindowState()
        state.selectedItem = .library
        let viewModel = TranscriptionViewModel()
        var loadCount = 0
        let open = state.openTranscription(from: .library, in: viewModel) {
            loadCount += 1
            return Transcription(fileName: "Older Library click")
        }
        // No suspension between the click and the meeting handoff: the open's
        // Task has not run yet, but its selection snapshot must already exist.
        let meeting = Transcription(fileName: "Completed meeting", status: .completed)
        viewModel.currentTranscription = meeting

        let opened = await open.value
        XCTAssertFalse(opened)
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(viewModel.currentTranscription?.id, meeting.id)
    }

    func testSupersededOpenDoesNotStartItsLoader() async {
        let state = MainWindowState()
        state.selectedItem = .library
        let viewModel = TranscriptionViewModel()
        var olderLoadCount = 0
        let older = state.openTranscription(from: .library, in: viewModel) {
            olderLoadCount += 1
            return Transcription(fileName: "Older click")
        }
        let selected = Transcription(fileName: "Newer click")
        let newer = state.openTranscription(from: .library, in: viewModel) { selected }

        let olderOpened = await older.value
        let newerOpened = await newer.value
        XCTAssertFalse(olderOpened)
        XCTAssertTrue(newerOpened)
        XCTAssertEqual(olderLoadCount, 0)
        XCTAssertEqual(viewModel.currentTranscription?.id, selected.id)
    }

    func testOpenTranscriptionRejectsLeavingAndReturningToItsTab() async {
        for tab in [SidebarItem.library, .meetings] {
            let state = MainWindowState()
            state.selectedItem = tab
            let viewModel = TranscriptionViewModel()
            let load = SuspendedTranscriptionLoad()
            let open = state.openTranscription(from: tab, in: viewModel) { await load.fetch() }
            await load.waitUntilStarted()

            state.selectedItem = .settings
            state.selectedItem = tab
            load.complete(with: Transcription(fileName: "Stale click"))

            let opened = await open.value
            XCTAssertFalse(opened)
            XCTAssertNil(viewModel.currentTranscription)
            XCTAssertEqual(state.selectedItem, tab)
        }
    }

    func testNewerOpenWinsEvenWhenOlderLoadFinishesFirst() async {
        let state = MainWindowState()
        state.selectedItem = .library
        let viewModel = TranscriptionViewModel()
        let olderLoad = SuspendedTranscriptionLoad()
        let newerLoad = SuspendedTranscriptionLoad()
        let older = state.openTranscription(from: .library, in: viewModel) { await olderLoad.fetch() }
        await olderLoad.waitUntilStarted()
        let newer = state.openTranscription(from: .library, in: viewModel) { await newerLoad.fetch() }
        await newerLoad.waitUntilStarted()

        olderLoad.complete(with: Transcription(fileName: "Older click"))
        let olderOpened = await older.value
        XCTAssertFalse(olderOpened)
        XCTAssertNil(viewModel.currentTranscription)

        let selected = Transcription(fileName: "Newer click")
        newerLoad.complete(with: selected)
        let newerOpened = await newer.value
        XCTAssertTrue(newerOpened)
        XCTAssertEqual(viewModel.currentTranscription?.id, selected.id)
    }

    func testNewerMeetingOpenSurvivesOlderLibraryCompletion() async {
        let state = MainWindowState()
        state.selectedItem = .library
        let viewModel = TranscriptionViewModel()
        let libraryLoad = SuspendedTranscriptionLoad()
        let meetingLoad = SuspendedTranscriptionLoad()
        let libraryOpen = state.openTranscription(from: .library, in: viewModel) { await libraryLoad.fetch() }
        await libraryLoad.waitUntilStarted()
        state.selectedItem = .meetings
        let meetingOpen = state.openTranscription(from: .meetings, in: viewModel) { await meetingLoad.fetch() }
        await meetingLoad.waitUntilStarted()

        let meeting = Transcription(fileName: "Newer meeting click")
        meetingLoad.complete(with: meeting)
        let meetingOpened = await meetingOpen.value
        XCTAssertTrue(meetingOpened)
        XCTAssertEqual(state.selectedItem, .library)

        libraryLoad.complete(with: Transcription(fileName: "Older Library click"))
        let libraryOpened = await libraryOpen.value
        XCTAssertFalse(libraryOpened)
        XCTAssertEqual(viewModel.currentTranscription?.id, meeting.id)
    }

    func testMissingTranscriptionDoesNotChangeSelectionOrNavigation() async {
        let state = MainWindowState()
        state.selectedItem = .meetings
        let viewModel = TranscriptionViewModel()
        let open = state.openTranscription(from: .meetings, in: viewModel) { nil }

        let opened = await open.value
        XCTAssertFalse(opened)
        XCTAssertNil(viewModel.currentTranscription)
        XCTAssertEqual(state.selectedItem, .meetings)
    }
}

@MainActor
private final class SuspendedTranscriptionLoad {
    private var continuation: CheckedContinuation<Transcription?, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func fetch() async -> Transcription? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func complete(with transcription: Transcription?) {
        precondition(continuation != nil, "Wait for the load to start before completing it")
        continuation?.resume(returning: transcription)
        continuation = nil
    }
}
