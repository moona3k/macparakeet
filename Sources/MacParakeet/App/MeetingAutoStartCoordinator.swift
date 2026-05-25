import AppKit
import EventKit
import MacParakeetCore
import MacParakeetViewModels
import OSLog
import UserNotifications

/// Polls the user's calendar and routes upcoming meetings to the right
/// surface (notification / countdown toast / recording flow).
/// ADR-017 Phases 1 + 2 are wired here. `.lateJoinAvailable` is a no-op
/// (Phase 3 territory — the enum case stays so Phase 3 can wire the
/// late-join toast without changing `evaluate(...)`).
///
/// Auto-*stop* was removed (ADR-017 amendment, 2026-05): scheduled end times
/// are unreliable, so the coordinator never stops a recording. Stopping is
/// left to the user / a future activity-based detector.
///
/// ```
///   ┌──────────────────────┐
///   │ EKEventStoreChanged  │──┐
///   └──────────────────────┘  │  immediate
///                             ▼
///   60s/15s/5s adaptive Timer ──▶ poll() ──▶ MeetingMonitor.evaluate(...)
///                                                  │
///                ┌─────────────┬───────────────────┴──────────────────┐
///                ▼             ▼                                      ▼
///         .reminderDue   .autoStartDue                     .lateJoinAvailable
///                │             │                                      │
///                ▼             ▼                                  (no-op,
///   UNUserNotificationCenter   5s countdown                       Phase 3)
///                              toast → start
/// ```
@MainActor
final class MeetingAutoStartCoordinator {
    private let calendarService: any CalendarServicing
    private let settingsViewModel: SettingsViewModel
    /// Closures to the meeting recording flow — passed in rather than the
    /// concrete coordinator so this file doesn't gain a reverse dependency
    /// on `MeetingRecordingFlowCoordinator` (and so tests can stub them).
    private let isRecordingActive: @MainActor () -> Bool
    /// Called when the user (or countdown completion) commits to starting
    /// an auto-start recording. The event title is forwarded so the
    /// recording flow can pre-name the saved transcription with the
    /// calendar event name instead of the date-based default. Returns the
    /// recording generation on success, or `nil` if the start was rejected
    /// (state busy) — the coordinator only needs the non-nil/nil distinction.
    private let onAutoStartConfirmed: @MainActor (_ title: String) -> Int?
    private let toastController: MeetingCountdownToastController
    private let logger = Logger(subsystem: "com.macparakeet", category: "MeetingAutoStart")

    /// Adaptive polling — see ADR-017 §7. We only recreate the `Timer` when
    /// the desired interval changes so a meeting 30s away gets sub-tick
    /// accuracy without the steady-state polling 12× per minute.
    private var pollingTimer: Timer?
    private var pollingInterval: TimeInterval = 0  // 0 = uninitialized

    /// Reentrancy guard for `pollAsync` — see the guard there for why a
    /// coincident poll is coalesced rather than allowed to interleave.
    private var isPolling = false
    /// Set when a poll is requested while one is already in flight. The
    /// in-flight poll runs exactly one more pass on completion so a settings
    /// change (or reschedule) made mid-fetch isn't lost until the next tick.
    private var pollAgainRequested = false

    private var dismissedEventIds: Set<String> = []
    private var remindedEventIds: Set<String> = []
    private var countdownShownEventIds: Set<String> = []

    // `nonisolated(unsafe)` so the nonisolated `deinit` can read these to
    // unregister observers. They're write-only after start() / stop() and
    // mutation always happens on the main actor — no race.
    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var calendarChangeObserver: NSObjectProtocol?
    /// `NSWorkspace.didWakeNotification` — polls immediately on wake so a
    /// meeting whose auto-start/stop window opened while the Mac slept gets
    /// caught (the repeating `Timer` doesn't fire during sleep). Lives on
    /// `NSWorkspace.shared.notificationCenter`, not `NotificationCenter.default`.
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?
    private var cleanupTask: Task<Void, Never>?

