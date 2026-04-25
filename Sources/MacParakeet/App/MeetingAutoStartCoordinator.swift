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

    // `nonisolated(unsafe)` so the nonisolated `deinit` can read these to
    // unregister observers. They're write-only after start() / stop() and
    // mutation always happens on the main actor — no race.
    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var calendarChangeObserver: NSObjectProtocol?
    private var cleanupTask: Task<Void, Never>?

    init(calendarService: CalendarService = .shared, settingsViewModel: SettingsViewModel) {
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
            // queue: .main lands the closure on the main thread but Swift 6
            // strict isolation still requires an explicit @MainActor hop.
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
            await handle(event, mode: mode)
        }

        adjustPollingFrequency(events: events)
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
            // Filter by stable EKCalendar.calendarIdentifier — title-based
            // filtering breaks when two calendars share a name or one is
            // renamed. If the identifier is missing for some reason, default
            // to including the event (fail open — better to over-notify than
            // silently miss a meeting).
            guard let identifier = event.calendarIdentifier else { return true }
            return !excluded.contains(identifier)
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

    private func handle(_ event: MeetingMonitor.MonitorEvent, mode: CalendarAutoStartMode) async {
        switch event {
        case .reminderDue(let calEvent):
            await showReminder(calEvent, mode: mode)

        case .autoStartDue, .lateJoinAvailable, .autoStopDue:
            // Phase D scope: notify-only. These are recognized by
            // `MeetingMonitor` so the enum stays Phase E-ready, but the
            // coordinator deliberately no-ops until the countdown toast +
            // recording trigger land.
            return
        }
    }

    private func showReminder(_ event: CalendarEvent, mode: CalendarAutoStartMode) async {
        // Mark before posting so a failed delivery doesn't cause us to
        // re-attempt every poll tick — better to miss one reminder than
        // spam the user.
        remindedEventIds.insert(event.id)

        // Defense in depth: we requested authorization at calendar grant
        // time, but the user may have revoked notifications since. Without
        // this check macOS silently drops `add()` and the user sees no
        // reminder despite Calendar being granted.
        guard await CalendarNotificationAuthorization.isAuthorized() else {
            logger.warning("Notification authorization missing — reminder for event id=\(event.id, privacy: .public) not delivered")
            return
        }

        let leadMinutes = settingsViewModel.calendarReminderMinutes
        // Notification UX: the headline is the timing + event name (the part
        // the user will scan first); the supporting line is the meeting
        // service ("Zoom", "Google Meet", etc.) so the user knows where to
        // click. Names match the field they populate in
        // `UNMutableNotificationContent`, not the semantic role of "title"
        // and "subtitle" — the previous swap was confusing on a re-read.
        let notificationTitle: String = {
            if leadMinutes > 0 {
                return "\(event.title) starts in \(leadMinutes) minute\(leadMinutes == 1 ? "" : "s")"
            }
            return "\(event.title) is starting"
        }()
        let notificationBody = event.meetUrl.flatMap(MeetingLinkParser.shared.identifyService) ?? "MacParakeet"

        let content = UNMutableNotificationContent()
        content.title = notificationTitle
        content.body = notificationBody
        content.sound = nil  // Reminders shouldn't compete with the user's Zoom join sound

        let request = UNNotificationRequest(
            identifier: "macparakeet.calendar.\(event.id)",
            content: content,
            trigger: nil  // Deliver immediately
        )

        // Only report `calendarReminderShown` after delivery actually succeeds —
        // otherwise telemetry over-reports and we lose signal on real failure
        // rates. The `remindedEventIds` mark above stays before the auth check,
        // because the alternative (mark on success only) would re-attempt every
        // poll tick when delivery transiently fails — better to miss a single
        // reminder than spam the user.
        do {
            try await UNUserNotificationCenter.current().add(request)
            Telemetry.send(.calendarReminderShown(
                mode: mode.rawValue,
                leadMinutes: leadMinutes,
                hasMeetUrl: event.meetUrl != nil
            ))
            logger.info("Reminder posted for event id=\(event.id, privacy: .public)")
        } catch {
            logger.error("Reminder notification failed: \(error.localizedDescription, privacy: .public)")
        }
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
                guard !Task.isCancelled else { return }
                await self?.cleanupStaleIds()
            }
        }
    }

    /// Async + structured. Runs on the main actor (the coordinator is
    /// `@MainActor`), with the EventKit fetch hopping to the
    /// `CalendarService` actor for thread safety. Errors propagate via the
    /// `try?` — silent failure is acceptable for a 24-hour janitor.
    private func cleanupStaleIds() async {
        guard let events = try? await calendarService.fetchUpcomingEvents(days: 7) else { return }
        let liveIds = Set(events.map(\.id))
        dismissedEventIds.formIntersection(liveIds)
        remindedEventIds.formIntersection(liveIds)
        countdownShownEventIds.formIntersection(liveIds)
    }
}
