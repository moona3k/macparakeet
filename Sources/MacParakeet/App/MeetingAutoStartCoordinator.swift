import AppKit
import EventKit
import MacParakeetCore
import MacParakeetViewModels
import OSLog
import UserNotifications

/// Polls the user's calendar and surfaces upcoming meetings via macOS
/// notifications. Phase D (ADR-017 Phase 1) — handles `.reminderDue` only;
/// `.autoStartDue` / `.lateJoinAvailable` / `.autoStopDue` are recognized by
/// `MeetingMonitor` but the coordinator no-ops on them. Phase E will wire the
/// countdown toast and recording trigger.
///
/// ```
///         ┌──────────────────────┐
///         │ EKEventStoreChanged  │──┐
///         └──────────────────────┘  │  immediate
///                                   ▼
///   60s/15s/5s adaptive Timer ──▶  poll() ──▶ MeetingMonitor.evaluate(...)
///                                                       │
///                                  ┌────────────────────┴────────────────┐
///                                  ▼                                     ▼
///                            .reminderDue                  (other cases queued for Phase E)
///                                  │
///                                  ▼
///                       UNUserNotificationCenter
///                       Telemetry.calendarReminderShown
/// ```
@MainActor
final class MeetingAutoStartCoordinator {
    private let calendarService: CalendarService
    private let settingsViewModel: SettingsViewModel
    private let logger = Logger(subsystem: "com.macparakeet", category: "MeetingAutoStart")

    /// Adaptive polling — see ADR-017 §7. We only recreate the `Timer` when
    /// the desired interval changes so a meeting 30s away gets sub-tick
    /// accuracy without the steady-state polling 12× per minute.
    private var pollingTimer: Timer?
    private var pollingInterval: TimeInterval = 0  // 0 = uninitialized

    private var dismissedEventIds: Set<String> = []
    private var remindedEventIds: Set<String> = []
    private var countdownShownEventIds: Set<String> = []

    private var settingsObserver: NSObjectProtocol?
    private var calendarChangeObserver: NSObjectProtocol?
    private var cleanupTask: Task<Void, Never>?

