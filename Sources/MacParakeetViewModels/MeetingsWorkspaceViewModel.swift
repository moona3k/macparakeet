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
                self.upcomingEvents = Array(
                    events
                        .filter { event in self.shouldShowCalendarEvent(event) }
                        .prefix(max(0, eventLimit))
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

    private func shouldShowCalendarEvent(_ event: CalendarEvent) -> Bool {
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
}
