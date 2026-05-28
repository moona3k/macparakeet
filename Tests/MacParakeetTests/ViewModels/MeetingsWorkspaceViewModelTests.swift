import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class MeetingsWorkspaceViewModelTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "MeetingsWorkspaceViewModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testRefreshUpcomingEventsSkipsFetchWhenCalendarModeIsOff() async {
        let calendar = MockCalendarService()
        calendar.stubPermissionStatus = .granted
        calendar.stubEvents = [makeEvent(title: "Design Review", meetUrl: "https://meet.google.com/abc")]
        let viewModel = makeViewModel(calendarMode: .off, calendarService: calendar)
        viewModel.settingsViewModel.calendarPermissionStatus = .granted

        await viewModel.refreshUpcomingEvents().value

        XCTAssertEqual(calendar.fetchUpcomingEventsCallCount, 0)
        XCTAssertTrue(viewModel.upcomingEvents.isEmpty)
        XCTAssertEqual(viewModel.calendarStatus, AppFeatures.calendarEnabled ? .off : .unavailable)
    }

    func testRefreshUpcomingEventsFiltersByMeetingRulesAndExcludedCalendars() async {
        let calendar = MockCalendarService()
        calendar.stubPermissionStatus = .granted
        calendar.stubEvents = [
            makeEvent(title: "Design Review", meetUrl: "https://zoom.us/j/123", calendarIdentifier: "work"),
            makeEvent(title: "Focus Block", meetUrl: nil, calendarIdentifier: "work"),
            makeEvent(title: "Ignored Review", meetUrl: "https://meet.google.com/abc", calendarIdentifier: "personal")
        ]
        let viewModel = makeViewModel(
            calendarMode: .notify,
            triggerFilter: .withLink,
            excludedCalendarIds: ["personal"],
            calendarService: calendar
        )
        viewModel.settingsViewModel.calendarPermissionStatus = .granted

        await viewModel.refreshUpcomingEvents().value

        if AppFeatures.calendarEnabled {
            XCTAssertEqual(calendar.fetchUpcomingEventsCallCount, 1)
            XCTAssertEqual(viewModel.upcomingEvents.map(\.title), ["Design Review"])
            XCTAssertEqual(viewModel.calendarStatus, .ready(mode: .notify))
        } else {
            XCTAssertEqual(calendar.fetchUpcomingEventsCallCount, 0)
            XCTAssertTrue(viewModel.upcomingEvents.isEmpty)
            XCTAssertEqual(viewModel.calendarStatus, .unavailable)
        }
    }

    func testRecordingStatusTracksMeetingPillState() {
        let pill = MeetingRecordingPillViewModel()
        let viewModel = makeViewModel(meetingPillViewModel: pill)

        pill.state = .recording
        XCTAssertEqual(viewModel.recordingStatus, .recording)
        XCTAssertTrue(viewModel.hasActiveRecording)

        pill.state = .paused
        XCTAssertEqual(viewModel.recordingStatus, .paused)
        XCTAssertTrue(viewModel.hasActiveRecording)

        pill.state = .error("capture failed")
        XCTAssertEqual(viewModel.recordingStatus, .error("capture failed"))
        XCTAssertFalse(viewModel.hasActiveRecording)
    }

    func testAttentionItemsDoNotDuplicateCalendarAndAISetupStates() {
        let viewModel = makeViewModel(calendarMode: .notify)
        viewModel.settingsViewModel.calendarPermissionStatus = .notDetermined

        let ids = Set(viewModel.attentionItems.map(\.id))

        XCTAssertFalse(ids.contains("calendar-permission"))
        XCTAssertFalse(ids.contains("ai-setup"))
        XCTAssertEqual(viewModel.calendarStatus, AppFeatures.calendarEnabled ? .permissionNeeded : .unavailable)
        XCTAssertEqual(viewModel.intelligenceStatus, .setupNeeded)
    }

    func testConfigureLoadsLiveAskPromptPreview() throws {
        let manager = try DatabaseManager()
        let quickPromptRepo = QuickPromptRepository(dbQueue: manager.dbQueue)
        let transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let viewModel = makeViewModel()

        viewModel.configure(
            transcriptionRepo: transcriptionRepo,
            quickPromptRepo: quickPromptRepo
        )

        XCTAssertEqual(
            viewModel.quickPromptsViewModel.pinnedCount,
            QuickPrompt.builtInPrompts().filter(\.isPinned).count
        )
        XCTAssertEqual(
            viewModel.liveAskPromptVisiblePinnedCount,
            viewModel.quickPromptsViewModel.visiblePinned.count
        )
        XCTAssertEqual(
            viewModel.liveAskPromptPreviewPrompts.map(\.label),
            viewModel.quickPromptsViewModel.visiblePinned.prefix(2).map(\.label)
        )
    }

    func testRefreshQuickPromptsIsSafeBeforeRepositoryConfiguration() {
        let viewModel = makeViewModel()

        viewModel.refreshQuickPrompts()

        XCTAssertTrue(viewModel.liveAskPromptPreviewPrompts.isEmpty)
        XCTAssertEqual(viewModel.liveAskPromptVisiblePinnedCount, 0)
        XCTAssertEqual(viewModel.quickPromptsViewModel.pinnedCount, 0)
    }

    func testLiveAskPromptPreviewIsEmptyWhenNoPromptsArePinned() throws {
        let manager = try DatabaseManager()
        let quickPromptRepo = QuickPromptRepository(dbQueue: manager.dbQueue)
        let transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let viewModel = makeViewModel()
        viewModel.configure(
            transcriptionRepo: transcriptionRepo,
            quickPromptRepo: quickPromptRepo
        )

        for prompt in viewModel.quickPromptsViewModel.allPinned {
            try quickPromptRepo.setPinned(id: prompt.id, isPinned: false)
        }
        viewModel.refreshQuickPrompts()

        XCTAssertTrue(viewModel.liveAskPromptPreviewPrompts.isEmpty)
        XCTAssertEqual(viewModel.liveAskPromptVisiblePinnedCount, 0)
        XCTAssertEqual(viewModel.quickPromptsViewModel.pinnedCount, 0)
    }

    func testLiveAskPromptCountTracksVisiblePinnedPromptsAfterHiding() throws {
        let manager = try DatabaseManager()
        let quickPromptRepo = QuickPromptRepository(dbQueue: manager.dbQueue)
        let transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let viewModel = makeViewModel()
        viewModel.configure(
            transcriptionRepo: transcriptionRepo,
            quickPromptRepo: quickPromptRepo
        )

        for prompt in viewModel.quickPromptsViewModel.visiblePinned {
            try quickPromptRepo.toggleVisibility(id: prompt.id)
        }
        viewModel.refreshQuickPrompts()

        XCTAssertTrue(viewModel.liveAskPromptPreviewPrompts.isEmpty)
        XCTAssertEqual(viewModel.liveAskPromptVisiblePinnedCount, 0)
        XCTAssertEqual(viewModel.quickPromptsViewModel.pinnedCount, 0)
    }

    private func makeViewModel(
        calendarMode: CalendarAutoStartMode = .off,
        triggerFilter: MeetingTriggerFilter = .withLink,
        excludedCalendarIds: Set<String> = [],
        meetingPillViewModel: MeetingRecordingPillViewModel? = nil,
        calendarService: MockCalendarService = MockCalendarService()
    ) -> MeetingsWorkspaceViewModel {
        defaults.set(calendarMode.rawValue, forKey: CalendarAutoStartPreferences.modeKey)
        defaults.set(triggerFilter.rawValue, forKey: CalendarAutoStartPreferences.triggerFilterKey)
        defaults.set(Array(excludedCalendarIds), forKey: CalendarAutoStartPreferences.excludedCalendarIdsKey)

        let settingsViewModel = SettingsViewModel(defaults: defaults)
        let llmSettingsViewModel = LLMSettingsViewModel(defaults: defaults)
        return MeetingsWorkspaceViewModel(
            recentMeetingsViewModel: TranscriptionLibraryViewModel(scope: .meetings),
            meetingPillViewModel: meetingPillViewModel ?? MeetingRecordingPillViewModel(),
            settingsViewModel: settingsViewModel,
            llmSettingsViewModel: llmSettingsViewModel,
            calendarService: calendarService
        )
    }

    private func makeEvent(
        title: String,
        meetUrl: String?,
        calendarIdentifier: String? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: UUID().uuidString,
            title: title,
            startTime: Date().addingTimeInterval(3600),
            endTime: Date().addingTimeInterval(5400),
            meetUrl: meetUrl,
            participants: [EventParticipant(name: "Ava")],
            calendarName: "Work",
            calendarIdentifier: calendarIdentifier
        )
    }
}
