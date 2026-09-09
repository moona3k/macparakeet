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
            makeEvent(title: "Ignored Review", meetUrl: "https://meet.google.com/abc", calendarIdentifier: "personal"),
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
            makeEvent(title: "Declined Standup", meetUrl: "https://zoom.us/j/4", userStatus: .declined),
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
            makeEvent(title: "Declined Sync", meetUrl: "https://zoom.us/j/789", userStatus: .declined),
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
            makeEvent(title: "Pending Invite", meetUrl: "https://zoom.us/j/456", userStatus: .pending),
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
            makeEvent(
                title: "Standup Wed", meetUrl: "https://zoom.us/j/1", id: "standup",
                startTime: base.addingTimeInterval(2 * 86_400)),
            makeEvent(title: "Standup Mon", meetUrl: "https://zoom.us/j/1", id: "standup", startTime: base),
            makeEvent(
                title: "Standup Tue", meetUrl: "https://zoom.us/j/1", id: "standup",
                startTime: base.addingTimeInterval(86_400)),
            makeEvent(
                title: "1:1", meetUrl: "https://zoom.us/j/2", id: "one-on-one",
                startTime: base.addingTimeInterval(3 * 86_400)),
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

        pill.state = .starting
        XCTAssertEqual(viewModel.recordingStatus, .starting)
        XCTAssertTrue(viewModel.hasActiveRecording)

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

    func testMeetingAutoNotesListVisibleResultPromptsAndReflectScope() throws {
        let promptRepo = MockPromptRepository()
        promptRepo.prompts = [
            // Unscoped auto-run (nil = all sources) → counts as on for meetings.
            makeResultPrompt(name: "Summary", isAutoRun: true, sortOrder: 0),
            // Off by default.
            makeResultPrompt(name: "Action Items", isAutoRun: false, sortOrder: 1),
            // Auto-run but scoped to YouTube only → not a meeting auto-note.
            makeResultPrompt(name: "Blog Post", isAutoRun: true, sortOrder: 2, appliesToSources: [.youtube]),
            // Hidden → excluded from the card entirely.
            makeResultPrompt(name: "Hidden", isVisible: false, sortOrder: 3),
        ]
        let promptsVM = PromptsViewModel()
        promptsVM.configure(repo: promptRepo)

        let viewModel = makeViewModel(promptsViewModel: promptsVM)

        XCTAssertEqual(viewModel.meetingAutoNotePrompts.map(\.name), ["Summary", "Action Items", "Blog Post"])
        XCTAssertEqual(viewModel.meetingAutoNoteActivePrompts.map(\.name), ["Summary"])
        XCTAssertEqual(viewModel.meetingAutoNoteActiveCount, 1)
    }

    func testConfigureWiresPromptCollectionsForMeetingManager() throws {
        let manager = try DatabaseManager()
        let promptRepo = MockPromptRepository()
        let viewModel = makeViewModel()

        viewModel.configure(
            transcriptionRepo: MockTranscriptionRepository(),
            promptRepo: promptRepo,
            promptCollectionRepository: PromptCollectionRepository(dbQueue: manager.dbQueue)
        )

        viewModel.promptsViewModel.newCollectionName = "Customer meetings"
        viewModel.promptsViewModel.createCollection()

        XCTAssertEqual(viewModel.promptsViewModel.collections.map(\.name), ["Customer meetings"])
        XCTAssertNil(viewModel.promptsViewModel.errorMessage)
    }

    func testSetMeetingAutoNoteScopesToMeetingOnly() throws {
        let promptRepo = MockPromptRepository()
        promptRepo.prompts = [
            makeResultPrompt(name: "Action Items", isAutoRun: false, sortOrder: 0)
        ]
        let promptsVM = PromptsViewModel()
        promptsVM.configure(repo: promptRepo)
        let viewModel = makeViewModel(promptsViewModel: promptsVM)

        let actionItems = try XCTUnwrap(viewModel.meetingAutoNotePrompts.first)
        XCTAssertFalse(viewModel.isMeetingAutoNote(actionItems))

        viewModel.setMeetingAutoNote(actionItems, enabled: true)

        let toggled = try XCTUnwrap(viewModel.meetingAutoNotePrompts.first)
        XCTAssertTrue(viewModel.isMeetingAutoNote(toggled))
        XCTAssertEqual(
            toggled.appliesToSources, [.meeting], "Enabling from the Meetings card must scope to meetings only.")
        XCTAssertEqual(viewModel.meetingAutoNoteActiveCount, 1)
    }

    func testSetMeetingAutoNoteWithPolicyRepositoryWritesPromptAutoRunForMeetings() async throws {
        let promptRepo = MockPromptRepository()
        let actionItems = makeResultPrompt(name: "Action Items", isAutoRun: false, sortOrder: 0)
        promptRepo.prompts = [actionItems]
        let policyRepo = MockPromptMeetingPolicyRepository()
        policyRepo.policiesByPromptID[actionItems.id] = [.defaultForNewPrompt(actionItems)]
        let viewModel = makeViewModel()
        viewModel.configure(
            transcriptionRepo: MockTranscriptionRepository(),
            promptRepo: promptRepo,
            promptMeetingPolicyRepository: policyRepo
        )
        await viewModel.refreshAutoNotes().value

        let listed = try XCTUnwrap(viewModel.meetingAutoNotePrompts.first)
        XCTAssertFalse(listed.autoRuns(for: .meeting))

        viewModel.setMeetingAutoNote(listed, enabled: true)

        let toggled = try XCTUnwrap(promptRepo.fetch(id: actionItems.id))
        XCTAssertTrue(toggled.autoRuns(for: .meeting))
        XCTAssertEqual(toggled.appliesToSources, [.meeting])
        XCTAssertTrue(viewModel.isMeetingAutoNote(try XCTUnwrap(viewModel.meetingAutoNotePrompts.first)))
    }

    func testMeetingAutoNoteCardWithProductionRepositoriesControlsQueue() async throws {
        let manager = try DatabaseManager()
        let promptRepo = PromptRepository(dbQueue: manager.dbQueue)
        let labelPolicyRepo = PromptLabelPolicyRepository(dbQueue: manager.dbQueue)
        let meetingPolicyRepo = PromptMeetingPolicyRepository(dbQueue: manager.dbQueue)
        let meetingLabelRepo = MeetingLabelRepository(dbQueue: manager.dbQueue)
        let transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let transcriptionLabelRepo = TranscriptionMeetingLabelRepository(dbQueue: manager.dbQueue)
        let viewModel = makeViewModel()
        viewModel.configure(
            transcriptionRepo: transcriptionRepo,
            promptRepo: promptRepo,
            promptEditingService: PromptEditingService(dbQueue: manager.dbQueue),
            meetingLabelRepository: meetingLabelRepo,
            promptMeetingPolicyRepository: meetingPolicyRepo,
            promptLabelPolicyRepository: labelPolicyRepo
        )
        await viewModel.refreshAutoNotes().value

        let summary = try XCTUnwrap(viewModel.meetingAutoNotePrompts.first { $0.name == "Summary" })
        let actionItems = try XCTUnwrap(
            viewModel.meetingAutoNotePrompts.first { $0.name == "Action Items & Decisions" }
        )
        let chapter = try XCTUnwrap(
            viewModel.promptsViewModel.prompts.first { $0.name == "Chapter Breakdown" }
        )
        XCTAssertTrue(viewModel.isMeetingAutoNote(summary))
        XCTAssertFalse(viewModel.isMeetingAutoNote(actionItems))
        XCTAssertTrue(viewModel.meetingAutoNotePrompts.contains { $0.name == "Chapter Breakdown" })

        try promptRepo.toggleVisibility(id: chapter.id)
        await viewModel.refreshAutoNotes().value
        XCTAssertFalse(viewModel.meetingAutoNotePrompts.contains { $0.name == "Chapter Breakdown" })

        viewModel.setMeetingAutoNote(summary, enabled: false)
        viewModel.setMeetingAutoNote(actionItems, enabled: true)

        let storedSummary = try XCTUnwrap(promptRepo.fetch(id: summary.id))
        let storedActions = try XCTUnwrap(promptRepo.fetch(id: actionItems.id))
        XCTAssertFalse(storedSummary.autoRuns(for: .meeting))
        XCTAssertTrue(storedSummary.autoRuns(for: .youtube))
        XCTAssertTrue(storedSummary.autoRuns(for: .file))
        XCTAssertTrue(storedActions.autoRuns(for: .meeting))
        XCTAssertFalse(storedActions.autoRuns(for: .youtube))
        XCTAssertFalse(
            viewModel.isMeetingAutoNote(
                try XCTUnwrap(viewModel.meetingAutoNotePrompts.first { $0.name == "Summary" })
            )
        )
        XCTAssertTrue(
            viewModel.isMeetingAutoNote(
                try XCTUnwrap(
                    viewModel.meetingAutoNotePrompts.first { $0.name == "Action Items & Decisions" }
                )
            )
        )

        let meeting = Transcription(
            fileName: "standup.m4a",
            status: .completed,
            sourceType: .meeting
        )
        let youtube = Transcription(
            fileName: "talk.mp4",
            status: .completed,
            sourceType: .youtube
        )
        try transcriptionRepo.save(meeting)
        try transcriptionRepo.save(youtube)

        XCTAssertEqual(
            queuedPromptNames(
                promptRepo: promptRepo,
                promptResultRepo: PromptResultRepository(dbQueue: manager.dbQueue),
                labelPolicyRepo: labelPolicyRepo,
                transcriptionRepo: transcriptionRepo,
                transcriptionLabelRepo: transcriptionLabelRepo,
                transcriptionId: meeting.id,
                sourceType: .meeting
            ),
            ["Action Items & Decisions"]
        )
        XCTAssertEqual(
            queuedPromptNames(
                promptRepo: promptRepo,
                promptResultRepo: PromptResultRepository(dbQueue: manager.dbQueue),
                labelPolicyRepo: labelPolicyRepo,
                transcriptionRepo: transcriptionRepo,
                transcriptionLabelRepo: transcriptionLabelRepo,
                transcriptionId: youtube.id,
                sourceType: .youtube
            ),
            ["Summary"]
        )

        let customer = MeetingLabel(name: "Customer")
        try meetingLabelRepo.save(customer)
        try labelPolicyRepo.replaceTargetLabels(promptId: actionItems.id, labelIds: [customer.id])
        await viewModel.refreshAutoNotes().value
        XCTAssertFalse(viewModel.meetingAutoNotePrompts.contains { $0.name == "Action Items & Decisions" })
        XCTAssertEqual(
            queuedPromptNames(
                promptRepo: promptRepo,
                promptResultRepo: PromptResultRepository(dbQueue: manager.dbQueue),
                labelPolicyRepo: labelPolicyRepo,
                transcriptionRepo: transcriptionRepo,
                transcriptionLabelRepo: transcriptionLabelRepo,
                transcriptionId: meeting.id,
                sourceType: .meeting
            ),
            []
        )

        try transcriptionLabelRepo.replaceLabels(for: meeting.id, with: [customer.id])
        XCTAssertEqual(
            queuedPromptNames(
                promptRepo: promptRepo,
                promptResultRepo: PromptResultRepository(dbQueue: manager.dbQueue),
                labelPolicyRepo: labelPolicyRepo,
                transcriptionRepo: transcriptionRepo,
                transcriptionLabelRepo: transcriptionLabelRepo,
                transcriptionId: meeting.id,
                sourceType: .meeting
            ),
            ["Action Items & Decisions"]
        )
    }

    func testRefreshIfNeededReloadsAutoNotesFromSeparateRepositoriesWithoutReloadingCalendar() async throws {
        let manager = try DatabaseManager()
        let meetingsPromptRepo = PromptRepository(dbQueue: manager.dbQueue)
        let promptsTabPromptRepo = PromptRepository(dbQueue: manager.dbQueue)
        let meetingsLabelPolicyRepo = PromptLabelPolicyRepository(dbQueue: manager.dbQueue)
        let promptsTabLabelPolicyRepo = PromptLabelPolicyRepository(dbQueue: manager.dbQueue)
        let meetingLabelRepo = MeetingLabelRepository(dbQueue: manager.dbQueue)
        let transcriptionRepo = MockTranscriptionRepository()
        let calendar = MockCalendarService()
        calendar.stubPermissionStatus = .granted
        calendar.stubEvents = [makeEvent(title: "Design Review", meetUrl: "https://zoom.us/j/1")]
        let viewModel = makeViewModel(calendarMode: .notify, calendarService: calendar)
        viewModel.settingsViewModel.calendarPermissionStatus = .granted
        viewModel.configure(
            transcriptionRepo: transcriptionRepo,
            promptRepo: meetingsPromptRepo,
            promptEditingService: PromptEditingService(dbQueue: manager.dbQueue),
            meetingLabelRepository: meetingLabelRepo,
            promptMeetingPolicyRepository: PromptMeetingPolicyRepository(dbQueue: manager.dbQueue),
            promptLabelPolicyRepository: meetingsLabelPolicyRepo
        )

        viewModel.refreshIfNeeded()
        try await waitUntil { !transcriptionRepo.fetchAllCalls.isEmpty }
        if AppFeatures.calendarEnabled {
            try await waitUntil { calendar.fetchUpcomingEventsCallCount >= 1 }
        }

        let summary = try XCTUnwrap(viewModel.meetingAutoNotePrompts.first { $0.name == "Summary" })
        let actionItems = try XCTUnwrap(
            viewModel.meetingAutoNotePrompts.first { $0.name == "Action Items & Decisions" }
        )
        XCTAssertTrue(viewModel.isMeetingAutoNote(summary))
        XCTAssertTrue(viewModel.meetingAutoNotePrompts.contains { $0.id == actionItems.id })

        let calendarFetchesAfterFirstVisit = calendar.fetchUpcomingEventsCallCount
        let listLoadsAfterFirstVisit = transcriptionRepo.fetchAllCalls.count

        try promptsTabPromptRepo.setAutoRun(id: summary.id, source: .meeting, enabled: false)
        try promptsTabPromptRepo.setAutoRun(id: actionItems.id, source: .meeting, enabled: true)
        let customer = MeetingLabel(name: "Customer")
        try meetingLabelRepo.save(customer)
        try promptsTabLabelPolicyRepo.replaceTargetLabels(promptId: actionItems.id, labelIds: [customer.id])

        viewModel.refreshIfNeeded()

        XCTAssertFalse(
            viewModel.isMeetingAutoNote(
                try XCTUnwrap(viewModel.meetingAutoNotePrompts.first { $0.name == "Summary" })
            )
        )
        XCTAssertFalse(viewModel.meetingAutoNotePrompts.contains { $0.name == "Action Items & Decisions" })
        XCTAssertEqual(transcriptionRepo.fetchAllCalls.count, listLoadsAfterFirstVisit)
        if AppFeatures.calendarEnabled {
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(calendar.fetchUpcomingEventsCallCount, calendarFetchesAfterFirstVisit)
        }
    }

    func testLabelPolicyReloadFailureHidesUnknownChipsPreservesRestrictedCacheAndSurvivesMeetingReload() async throws {
        let promptRepo = MockPromptRepository()
        let summary = makeResultPrompt(name: "Summary", isAutoRun: true, sortOrder: 0)
        let actionItems = makeResultPrompt(name: "Action Items", isAutoRun: false, sortOrder: 1)
        promptRepo.prompts = [summary, actionItems]
        let labelPolicyRepo = MockPromptLabelPolicyRepository()
        labelPolicyRepo.fetchError = PromptLabelPolicyFetchError()
        let meetingPolicyRepo = MockPromptMeetingPolicyRepository()
        meetingPolicyRepo.policiesByPromptID[summary.id] = [.defaultForNewPrompt(summary)]
        meetingPolicyRepo.policiesByPromptID[actionItems.id] = [.defaultForNewPrompt(actionItems)]
        let viewModel = makeViewModel()
        viewModel.configure(
            transcriptionRepo: MockTranscriptionRepository(),
            promptRepo: promptRepo,
            promptMeetingPolicyRepository: meetingPolicyRepo,
            promptLabelPolicyRepository: labelPolicyRepo
        )

        await viewModel.refreshAutoNotes().value

        XCTAssertTrue(
            viewModel.meetingAutoNotePrompts.isEmpty,
            "First-load failure must not treat empty policies as unrestricted."
        )
        XCTAssertFalse(viewModel.isMeetingAutoNote(summary))
        XCTAssertNotNil(viewModel.meetingPolicyErrorMessage)
        viewModel.setMeetingAutoNote(summary, enabled: false)
        XCTAssertTrue(
            try XCTUnwrap(promptRepo.fetch(id: summary.id)).autoRuns(for: .meeting),
            "Unknown availability must not keep offering auto-note toggles."
        )

        await viewModel.loadPromptMeetingPolicies().value
        XCTAssertNotNil(viewModel.meetingPolicyErrorMessage)
        XCTAssertTrue(viewModel.meetingAutoNotePrompts.isEmpty)

        let customerLabelID = UUID()
        labelPolicyRepo.fetchError = nil
        labelPolicyRepo.policiesByPromptID[actionItems.id] = [
            PromptLabelPolicy(promptId: actionItems.id, scopeKind: .all, isAvailable: false),
            PromptLabelPolicy(
                promptId: actionItems.id,
                scopeKind: .label,
                labelId: customerLabelID,
                isAvailable: true
            ),
        ]
        await viewModel.refreshAutoNotes().value

        XCTAssertNil(viewModel.meetingPolicyErrorMessage)
        XCTAssertEqual(viewModel.meetingAutoNotePrompts.map(\.name), ["Summary"])
        XCTAssertTrue(viewModel.isMeetingAutoNote(summary))
        XCTAssertFalse(viewModel.meetingAutoNotePrompts.contains { $0.id == actionItems.id })

        labelPolicyRepo.fetchError = PromptLabelPolicyFetchError()
        await viewModel.refreshAutoNotes().value

        XCTAssertNotNil(viewModel.meetingPolicyErrorMessage)
        XCTAssertEqual(viewModel.meetingAutoNotePrompts.map(\.name), ["Summary"])
        XCTAssertTrue(viewModel.isMeetingAutoNote(summary))
        XCTAssertFalse(
            viewModel.meetingAutoNotePrompts.contains { $0.id == actionItems.id },
            "Last-good restrictions must survive a later read failure."
        )

        await viewModel.loadPromptMeetingPolicies().value
        XCTAssertNotNil(
            viewModel.meetingPolicyErrorMessage,
            "Meeting-policy reload success must not clear a label-policy load error."
        )
        XCTAssertFalse(viewModel.meetingAutoNotePrompts.contains { $0.id == actionItems.id })
    }

    func testSuccessfulDetailRenamePropagatesAcrossSeparateMeetingCollectionsInPlace() async throws {
        let target = Transcription(
            createdAt: Date(timeIntervalSinceReferenceDate: 300),
            fileName: "Meeting Sep 4",
            status: .completed,
            sourceType: .meeting,
            derivedTitle: "Generated target title"
        )
        let unrelatedLocal = Transcription(
            createdAt: Date(timeIntervalSinceReferenceDate: 200),
            fileName: "interview.m4a",
            status: .completed,
            sourceType: .file,
            derivedTitle: "Local interview"
        )
        let unrelatedMeeting = Transcription(
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            fileName: "Weekly Sync",
            status: .completed,
            sourceType: .meeting,
            derivedTitle: "Generated weekly title"
        )
        let repo = MockTranscriptionRepository()
        repo.transcriptions = [unrelatedMeeting, unrelatedLocal, target]

        let detailViewModel = TranscriptionViewModel()
        detailViewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: repo
        )
        detailViewModel.currentTranscription = target

        let libraryViewModel = TranscriptionLibraryViewModel()
        libraryViewModel.configure(transcriptionRepo: repo)
        let recentMeetingsViewModel = TranscriptionLibraryViewModel(scope: .meetings)
        let workspaceViewModel = makeViewModel(
            recentMeetingsViewModel: recentMeetingsViewModel
        )
        workspaceViewModel.configure(transcriptionRepo: repo)
        await libraryViewModel.loadTranscriptions().value
        await workspaceViewModel.refreshRecentMeetings().value

        XCTAssertFalse(libraryViewModel === recentMeetingsViewModel)
        let originalDetailOrder = detailViewModel.transcriptions.map(\.id)
        let originalLibraryOrder = libraryViewModel.groupedTranscriptions.flatMap { $0.items }.map(\.id)
        let originalRecentOrder = recentMeetingsViewModel.groupedTranscriptions.flatMap { $0.items }.map(\.id)

        detailViewModel.onMeetingRenamed = { rename in
            libraryViewModel.applyMeetingRename(rename)
            workspaceViewModel.recentMeetingsViewModel.applyMeetingRename(rename)
        }

        detailViewModel.renameCurrentTranscription(to: "Design Review")

        XCTAssertEqual(detailViewModel.currentTranscription?.fileName, "Design Review")
        XCTAssertEqual(
            detailViewModel.transcriptions.first(where: { $0.id == target.id })?.fileName,
            "Design Review"
        )
        XCTAssertEqual(
            libraryViewModel.filteredTranscriptions.first(where: { $0.id == target.id })?.fileName,
            "Design Review"
        )
        XCTAssertEqual(
            recentMeetingsViewModel.filteredTranscriptions.first(where: { $0.id == target.id })?.fileName,
            "Design Review"
        )
        XCTAssertEqual(
            [
                detailViewModel.transcriptions.first(where: { $0.id == target.id })?.derivedTitle,
                libraryViewModel.filteredTranscriptions.first(where: { $0.id == target.id })?.derivedTitle,
                recentMeetingsViewModel.filteredTranscriptions.first(where: { $0.id == target.id })?.derivedTitle,
            ],
            ["Design Review", "Design Review", "Design Review"]
        )
        XCTAssertEqual(detailViewModel.transcriptions.map(\.id), originalDetailOrder)
        XCTAssertEqual(
            libraryViewModel.groupedTranscriptions.flatMap { $0.items }.map(\.id),
            originalLibraryOrder
        )
        XCTAssertEqual(
            recentMeetingsViewModel.groupedTranscriptions.flatMap { $0.items }.map(\.id),
            originalRecentOrder
        )
        XCTAssertEqual(
            libraryViewModel.filteredTranscriptions.first(where: { $0.id == unrelatedLocal.id })?.derivedTitle,
            "Local interview"
        )
        XCTAssertEqual(
            detailViewModel.transcriptions.first(where: { $0.id == unrelatedLocal.id })?.derivedTitle,
            "Local interview"
        )
        XCTAssertEqual(
            libraryViewModel.filteredTranscriptions.first(where: { $0.id == unrelatedMeeting.id })?.fileName,
            "Weekly Sync"
        )
        XCTAssertEqual(
            recentMeetingsViewModel.filteredTranscriptions.first(where: { $0.id == unrelatedMeeting.id })?.derivedTitle,
            "Generated weekly title"
        )
    }

    func testPromptPoliciesLoadInOneBulkFetch() async {
        let promptRepo = MockPromptRepository()
        promptRepo.prompts = [
            makeResultPrompt(name: "Summary", sortOrder: 0),
            makeResultPrompt(name: "Actions", sortOrder: 1),
        ]
        let promptsVM = PromptsViewModel()
        promptsVM.configure(repo: promptRepo)
        let policyRepo = MockPromptMeetingPolicyRepository()
        let viewModel = makeViewModel(promptsViewModel: promptsVM)
        viewModel.configure(
            transcriptionRepo: MockTranscriptionRepository(),
            promptMeetingPolicyRepository: policyRepo
        )

        await viewModel.refreshAutoNotes().value

        XCTAssertEqual(policyRepo.bulkFetchCallCount, 1)
        XCTAssertEqual(policyRepo.singleFetchCallCount, 0)
    }

    func testPromptPolicyMockSerializesConcurrentReadsAndMutations() async throws {
        let policyRepo = MockPromptMeetingPolicyRepository()
        let promptID = UUID()
        try policyRepo.save(.allMeetings(promptId: promptID, isAvailable: true, isAutoRun: false))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for iteration in 0..<200 {
                        if worker.isMultiple(of: 2) {
                            _ = try policyRepo.setAllMeetingsPolicy(
                                promptId: promptID, isAvailable: true,
                                isAutoRun: iteration.isMultiple(of: 2), sortOrder: nil
                            )
                        } else {
                            let policies = try policyRepo.fetchPolicies(promptIds: [promptID])
                            XCTAssertEqual(policies.count, 1, "Scope replacement must be atomic")
                            XCTAssertEqual(policyRepo.policiesByPromptID[promptID]?.count, 1)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(policyRepo.bulkFetchCallCount, 800)
        XCTAssertEqual(try policyRepo.fetchPolicies(promptId: promptID).count, 1)
    }

    func testStalePromptPolicyLoadCannotOverwriteNewerMutation() async throws {
        let promptRepo = MockPromptRepository()
        let prompt = makeResultPrompt(name: "Summary", sortOrder: 0)
        promptRepo.prompts = [prompt]
        let promptsVM = PromptsViewModel()
        promptsVM.configure(repo: promptRepo)
        let policyRepo = MockPromptMeetingPolicyRepository()
        let oldPolicy = PromptMeetingPolicy.allMeetings(
            promptId: prompt.id,
            isAvailable: true,
            isAutoRun: false,
            sortOrder: prompt.sortOrder
        )
        policyRepo.policiesByPromptID[prompt.id] = [oldPolicy]
        let staleLoadStarted = expectation(description: "stale load started")
        let releaseStaleLoad = DispatchSemaphore(value: 0)
        let handlerLock = NSLock()
        var shouldBlockFirstLoad = true
        policyRepo.bulkFetchHandler = { promptIDs in
            let blocks = handlerLock.withLock {
                defer { shouldBlockFirstLoad = false }
                return shouldBlockFirstLoad
            }
            if blocks {
                let snapshot = promptIDs.flatMap { policyRepo.policiesByPromptID[$0] ?? [] }
                staleLoadStarted.fulfill()
                releaseStaleLoad.wait()
                return snapshot
            }
            return promptIDs.flatMap { policyRepo.policiesByPromptID[$0] ?? [] }
        }
        let viewModel = makeViewModel(promptsViewModel: promptsVM)
        viewModel.configure(
            transcriptionRepo: MockTranscriptionRepository(),
            promptMeetingPolicyRepository: policyRepo
        )

        let staleLoad = viewModel.refreshAutoNotes()
        await fulfillment(of: [staleLoadStarted], timeout: 1)
        let mutation = viewModel.setMeetingPolicy(
            prompt: prompt,
            meetingTypeID: nil,
            isAvailable: true,
            isAutoRun: true
        )
        let concurrentLoad = viewModel.loadPromptMeetingPolicies()
        await concurrentLoad.value
        await mutation.value
        releaseStaleLoad.signal()
        await staleLoad.value

        XCTAssertTrue(viewModel.meetingPolicyResolution(for: prompt, meetingTypeID: nil).isAutoRun)
        XCTAssertFalse(policyRepo.mutationRanOnMainThread)
        XCTAssertGreaterThanOrEqual(policyRepo.bulkFetchCallCount, 3)
    }

    private func makeViewModel(
        calendarMode: CalendarAutoStartMode = .off,
        triggerFilter: MeetingTriggerFilter = .withLink,
        excludedCalendarIds: Set<String> = [],
        recentMeetingsViewModel: TranscriptionLibraryViewModel? = nil,
        meetingPillViewModel: MeetingRecordingPillViewModel? = nil,
        promptsViewModel: PromptsViewModel? = nil,
        calendarService: MockCalendarService = MockCalendarService()
    ) -> MeetingsWorkspaceViewModel {
        defaults.set(calendarMode.rawValue, forKey: CalendarAutoStartPreferences.modeKey)
        defaults.set(triggerFilter.rawValue, forKey: CalendarAutoStartPreferences.triggerFilterKey)
        defaults.set(Array(excludedCalendarIds), forKey: CalendarAutoStartPreferences.excludedCalendarIdsKey)

        let settingsViewModel = SettingsViewModel(defaults: defaults)
        let llmSettingsViewModel = LLMSettingsViewModel(defaults: defaults)
        return MeetingsWorkspaceViewModel(
            recentMeetingsViewModel:
                recentMeetingsViewModel ?? TranscriptionLibraryViewModel(scope: .meetings),
            meetingPillViewModel: meetingPillViewModel ?? MeetingRecordingPillViewModel(),
            settingsViewModel: settingsViewModel,
            llmSettingsViewModel: llmSettingsViewModel,
            promptsViewModel: promptsViewModel,
            calendarService: calendarService
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private func queuedPromptNames(
        promptRepo: PromptRepository,
        promptResultRepo: PromptResultRepository,
        labelPolicyRepo: PromptLabelPolicyRepository,
        transcriptionRepo: TranscriptionRepository,
        transcriptionLabelRepo: TranscriptionMeetingLabelRepository,
        transcriptionId: UUID,
        sourceType: Transcription.SourceType
    ) -> [String] {
        let results = PromptResultsViewModel()
        results.configure(
            llmService: MockLLMService(),
            promptRepo: promptRepo,
            promptResultRepo: promptResultRepo,
            promptLabelPolicyRepository: labelPolicyRepo,
            transcriptionLabelRepository: transcriptionLabelRepo,
            transcriptionRepo: transcriptionRepo
        )
        _ = results.autoGeneratePromptResults(
            transcript: String(repeating: "Long transcript ", count: 50),
            transcriptionId: transcriptionId,
            sourceType: sourceType
        )
        return results.pendingGenerations.map(\.promptName)
    }

    private func makeResultPrompt(
        name: String,
        isVisible: Bool = true,
        isAutoRun: Bool = false,
        sortOrder: Int,
        appliesToSources: Set<Transcription.SourceType>? = nil
    ) -> Prompt {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return Prompt(
            id: UUID(),
            name: name,
            content: "content for \(name)",
            category: .result,
            isBuiltIn: true,
            isVisible: isVisible,
            isAutoRun: isAutoRun,
            sortOrder: sortOrder,
            createdAt: date,
            updatedAt: date,
            appliesToSources: appliesToSources
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

private struct PromptLabelPolicyFetchError: Error {}

private final class MockPromptLabelPolicyRepository: PromptLabelPolicyRepositoryProtocol, @unchecked Sendable {
    var policiesByPromptID: [UUID: [PromptLabelPolicy]] = [:]
    var fetchError: Error?

    func fetchPolicies(promptId: UUID) throws -> [PromptLabelPolicy] {
        if let fetchError { throw fetchError }
        return policiesByPromptID[promptId] ?? []
    }

    func fetchPolicies(promptIds: Set<UUID>) throws -> [PromptLabelPolicy] {
        if let fetchError { throw fetchError }
        return promptIds.flatMap { policiesByPromptID[$0] ?? [] }
    }

    func replaceTargetLabels(promptId: UUID, labelIds: Set<UUID>) throws {
        let now = Date()
        policiesByPromptID[promptId] =
            labelIds.isEmpty
            ? []
            : [
                PromptLabelPolicy(
                    promptId: promptId,
                    scopeKind: .all,
                    isAvailable: false,
                    createdAt: now,
                    updatedAt: now
                )
            ]
                + labelIds.map {
                    PromptLabelPolicy(
                        promptId: promptId,
                        scopeKind: .label,
                        labelId: $0,
                        isAvailable: true,
                        createdAt: now,
                        updatedAt: now
                    )
                }
    }
}
