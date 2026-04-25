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
    private let calendarService: any CalendarServicing
    private let settingsViewModel: SettingsViewModel
    /// Closures to the meeting recording flow — passed in rather than the
    /// concrete coordinator so this file doesn't gain a reverse dependency
    /// on `MeetingRecordingFlowCoordinator` (and so tests can stub them).
    /// All Phase 2 wiring goes through these three callbacks.
    private let isRecordingActive: @MainActor () -> Bool
    private let onAutoStartConfirmed: @MainActor () -> Void
    private let onAutoStopConfirmed: @MainActor () -> Void
    private let toastController: MeetingCountdownToastController
    private let logger = Logger(subsystem: "com.macparakeet", category: "MeetingAutoStart")

    /// Adaptive polling — see ADR-017 §7. We only recreate the `Timer` when
    /// the desired interval changes so a meeting 30s away gets sub-tick
    /// accuracy without the steady-state polling 12× per minute.
    private var pollingTimer: Timer?
    private var pollingInterval: TimeInterval = 0  // 0 = uninitialized

    private var dismissedEventIds: Set<String> = []
    private var remindedEventIds: Set<String> = []
    private var countdownShownEventIds: Set<String> = []
    /// `event.id` of the calendar event that triggered the *current*
    /// recording. Lets `.autoStopDue` only act on auto-started recordings —
    /// a manually-started recording during a calendar event is not auto-
    /// stopped (per ADR-017 §10). Cleared when recording ends (detected by
    /// next poll seeing `isRecordingActive() == false` while we still hold
    /// an id) or when auto-stop fires.
    private var autoStartedEventId: String?
    /// `event.id` of an auto-started recording for which we're currently
    /// showing the auto-stop countdown. Prevents re-firing the toast on
    /// every poll tick during the 30s window.
    private var autoStopCountdownEventId: String?

    // `nonisolated(unsafe)` so the nonisolated `deinit` can read these to
    // unregister observers. They're write-only after start() / stop() and
    // mutation always happens on the main actor — no race.
    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var calendarChangeObserver: NSObjectProtocol?
    private var cleanupTask: Task<Void, Never>?

    init(
        calendarService: any CalendarServicing = CalendarService.shared,
        settingsViewModel: SettingsViewModel,
        isRecordingActive: @escaping @MainActor () -> Bool = { false },
        onAutoStartConfirmed: @escaping @MainActor () -> Void = {},
        onAutoStopConfirmed: @escaping @MainActor () -> Void = {},
        toastController: MeetingCountdownToastController? = nil
    ) {
        self.calendarService = calendarService
        self.settingsViewModel = settingsViewModel
        self.isRecordingActive = isRecordingActive
        self.onAutoStartConfirmed = onAutoStartConfirmed
        self.onAutoStopConfirmed = onAutoStopConfirmed
        // The toast controller is `@MainActor`-isolated, so its default
        // can't be expressed as a parameter default (initializer evaluation
        // happens in the caller's actor context). Construct here when the
        // caller didn't inject one.
        self.toastController = toastController ?? MeetingCountdownToastController()
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
        toastController.close()
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
        // Run binding-cleanup *before* the early returns so toggling mode
        // off (or losing permission) while an auto-started recording is in
        // flight doesn't strand a stale `autoStartedEventId` until the
        // user re-enables.
        let activeRecording = isRecordingActive()
        if !activeRecording, autoStartedEventId != nil {
            autoStartedEventId = nil
            autoStopCountdownEventId = nil
        }

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
            activeRecording: activeRecording,
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
        // Soonest *future* start — drives auto-start window accuracy.
        let nextStart = events
            .filter { $0.startTime > now }
            .map { $0.startTime.timeIntervalSince(now) }
            .min()
        // Soonest *end* of an in-progress event we're recording — without
        // this, a single isolated meeting would keep polling at 60s and
        // the [endTime - 30s, endTime] auto-stop window would slip
        // through (60s cadence + arbitrary phase = miss). Only relevant
        // when auto-stop is enabled and we're actually recording.
        let nextEnd: TimeInterval? = {
            guard isRecordingActive(), settingsViewModel.calendarAutoStopEnabled else { return nil }
            return events
                .filter { $0.startTime <= now && $0.endTime > now }
                .map { $0.endTime.timeIntervalSince(now) }
                .min()
        }()
        guard let secondsUntil = [nextStart, nextEnd].compactMap({ $0 }).min() else {
            rescheduleTimer(interval: 60)
            return
        }
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

        case .autoStartDue(let calEvent):
            showAutoStartCountdown(calEvent)

        case .autoStopDue(let calEvent):
            showAutoStopCountdown(calEvent)

        case .lateJoinAvailable:
            // Phase 3 — UI not built. The enum case stays so Phase 3 wires
            // the late-join toast without changing `evaluate(...)`.
            return
        }
    }

    // MARK: - Auto-start countdown (Phase 2)

    /// Show the 5s pre-meeting countdown. Marks the event as countdown-shown
    /// regardless of outcome so we don't re-fire on the next poll tick.
    /// Outcome handling:
    /// - `.completed` / `.primedEarly` → trigger recording, mark as auto-started
    /// - `.userDismissed` → add to dismissed set so monitor stops emitting
    /// - `.programmaticClose` → no-op (another toast preempted us)
    private func showAutoStartCountdown(_ event: CalendarEvent) {
        countdownShownEventIds.insert(event.id)
        // Actual lead time — how far before T-0 the toast went up. The
        // auto-start window allows up to +30s past T-0, so clamp to 0
        // when we surface it after the event has already started.
        let leadSeconds = max(0, Int(event.startTime.timeIntervalSinceNow.rounded()))
        let serviceName = event.meetUrl.flatMap(MeetingLinkParser.shared.identifyService)
        let body = serviceName.map { "Recording will start automatically — joining \($0)?" }
            ?? "Recording will start automatically."

        toastController.showAutoStart(
            title: event.title,
            body: body
        ) { [weak self] outcome in
            self?.handleAutoStartOutcome(outcome, for: event)
        }

        // Fire telemetry *after* `showAutoStart` returns so the event name
        // matches what the user actually saw — its docstring says "fires
        // when the toast is presented."
        Telemetry.send(.calendarAutoStartTriggered(
            leadSeconds: leadSeconds,
            hasMeetUrl: event.meetUrl != nil
        ))
    }

    /// Drop any optimistic auto-start binding. Called by
    /// `MeetingRecordingFlowCoordinator.onAutoStartFailed` when the
    /// downstream start either silently no-oped (state machine wasn't
    /// idle — likely the previous meeting is still wrapping up) or threw
    /// during the underlying `startRecording()`. Without this, a stale
    /// binding can suppress the *next* meeting's auto-stop window.
    func clearAutoStartBinding() {
        autoStartedEventId = nil
        autoStopCountdownEventId = nil
        logger.info("Auto-start binding cleared (start failed or state busy)")
    }

    /// Internal entry point for the auto-start outcome routing. Public to
    /// the test target so tests can exercise the routing without driving
    /// real toast UI; production code reaches this only via the toast
    /// controller's outcome callback.
    func handleAutoStartOutcome(_ outcome: MeetingCountdownToastOutcome, for event: CalendarEvent) {
        switch outcome {
        case .completed, .primedEarly:
            autoStartedEventId = event.id
            onAutoStartConfirmed()
            logger.info("Auto-start confirmed for event id=\(event.id, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)")
        case .userDismissed:
            dismissedEventIds.insert(event.id)
            Telemetry.send(.calendarAutoStartCancelled(reason: "user_cancel"))
            logger.info("Auto-start cancelled by user for event id=\(event.id, privacy: .public)")
        case .programmaticClose:
            // Another toast preempted us — no telemetry, no recording.
            return
        }
    }

    // MARK: - Auto-stop countdown (Phase 2)

    /// Show the 30s end-of-meeting countdown — only for recordings the
    /// coordinator started itself. Manually-started recordings during a
    /// calendar event are not auto-stopped (ADR-017 §10).
    private func showAutoStopCountdown(_ event: CalendarEvent) {
        // Only act on the binding the coordinator owns. Manual recordings
        // are sovereign — auto-stop never touches them.
        guard autoStartedEventId == event.id else { return }
        // Don't re-stack the toast on every poll while it's already up.
        guard autoStopCountdownEventId != event.id else { return }
        autoStopCountdownEventId = event.id

        let durationSeconds = event.endTime.timeIntervalSince(event.startTime)
        Telemetry.send(.calendarAutoStopShown(eventDurationSeconds: durationSeconds))

        toastController.showAutoStop(
            title: event.title,
            body: "Meeting ending — recording will stop automatically."
        ) { [weak self] outcome in
            self?.handleAutoStopOutcome(outcome, for: event)
        }
    }

    /// Internal entry point for the auto-stop outcome routing — symmetric
    /// to `handleAutoStartOutcome`. Test target uses this directly via
    /// the testHook extension below.
    func handleAutoStopOutcome(_ outcome: MeetingCountdownToastOutcome, for event: CalendarEvent) {
        switch outcome {
        case .completed, .primedEarly:
            onAutoStopConfirmed()
            autoStartedEventId = nil
            autoStopCountdownEventId = nil
            logger.info("Auto-stop confirmed for event id=\(event.id, privacy: .public)")
        case .userDismissed:
            dismissedEventIds.insert(event.id)
            autoStopCountdownEventId = nil
            Telemetry.send(.calendarAutoStopCancelled)
            logger.info("Auto-stop cancelled by user for event id=\(event.id, privacy: .public)")
        case .programmaticClose:
            autoStopCountdownEventId = nil
            return
        }
    }
}