    init(calendarService: CalendarService, settingsViewModel: SettingsViewModel) {
        self.calendarService = calendarService
        self.settingsViewModel = settingsViewModel
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = calendarChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    func start() {
        // Defensive: do nothing when the entire feature is gated off at
        // compile time. Keeps test runs and CI clean even if AppDelegate
        // forgot to gate.
        guard AppFeatures.meetingRecordingEnabled else { return }

        scheduleCleanupTask()
        registerCalendarChangeObserver()
        registerSettingsObserver()
        rescheduleTimer(interval: 60)
        // Poll immediately so a meeting starting in the next minute doesn't
        // wait for the first tick.
        Task { await pollAsync() }

        logger.info("Meeting auto-start coordinator started")
    }

    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        pollingInterval = 0
        cleanupTask?.cancel()
        cleanupTask = nil
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
            settingsObserver = nil
        }
        if let observer = calendarChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            calendarChangeObserver = nil
        }
        logger.info("Meeting auto-start coordinator stopped")
    }

    // MARK: - Observers

    private func registerSettingsObserver() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetCalendarSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Hop to the main actor; the queue:.main parameter keeps us on
            // the main thread but Swift 6 still wants the explicit isolation.
            Task { @MainActor [weak self] in self?.handleSettingsChanged() }
        }
    }

    private func registerCalendarChangeObserver() {
        calendarChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logger.debug("EKEventStoreChanged — re-evaluating immediately")
                await self?.pollAsync()
            }
        }
    }

    private func handleSettingsChanged() {
        // Setting changes can disable a feature mid-flight (e.g., toggling
        // mode to .off). Re-evaluate immediately and reset adaptive polling
        // back to baseline so we don't keep the 5s timer alive for a feature
        // that's now disabled.
        rescheduleTimer(interval: 60)
        Task { await pollAsync() }
    }

    // MARK: - Polling

    private func pollAsync() async {
        let mode = settingsViewModel.calendarAutoStartMode
        guard mode != .off else { return }
        guard calendarService.permissionStatus == .granted else { return }

        let events: [CalendarEvent]
        do {
            // 7-day look-ahead is overkill for the next-poll logic but keeps
            // the per-calendar include filter cheap and lets adaptive polling
            // see a "next event" 90 minutes out.
            let raw = try await calendarService.fetchUpcomingEvents(days: 7)
            events = filterByIncludedCalendars(raw)
        } catch {
            logger.error("Failed to fetch events: \(error.localizedDescription, privacy: .public)")
            return
        }

        let config = currentConfig(mode: mode)
        let monitorEvents = MeetingMonitor.evaluate(
            events: events,
            now: Date(),
            config: config,
            activeRecording: false,  // Phase E wires this from the meeting coordinator
            dismissedEventIds: dismissedEventIds,
            remindedEventIds: remindedEventIds,
            countdownShownEventIds: countdownShownEventIds
        )

        for event in monitorEvents {
            handle(event, mode: mode)
        }

        adjustPollingFrequency(events: events)
    }

    @objc private func pollFromTimer() {
        Task { @MainActor [weak self] in await self?.pollAsync() }
    }

    private func currentConfig(mode: CalendarAutoStartMode) -> MeetingMonitor.Config {
        MeetingMonitor.Config(
            mode: mode,
            reminderMinutes: settingsViewModel.calendarReminderMinutes,
            countdownSeconds: 5,
            autoStopEnabled: settingsViewModel.calendarAutoStopEnabled,
            autoStopLeadSeconds: 30,
            triggerFilter: settingsViewModel.meetingTriggerFilter,
            lateJoinGraceMinutes: 10
        )
    }

    private func filterByIncludedCalendars(_ events: [CalendarEvent]) -> [CalendarEvent] {
        let excluded = settingsViewModel.calendarExcludedIdentifiers
        guard !excluded.isEmpty else { return events }
        return events.filter { event in
            // CalendarEvent doesn't carry the calendar identifier, only the
            // human-readable title. We match on title until/unless we add an
            // identifier to the model — for now this is "good enough" because
            // the include list is rendered with the same titles.
            guard let title = event.calendarName else { return true }
            return !excluded.contains(title)
        }
    }

    private func adjustPollingFrequency(events: [CalendarEvent]) {
        let now = Date()
        let nearest = events
            .filter { $0.startTime > now }
            .min(by: { $0.startTime < $1.startTime })

        guard let event = nearest else {
            rescheduleTimer(interval: 60)
            return
        }
        let secondsUntil = event.startTime.timeIntervalSince(now)
        let newInterval: TimeInterval
        if secondsUntil <= 30 {
            newInterval = 5
        } else if secondsUntil <= 120 {
            newInterval = 15
        } else {
            newInterval = 60
        }
        rescheduleTimer(interval: newInterval)
    }

    private func rescheduleTimer(interval: TimeInterval) {
        guard pollingInterval != interval else { return }
        pollingTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.pollAsync() }
        }
        // .common keeps the timer firing while menus / scrollers are tracking;
        // the default .default mode would silently pause those windows.
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer
        pollingInterval = interval
    }

    // MARK: - Event handling

    private func handle(_ event: MeetingMonitor.MonitorEvent, mode: CalendarAutoStartMode) {
        switch event {
        case .reminderDue(let calEvent):
            showReminder(calEvent, mode: mode)

        case .autoStartDue, .lateJoinAvailable, .autoStopDue:
            // Phase D scope: notify-only. Mark these as "seen" so we don't
            // log them on every tick once Phase E is wired.
            return
        }
    }

    private func showReminder(_ event: CalendarEvent, mode: CalendarAutoStartMode) {
        remindedEventIds.insert(event.id)

        let leadMinutes = settingsViewModel.calendarReminderMinutes
        let title = event.title
        let body: String = {
            if leadMinutes > 0 {
                return "\(title) starts in \(leadMinutes) minute\(leadMinutes == 1 ? "" : "s")"
            }
            return "\(title) is starting"
        }()
        let subtitle = event.meetUrl.flatMap(MeetingLinkParser.shared.identifyService) ?? "MacParakeet"

        let content = UNMutableNotificationContent()
        content.title = body
        content.body = subtitle
        content.sound = nil  // Reminders shouldn't compete with the user's Zoom join sound

        let request = UNNotificationRequest(
            identifier: "macparakeet.calendar.\(event.id)",
            content: content,
            trigger: nil  // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error {
                logger.error("Reminder notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        Telemetry.send(.calendarReminderShown(
            mode: mode.rawValue,
            leadMinutes: leadMinutes,
            hasMeetUrl: event.meetUrl != nil
        ))
        logger.info("Reminder posted for event id=\(event.id, privacy: .public)")
    }

    // MARK: - Cleanup

    /// Periodically prune state-machine sets so they don't grow unbounded
    /// across long-running app sessions. ~24h cadence is plenty — events
    /// older than a day will never re-fire any monitor case.
    private func scheduleCleanupTask() {
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                guard let self else { return }
                await MainActor.run { self.cleanupStaleIds() }
            }
        }
    }

    private func cleanupStaleIds() {
        Task { [weak self] in
            guard let self else { return }
            guard let events = try? await self.calendarService.fetchUpcomingEvents(days: 7) else { return }
            let liveIds = Set(events.map(\.id))
            await MainActor.run {
                self.dismissedEventIds.formIntersection(liveIds)
                self.remindedEventIds.formIntersection(liveIds)
                self.countdownShownEventIds.formIntersection(liveIds)
            }
        }
    }
}
