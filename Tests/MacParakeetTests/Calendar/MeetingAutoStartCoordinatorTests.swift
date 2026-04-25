import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class MeetingAutoStartCoordinatorTests: XCTestCase {

    // MARK: - Fixtures

    private var defaults: UserDefaults!
    private var settingsViewModel: SettingsViewModel!
    private var calendarService: MockCalendarService!

    /// Tracks calls to the recording-flow callbacks the coordinator makes.
    private var recordingActiveStub = false
    private var autoStartConfirmedCount = 0
    private var autoStopConfirmedCount = 0

    override func setUp() {
        super.setUp()
        let suite = "com.macparakeet.tests.coordinator.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // Tests seed defaults before constructing SettingsViewModel via
        // `seedSettings(...)` so VM init reads the right values without
        // firing `didSet` (which under `.notify`/`.autoStart` would call
        // `UNUserNotificationCenter.current()` — that API crashes in the
        // xctest bundle since there's no host app's notification center).
        calendarService = MockCalendarService()
        recordingActiveStub = false
        autoStartConfirmedCount = 0
        autoStopConfirmedCount = 0
    }

    /// Seed `UserDefaults` *before* the SettingsViewModel is constructed
    /// so init reads the values rather than each property running its
    /// `didSet` side-effects (which include notification-auth requests
    /// that crash in the test bundle).
    private func seedSettings(
        mode: CalendarAutoStartMode = .off,
        reminderMinutes: Int = 5,
        triggerFilter: MeetingTriggerFilter = .withLink,
        autoStopEnabled: Bool = true
    ) {
        defaults.set(mode.rawValue, forKey: CalendarAutoStartPreferences.modeKey)
        defaults.set(reminderMinutes, forKey: CalendarAutoStartPreferences.reminderMinutesKey)
        defaults.set(triggerFilter.rawValue, forKey: CalendarAutoStartPreferences.triggerFilterKey)
        defaults.set(autoStopEnabled, forKey: CalendarAutoStartPreferences.autoStopEnabledKey)
        settingsViewModel = SettingsViewModel(defaults: defaults)
    }

    override func tearDown() {
        defaults = nil
        settingsViewModel = nil
        calendarService = nil
        super.tearDown()
    }

    private func makeCoordinator(
        toastController: MeetingCountdownToastController? = nil
    ) -> MeetingAutoStartCoordinator {
        MeetingAutoStartCoordinator(
            calendarService: calendarService,
            settingsViewModel: settingsViewModel,
            isRecordingActive: { [weak self] in self?.recordingActiveStub ?? false },
            onAutoStartConfirmed: { [weak self] in self?.autoStartConfirmedCount += 1 },
            onAutoStopConfirmed: { [weak self] in self?.autoStopConfirmedCount += 1 },
            toastController: toastController
        )
    }

    private func event(
        id: String = "evt-1",
        title: String = "Standup",
        startsIn seconds: TimeInterval = 5 * 60,
        durationMinutes: Int = 30,
        meetUrl: String? = "https://zoom.us/j/123"
    ) -> CalendarEvent {
        let now = Date()
        let start = now.addingTimeInterval(seconds)
        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        return CalendarEvent(
            id: id,
            title: title,
            startTime: start,
            endTime: end,
            meetUrl: meetUrl,
            participants: [EventParticipant(email: "alice@example.com")],
            calendarIdentifier: "cal-1",
            userStatus: .accepted
        )
    }

    /// Wait for an actor / Task hop to settle. Coordinator polls inside
    /// `Task { await pollAsync() }` from observer + start, so a single
    /// `Task.yield()` isn't enough — give the runloop a tick.
    private func waitForPoll() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Lifecycle

    func testStopIsIdempotentAndDoesNotCrashIfNotStarted() {
        seedSettings(mode: .off)
        let coordinator = makeCoordinator()
        coordinator.stop()  // never started
        coordinator.stop()  // double-stop after initial
    }

    func testSettingsChangeNotificationTriggersImmediateRePoll() async {
        calendarService.stubPermissionStatus = .granted
        calendarService.stubEvents = [event(startsIn: 5 * 60)]
        seedSettings(mode: .notify, reminderMinutes: 5)

        let coordinator = makeCoordinator()
        coordinator.start()
        await waitForPoll()
        let baseline = calendarService.fetchUpcomingEventsCallCount

        // Posting the notification should cause an extra fetch beyond the
        // start-time poll.
        NotificationCenter.default.post(
            name: .macParakeetCalendarSettingsDidChange,
            object: nil
        )
        await waitForPoll()
        XCTAssertGreaterThan(calendarService.fetchUpcomingEventsCallCount, baseline)

        coordinator.stop()
    }

    func testOffModeShortCircuitsBeforeFetch() async {
        calendarService.stubPermissionStatus = .granted
        seedSettings(mode: .off)

        let coordinator = makeCoordinator()
        coordinator.start()
        await waitForPoll()

        XCTAssertEqual(calendarService.fetchUpcomingEventsCallCount, 0,
                       "Off mode must not touch the calendar service")

        coordinator.stop()
    }

    func testMissingPermissionShortCircuitsBeforeFetch() async {
        calendarService.stubPermissionStatus = .denied
        seedSettings(mode: .notify)

        let coordinator = makeCoordinator()
        coordinator.start()
        await waitForPoll()

        XCTAssertEqual(calendarService.fetchUpcomingEventsCallCount, 0,
                       "Denied permission must not attempt a fetch")

        coordinator.stop()
    }

    // MARK: - Auto-start outcome routing

    func testAutoStartCompletedTriggersRecording() async {
        calendarService.stubPermissionStatus = .granted
        seedSettings(mode: .autoStart)

        let toast = MeetingCountdownToastController()
        let coordinator = makeCoordinator(toastController: toast)
        coordinator.start()
        await waitForPoll()

        // Skip the actual countdown — manually invoke the test surface
        // that the coordinator wires. The countdown UX is covered by
        // toast-controller tests; here we're testing the coordinator's
        // outcome plumbing.
        coordinator.testHook_simulateAutoStartConfirmed(eventId: "evt-1")
        XCTAssertEqual(autoStartConfirmedCount, 1,
                       "Recording start callback must fire on .completed outcome")

        coordinator.stop()
    }

    func testAutoStartUserCancelDoesNotTriggerRecording() async {
        calendarService.stubPermissionStatus = .granted
        seedSettings(mode: .autoStart)

        let coordinator = makeCoordinator()
        coordinator.start()
        await waitForPoll()

        coordinator.testHook_simulateAutoStartCancelled(eventId: "evt-1")
        XCTAssertEqual(autoStartConfirmedCount, 0)

        coordinator.stop()
    }

    // MARK: - Auto-stop binding

    func testAutoStopOnlyFiresForCoordinatorOwnedRecording() async {
        // Manually-started recording during a calendar event should NOT
        // trigger the auto-stop toast even if the event is in the auto-stop
        // window. The coordinator's `autoStartedEventId` binding is empty,
        // so MeetingMonitor's `.autoStopDue` no-ops in the handler.
        calendarService.stubPermissionStatus = .granted
        seedSettings(mode: .autoStart)
        recordingActiveStub = true

        let coordinator = makeCoordinator()
        coordinator.start()
        await waitForPoll()

        coordinator.testHook_simulateAutoStopFired(eventId: "evt-not-bound")
        XCTAssertEqual(autoStopConfirmedCount, 0,
                       "Manual recordings must not be auto-stopped")

        coordinator.stop()
    }

    func testManualStopOfAutoStartedRecordingClearsBinding() async {
        calendarService.stubPermissionStatus = .granted
        seedSettings(mode: .autoStart)

        let coordinator = makeCoordinator()
        coordinator.start()
        await waitForPoll()

        // Simulate auto-start: recording becomes active, binding set.
        coordinator.testHook_simulateAutoStartConfirmed(eventId: "evt-1")
        recordingActiveStub = true
        XCTAssertEqual(coordinator.testHook_autoStartedEventId, "evt-1")

        // User manually stops the recording mid-meeting.
        recordingActiveStub = false
        // Force a fresh poll so the coordinator notices and clears the
        // binding (this is the path that prevents a phantom auto-stop).
        calendarService.stubEvents = []
        coordinator.testHook_forcePoll()
        await waitForPoll()
        XCTAssertNil(coordinator.testHook_autoStartedEventId,
                     "Binding must clear when recording stops outside coordinator's control")

        coordinator.stop()
    }
}