    init(
        calendarService: any CalendarServicing = CalendarService.shared,
        settingsViewModel: SettingsViewModel,
        isRecordingActive: @escaping @MainActor () -> Bool = { false },
        onAutoStartConfirmed: @escaping @MainActor (_ title: String) -> Int? = { _ in nil },
        toastController: MeetingCountdownToastController? = nil
    ) {
        self.calendarService = calendarService
        self.settingsViewModel = settingsViewModel
        self.isRecordingActive = isRecordingActive
        self.onAutoStartConfirmed = onAutoStartConfirmed
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
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    func start() {
        // Defensive: do nothing when the entire feature is gated off at
        // compile time. Keeps test runs and CI clean even if AppDelegate
        // forgot to gate.
        guard AppFeatures.meetingRecordingEnabled else { return }
        // Calendar auto-start is independently gated. When the calendar flag
        // is off we never poll, never request EventKit access, and never
        // schedule countdown toasts — even if meeting recording is enabled.
        guard AppFeatures.calendarEnabled else { return }

        scheduleCleanupTask()
        registerCalendarChangeObserver()
        registerSettingsObserver()
        registerWakeObserver()
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
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
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

    private func registerWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logger.debug("System woke — polling immediately")
                // pollAsync re-tunes the cadence at the end, so we don't need
                // to wait for the (possibly 60s-out) next timer tick to catch
                // a window that opened during sleep.
                await self?.pollAsync()
            }
        }
    }

    private func handleSettingsChanged() {
        // Setting changes can disable a feature mid-flight (e.g., toggling
        // mode to .off). Re-evaluate immediately and reset adaptive polling
        // back to baseline so we don't keep the 5s timer alive for a feature
        // that's now disabled.
        toastController.close()
        rescheduleTimer(interval: 60)
        Task { await pollAsync() }
    }

    // MARK: - Polling

    private func pollAsync() async {
        // Reentrancy guard. Timer ticks, EKEventStoreChanged bursts, settings
        // changes, and wake all spawn `Task { await pollAsync() }`. Without
        // this, two polls can interleave across the `await` fetch and both
        // pass the `!remindedEventIds.contains(...)` check before either
        // inserts — posting a *duplicate* reminder notification (which has no
        // dedupe of its own). One poll at a time; a coincident request is
        // safely dropped because the in-flight poll already reflects current
        // state (it re-reads settings, permission, and events itself).
        guard !isPolling else {
            // A poll arrived while one is in flight — coalesce it.
            pollAgainRequested = true
            return
        }
        isPolling = true
        defer {
            isPolling = false
            if pollAgainRequested {
                pollAgainRequested = false
                Task { @MainActor [weak self] in await self?.pollAsync() }
            }
        }

        let activeRecording = isRecordingActive()

        // Fast-path guards before the (awaited) fetch.
        guard settingsViewModel.calendarAutoStartMode != .off else {
            toastController.close()
            return
        }
        guard calendarService.permissionStatus == .granted else {
            toastController.close()
            return
        }

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

        // Re-read mode/permission AFTER the await: the user may have toggled
        // the feature off (or revoked Calendar access) during the fetch. The
        // pre-fetch values are stale; honoring the latest stops us from
        // processing a now-disabled feature one last time.
        let mode = settingsViewModel.calendarAutoStartMode
        guard mode != .off else {
            toastController.close()
            return
        }
        guard calendarService.permissionStatus == .granted else {
            toastController.close()
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
        // Soonest *future* start — drives auto-start window accuracy. With
        // auto-stop removed, the next start is the only thing the cadence
        // needs to track.
        let nextStart = events
            .filter { $0.startTime > now }
            .map { $0.startTime.timeIntervalSince(now) }
            .min()
        guard let secondsUntil = nextStart else {
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
        countdownShownEventIds.insert(event.dedupeKey)
        // Actual lead time — how far before T-0 the toast went up. The
        // auto-start window allows up to +30s past T-0, so clamp to 0
        // when we surface it after the event has already started.
        let leadSeconds = max(0, Int(event.startTime.timeIntervalSinceNow.rounded()))
        let serviceName = event.meetUrl.flatMap(MeetingLinkParser.shared.identifyService)

        // Rich variant per ADR-020 §10: only the calendar-driven start
        // path supplies CalendarContext (the view derives its status line
        // from `serviceName`). Manual hotkey/menu-bar/panel starts surface
        // the minimal layout.
        let calendarContext = MeetingCountdownToastViewModel.CalendarContext(
            attendeeCount: event.attendeeCount,
            serviceName: serviceName,
            steeringHint: "Take notes during the meeting. ⌘1 jumps to Notes."
        )

        toastController.showAutoStart(
            title: event.title,
            calendarContext: calendarContext
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

    /// Internal entry point for the auto-start outcome routing. Public to
    /// the test target so tests can exercise the routing without driving
    /// real toast UI; production code reaches this only via the toast
    /// controller's outcome callback.
    func handleAutoStartOutcome(_ outcome: MeetingCountdownToastOutcome, for event: CalendarEvent) {
        switch outcome {
        case .completed, .primedEarly:
            guard settingsViewModel.calendarAutoStartMode == .autoStart,
                  calendarService.permissionStatus == .granted else {
                countdownShownEventIds.remove(event.dedupeKey)
                logger.info("Auto-start completion ignored — calendar auto-start is no longer enabled")
                return
            }
            guard onAutoStartConfirmed(event.title) != nil else {
                // Start was rejected (state_busy — a prior recording is still
                // wrapping up). Drop this occurrence's countdown-shown mark so
                // it can retry on a later poll once the blocking recording
                // ends. Otherwise a true back-to-back meeting is permanently
                // suppressed. Retry only helps while still inside the
                // auto-start window [start-5s, start+30s]; later than that is
                // Phase-3 late-join territory.
                countdownShownEventIds.remove(event.dedupeKey)
                logger.info("Auto-start rejected (state busy) for event id=\(event.id, privacy: .public) — will retry after current recording ends")
                return
            }
            logger.info("Auto-start confirmed for event id=\(event.id, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)")
        case .userDismissed:
            dismissedEventIds.insert(event.dedupeKey)
            Telemetry.send(.calendarAutoStartCancelled(reason: "user_cancel"))
            logger.info("Auto-start cancelled by user for event id=\(event.id, privacy: .public)")
        case .programmaticClose:
            // Another toast preempted us — no telemetry, no recording.
            return
        }
    }
}

/// Hooks for unit tests. The `testHook_` prefix marks them as test-only
/// so they don't pollute autocomplete in production code paths. Not
/// `#if DEBUG`-gated so `swift test -c release` (CI perf lane) still
/// links — the methods are `internal` so they don't escape the module.
extension MeetingAutoStartCoordinator {
    var testHook_pollingInterval: TimeInterval { pollingInterval }

    /// Simulate the private `showAutoStartCountdown` having marked an event as
    /// countdown-shown (without driving real toast UI).
    func testHook_markCountdownShown(_ event: CalendarEvent) {
        countdownShownEventIds.insert(event.dedupeKey)
    }

    func testHook_isCountdownShown(_ event: CalendarEvent) -> Bool {
        countdownShownEventIds.contains(event.dedupeKey)
    }

    var testHook_pollAgainRequested: Bool { pollAgainRequested }

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

    func testHook_forcePoll() {
        Task { @MainActor [weak self] in await self?.pollAsync() }
    }
}

private extension MeetingAutoStartCoordinator {
    func showReminder(_ event: CalendarEvent, mode: CalendarAutoStartMode) async {
        // Mark before posting so a failed delivery doesn't cause us to
        // re-attempt every poll tick — better to miss one reminder than
        // spam the user.
        remindedEventIds.insert(event.dedupeKey)

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
        let liveIds = Set(events.map(\.dedupeKey))
        dismissedEventIds.formIntersection(liveIds)
        remindedEventIds.formIntersection(liveIds)
        countdownShownEventIds.formIntersection(liveIds)
    }
}
