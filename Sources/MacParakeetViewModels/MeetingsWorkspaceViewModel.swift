import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class MeetingsWorkspaceViewModel {
    public enum RecordingStatus: Equatable {
        case ready
        case recording
        case paused
        case finishing
        case transcribing
        case error(String)
    }

    public enum CalendarStatus: Equatable {
        case unavailable
        case off
        case permissionNeeded
        case permissionDenied
        case loading
        case ready(mode: CalendarAutoStartMode)
        case error(String)
    }

    public enum IntelligenceStatus: Equatable {
        case setupNeeded
        case ready(displayName: String, isLocal: Bool)
        case cannotConnect(displayName: String, message: String)
    }

    public enum AttentionSeverity: Equatable, Sendable {
        case recommended
        case required
    }

    public enum AttentionAction: Equatable, Sendable {
        case recordMeeting
        case recoverMeetings
        case openCalendarSettings
        case openAISettings
    }

    public struct AttentionItem: Identifiable, Equatable, Sendable {
        public let id: String
        public let severity: AttentionSeverity
        public let title: String
        public let detail: String
        public let actionTitle: String
        public let action: AttentionAction

        public init(
            id: String,
            severity: AttentionSeverity,
            title: String,
            detail: String,
            actionTitle: String,
            action: AttentionAction
        ) {
            self.id = id
            self.severity = severity
            self.title = title
            self.detail = detail
            self.actionTitle = actionTitle
            self.action = action
        }
    }

    public let recentMeetingsViewModel: TranscriptionLibraryViewModel
    public let meetingPillViewModel: MeetingRecordingPillViewModel
    public let settingsViewModel: SettingsViewModel
    public let llmSettingsViewModel: LLMSettingsViewModel
    public let quickPromptsViewModel: QuickPromptsViewModel

    public private(set) var upcomingEvents: [CalendarEvent] = []
    public private(set) var isLoadingUpcomingEvents = false
    public private(set) var calendarErrorMessage: String?
    public var calendarLookAheadDays = 7
    public var upcomingEventLimit = 4

    @ObservationIgnored private let calendarService: any CalendarServicing
    @ObservationIgnored private var upcomingEventsTask: Task<Void, Never>?
    @ObservationIgnored private var upcomingEventsGeneration = 0
    @ObservationIgnored private var hasLoadedInitialState = false

    public init(
        recentMeetingsViewModel: TranscriptionLibraryViewModel,
        meetingPillViewModel: MeetingRecordingPillViewModel,
        settingsViewModel: SettingsViewModel,
        llmSettingsViewModel: LLMSettingsViewModel,
        quickPromptsViewModel: QuickPromptsViewModel? = nil,
        calendarService: any CalendarServicing = CalendarService.shared
    ) {
        self.recentMeetingsViewModel = recentMeetingsViewModel
        self.meetingPillViewModel = meetingPillViewModel
        self.settingsViewModel = settingsViewModel
        self.llmSettingsViewModel = llmSettingsViewModel
        self.quickPromptsViewModel = quickPromptsViewModel ?? QuickPromptsViewModel()
        self.calendarService = calendarService
    }

    deinit {
        upcomingEventsTask?.cancel()
    }

    public func configure(
        transcriptionRepo: TranscriptionRepositoryProtocol,
        quickPromptRepo: QuickPromptRepositoryProtocol? = nil
    ) {
        recentMeetingsViewModel.configure(transcriptionRepo: transcriptionRepo)
        if let quickPromptRepo {
            quickPromptsViewModel.configure(repo: quickPromptRepo)
        }
    }

    public func refresh() {
        hasLoadedInitialState = true
        refreshRecentMeetings()
        refreshUpcomingEvents()
        refreshQuickPrompts()
    }

    public func refreshIfNeeded() {
        guard !hasLoadedInitialState else { return }
        refresh()
    }

    @discardableResult
    public func refreshRecentMeetings() -> Task<Void, Never> {
        recentMeetingsViewModel.loadTranscriptions()
    }

    @discardableResult
    public func refreshUpcomingEvents() -> Task<Void, Never> {
        upcomingEventsTask?.cancel()
        upcomingEventsGeneration += 1
        let generation = upcomingEventsGeneration

        guard shouldFetchCalendarEvents else {
            isLoadingUpcomingEvents = false
            calendarErrorMessage = nil
            upcomingEvents = []
            let task = Task<Void, Never> {}
            upcomingEventsTask = task
            return task
        }

        isLoadingUpcomingEvents = true
        calendarErrorMessage = nil

        let lookAheadDays = calendarLookAheadDays
        let eventLimit = upcomingEventLimit
        let task = Task { @MainActor [weak self, calendarService] in
            do {
                let events = try await calendarService.fetchUpcomingEvents(days: lookAheadDays)
                guard let self, !Task.isCancelled, self.upcomingEventsGeneration == generation else { return }
                self.upcomingEvents = Self.collapseRecurringOccurrences(
                    events.filter { event in self.shouldShowCalendarEvent(event) },
                    limit: eventLimit
                )
                self.isLoadingUpcomingEvents = false
            } catch {
                guard let self, !Task.isCancelled, self.upcomingEventsGeneration == generation else { return }
                self.upcomingEvents = []
                self.isLoadingUpcomingEvents = false
                self.calendarErrorMessage = error.localizedDescription
            }
        }
        upcomingEventsTask = task
        return task
    }

    public func refreshQuickPrompts() {
        quickPromptsViewModel.refresh()
    }

    public var liveAskPromptVisiblePinnedCount: Int {
        quickPromptsViewModel.visiblePinned.count
    }

    public var liveAskPromptPreviewPrompts: [QuickPrompt] {
        Array(quickPromptsViewModel.visiblePinned.prefix(2))
    }

    public var recordingStatus: RecordingStatus {
        switch meetingPillViewModel.state {
        case .idle, .completed:
            return .ready
        case .recording:
            return .recording
        case .paused:
            return .paused
        case .completing:
            return .finishing
        case .transcribing:
            return .transcribing
        case .error(let message):
            return .error(message)
        }
    }

    public var hasActiveRecording: Bool {
        switch recordingStatus {
        case .recording, .paused, .finishing, .transcribing:
            return true
        case .ready, .error:
            return false
        }
    }

    public var calendarStatus: CalendarStatus {
        guard AppFeatures.calendarEnabled else { return .unavailable }
        guard settingsViewModel.calendarAutoStartMode != .off else { return .off }

        switch settingsViewModel.calendarPermissionStatus {
        case .notDetermined:
            return .permissionNeeded
        case .denied:
            return .permissionDenied
        case .granted:
            if isLoadingUpcomingEvents { return .loading }
            if let calendarErrorMessage { return .error(calendarErrorMessage) }
            return .ready(mode: settingsViewModel.calendarAutoStartMode)
        }
    }

    public var intelligenceStatus: IntelligenceStatus {
        switch llmSettingsViewModel.setupStatus {
        case .setUpNeeded:
            return .setupNeeded
        case .ready(let displayName):
            return .ready(
                displayName: displayName,
                isLocal: llmSettingsViewModel.isLocalConfiguration
            )
        case .cannotConnect(let displayName, let message):
            return .cannotConnect(displayName: displayName, message: message)
        }
    }

    public var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []

        if settingsViewModel.pendingMeetingRecoveryCount > 0 {
            let count = settingsViewModel.pendingMeetingRecoveryCount
            items.append(AttentionItem(
                id: "meeting-recovery",
                severity: .required,
                title: "Interrupted recording",
                detail: "\(count) partial recording\(count == 1 ? "" : "s") can be recovered.",
                actionTitle: "Recover",
                action: .recoverMeetings
            ))
        }

        if case .error(let message) = recordingStatus {
            items.append(AttentionItem(
                id: "recording-error",
                severity: .required,
                title: "Recording stopped",
                detail: message,
                actionTitle: "Record Again",
                action: .recordMeeting
            ))
        }

        if case .cannotConnect(let displayName, let message) = intelligenceStatus {
            items.append(AttentionItem(
                id: "ai-unavailable",
                severity: .recommended,
                title: "\(displayName) unavailable",
                detail: message,
                actionTitle: "Open AI Settings",
                action: .openAISettings
            ))
        }

        return items
    }

    private var shouldFetchCalendarEvents: Bool {
        AppFeatures.calendarEnabled
            && settingsViewModel.calendarAutoStartMode != .off
            && settingsViewModel.calendarPermissionStatus == .granted
    }

    /// Decides which fetched events appear in the "Upcoming" preview.
    ///
    /// This mirrors the *candidate* set MacParakeet acts on, so the preview
    /// never promises behavior the coordinator won't deliver. It matches the
    /// candidate filter of `MeetingAutoStartCoordinator` + `MeetingMonitor.evaluate`:
    ///   - exclude all-day and RSVP-declined events (`MeetingMonitor` candidate filter),
    ///   - exclude calendars the user opted out of (`filterByIncludedCalendars`),
    ///   - apply the trigger filter (`MeetingMonitor.passesFilter`).
    /// RSVP is deliberately NOT mode-gated here: every candidate gets a reminder
    /// in any non-`.off` mode, and `.pending`/`.tentative` differ only in whether
    /// they additionally auto-*record* (`MeetingMonitor.shouldAutoStart`) — a
    /// per-event nuance, not list membership. Hiding `.pending` in `.autoStart`
    /// would make the app remind about an event missing from this list.
    /// The only candidate-filter input not mirrored is `MeetingMonitor`'s
    /// runtime `dismissedEventIds` (coordinator-private session state); a
    /// dismissed event reappears here until it passes or the mode changes.
    /// If the candidate rules change in `MeetingMonitor`, update this in lockstep.
    private func shouldShowCalendarEvent(_ event: CalendarEvent) -> Bool {
        guard !event.isAllDay, !event.userDeclined else { return false }

        if let calendarIdentifier = event.calendarIdentifier,
           settingsViewModel.calendarExcludedIdentifiers.contains(calendarIdentifier) {
            return false
        }

        switch settingsViewModel.meetingTriggerFilter {
        case .withLink:
            return event.meetUrl != nil
        case .withParticipants:
            return !event.participants.isEmpty
        case .allEvents:
            return true
        }
    }

    /// Collapses occurrences of a recurring series down to its soonest
    /// occurrence, then caps the list to `limit`.
    ///
    /// Every occurrence of a recurring series shares one `CalendarEvent.id`
    /// (EventKit's `eventIdentifier` — see the identity note in
    /// `CalendarEvent.swift`). Two reasons this matters here:
    ///   1. The "Upcoming" preview should list *distinct* meetings, not the
    ///      same daily standup four times pushing every other meeting out of a
    ///      4-row preview.
    ///   2. The view renders `ForEach(upcomingEvents)` keyed on `id`, so
    ///      duplicate ids would give SwiftUI "undefined results" (collapsed or
    ///      mis-diffed rows).
    /// This collapse is display-only: `MeetingMonitor`/the coordinator still
    /// act on *every* occurrence (they key on `dedupeKey`, id + start time).
    /// Picks the soonest occurrence per id regardless of input order so the
    /// preview never depends on the service's sort guarantee.
    static func collapseRecurringOccurrences(_ events: [CalendarEvent], limit: Int) -> [CalendarEvent] {
        var soonestByID: [String: CalendarEvent] = [:]
        for event in events {
            if let existing = soonestByID[event.id], existing.startTime <= event.startTime { continue }
            soonestByID[event.id] = event
        }
        return Array(
            soonestByID.values
                .sorted { $0.startTime < $1.startTime }
                .prefix(max(0, limit))
        )
    }
}