#if DEBUG
/// Hooks for unit tests. The `testHook_` prefix marks them as test-only
/// so they don't pollute autocomplete in production code paths.
extension MeetingAutoStartCoordinator {
    var testHook_autoStartedEventId: String? { autoStartedEventId }

    func testHook_simulateAutoStartConfirmed(eventId: String) {
        let event = CalendarEvent(
            id: eventId,
            title: "Test",
            startTime: Date(),
            endTime: Date().addingTimeInterval(1800)
        )
        handleAutoStartOutcome(.completed, for: event)
    }

    func testHook_simulateAutoStartCancelled(eventId: String) {
        let event = CalendarEvent(
            id: eventId,
            title: "Test",
            startTime: Date(),
            endTime: Date().addingTimeInterval(1800)
        )
        handleAutoStartOutcome(.userDismissed, for: event)
    }

    func testHook_simulateAutoStopFired(eventId: String) {
        // Mimic the production guard: only proceed if the event matches
        // the coordinator's auto-started binding.
        guard autoStartedEventId == eventId else { return }
        let event = CalendarEvent(
            id: eventId,
            title: "Test",
            startTime: Date().addingTimeInterval(-1800),
            endTime: Date().addingTimeInterval(20)
        )
        handleAutoStopOutcome(.completed, for: event)
    }

    func testHook_forcePoll() {
        Task { @MainActor [weak self] in await self?.pollAsync() }
    }
}
#endif

private extension MeetingAutoStartCoordinator {
    func showReminder(_ event: CalendarEvent, mode: CalendarAutoStartMode) async {
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
