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

    func testAutoStartPreviewShowsEveryRsvpStatusExceptDeclined() async {
        // The preview mirrors MeetingMonitor's *candidate* set, which excludes
        // only declined (and all-day) events. RSVP is not mode-gated: a pending
        // or tentative invite still gets a reminder in .autoStart mode, so it
        // must stay visible even though it won't auto-record.
        let calendar = MockCalendarService()
        calendar.stubPermissionStatus = .granted
        calendar.stubEvents = [
            makeEvent(title: "Accepted Review", meetUrl: "https://zoom.us/j/1", userStatus: .accepted),
            makeEvent(title: "Pending Invite", meetUrl: "https://zoom.us/j/2", userStatus: .pending),
            makeEvent(title: "Tentative Sync", meetUrl: "https://zoom.us/j/3", userStatus: .tentative),
            makeEvent(title: "Declined Standup", meetUrl: "https://zoom.us/j/4", userStatus: .declined)
        ]
        let viewModel = makeViewModel(
            calendarMode: .autoStart,
            triggerFilter: .withLink,
            calendarService: calendar
        )
        viewModel.settingsViewModel.calendarPermissionStatus = .granted

        await viewModel.refreshUpcomingEvents().value

        if AppFeatures.calendarEnabled {
            XCTAssertEqual(
                Set(viewModel.upcomingEvents.map(\.title)),
                ["Accepted Review", "Pending Invite", "Tentative Sync"]
            )
        } else {
            XCTAssertTrue(viewModel.upcomingEvents.isEmpty)
        }
    }

    func testUpcomingPreviewSkipsAllDayAndDeclinedEvents() async {
        let calendar = MockCalendarService()
        calendar.stubPermissionStatus = .granted
        calendar.stubEvents = [
            makeEvent(title: "Real Meeting", meetUrl: "https://zoom.us/j/123"),
            makeEvent(title: "All-day Offsite", meetUrl: "https://zoom.us/j/456", isAllDay: true),
            makeEvent(title: "Declined Sync", meetUrl: "https://zoom.us/j/789", userStatus: .declined)
        ]
        let viewModel = makeViewModel(
            calendarMode: .notify,
            triggerFilter: .withLink,
            calendarService: calendar
        )
        viewModel.settingsViewModel.calendarPermissionStatus = .granted

        await viewModel.refreshUpcomingEvents().value

        if AppFeatures.calendarEnabled {
            XCTAssertEqual(viewModel.upcomingEvents.map(\.title), ["Real Meeting"])
        } else {
            XCTAssertTrue(viewModel.upcomingEvents.isEmpty)
        }
    }

    func testNotifyModeKeepsPendingInvitations() async {
        let calendar = MockCalendarService()
        calendar.stubPermissionStatus = .granted
        calendar.stubEvents = [
            makeEvent(title: "Accepted Review", meetUrl: "https://zoom.us/j/123", userStatus: .accepted),
            makeEvent(title: "Pending Invite", meetUrl: "https://zoom.us/j/456", userStatus: .pending)
        ]
        let viewModel = makeViewModel(
            calendarMode: .notify,
            triggerFilter: .withLink,
            calendarService: calendar
        )
        viewModel.settingsViewModel.calendarPermissionStatus = .granted

        await viewModel.refreshUpcomingEvents().value

        if AppFeatures.calendarEnabled {
            // Reminders stay lenient — pending invites still get a reminder, so
            // they remain visible in the preview (matches MeetingMonitor).
            XCTAssertEqual(
                Set(viewModel.upcomingEvents.map(\.title)),
                ["Accepted Review", "Pending Invite"]
            )
        } else {
            XCTAssertTrue(viewModel.upcomingEvents.isEmpty)
        }
    }

    func testUpcomingPreviewCollapsesRecurringOccurrencesToSoonest() async {
        // A recurring series returns one CalendarEvent per occurrence, all
        // sharing EventKit's `eventIdentifier` (= CalendarEvent.id). The preview
        // must collapse them to the soonest occurrence — both so the list shows
        // distinct meetings and because ForEach keys on `id` (duplicate ids give
        // SwiftUI undefined rendering). Coordinator behavior is unaffected; it
        // keys on dedupeKey and still acts on every occurrence.
        let calendar = MockCalendarService()
        calendar.stubPermissionStatus = .granted
        let base = Date().addingTimeInterval(3600)
        // Deliberately unsorted, with the soonest standup in the middle, to
        // prove the collapse picks soonest by start time, not array order.
        calendar.stubEvents = [
            makeEvent(title: "Standup Wed", meetUrl: "https://zoom.us/j/1", id: "standup", startTime: base.addingTimeInterval(2 * 86_400)),
            makeEvent(title: "Standup Mon", meetUrl: "https://zoom.us/j/1", id: "standup", startTime: base),
            makeEvent(title: "Standup Tue", meetUrl: "https://zoom.us/j/1", id: "standup", startTime: base.addingTimeInterval(86_400)),
            makeEvent(title: "1:1", meetUrl: "https://zoom.us/j/2", id: "one-on-one", startTime: base.addingTimeInterval(3 * 86_400))
        ]
        let viewModel = makeViewModel(
            calendarMode: .notify,
            triggerFilter: .withLink,
            calendarService: calendar
        )
        viewModel.settingsViewModel.calendarPermissionStatus = .granted

        await viewModel.refreshUpcomingEvents().value

        guard AppFeatures.calendarEnabled else {
            XCTAssertTrue(viewModel.upcomingEvents.isEmpty)
            return
        }
        // One row per series, soonest occurrence wins, ordered by start time.
        XCTAssertEqual(viewModel.upcomingEvents.map(\.title), ["Standup Mon", "1:1"])
        // No duplicate ids reach the id-keyed ForEach.
        XCTAssertEqual(Set(viewModel.upcomingEvents.map(\.id)).count, viewModel.upcomingEvents.count)
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
        id: String? = nil,
        startTime: Date? = nil,
        calendarIdentifier: String? = nil,
        userStatus: EventParticipant.ParticipantStatus? = nil,
        isAllDay: Bool = false
    ) -> CalendarEvent {
        let start = startTime ?? Date().addingTimeInterval(3600)
        return CalendarEvent(
            id: id ?? UUID().uuidString,
            title: title,
            startTime: start,
            endTime: start.addingTimeInterval(1800),
            meetUrl: meetUrl,
            participants: [EventParticipant(name: "Ava")],
            isAllDay: isAllDay,
            calendarName: "Work",
            calendarIdentifier: calendarIdentifier,
            userStatus: userStatus
        )
    }
}
