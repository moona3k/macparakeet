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
    private var autoStartConfirmedTitles: [String] = []
    /// When true, the `onAutoStartConfirmed` stub mimics the real flow
    /// coordinator's `state_busy` rejection by returning nil — exercising the
    /// back-to-back retry path (#8).
    private var simulateAutoStartBusy = false

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
        autoStartConfirmedTitles = []
        simulateAutoStartBusy = false
    }

    /// Seed `UserDefaults` *before* the SettingsViewModel is constructed
    /// so init reads the values rather than each property running its
    /// `didSet` side-effects (which include notification-auth requests
    /// that crash in the test bundle).
    private func seedSettings(
        mode: CalendarAutoStartMode = .off,
        reminderMinutes: Int = 5,
        triggerFilter: MeetingTriggerFilter = .withLink
    ) {
        defaults.set(mode.rawValue, forKey: CalendarAutoStartPreferences.modeKey)
        defaults.set(reminderMinutes, forKey: CalendarAutoStartPreferences.reminderMinutesKey)
        defaults.set(triggerFilter.rawValue, forKey: CalendarAutoStartPreferences.triggerFilterKey)
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
            onAutoStartConfirmed: { [weak self] title in
                guard let self else { return nil }
                self.autoStartConfirmedCount += 1
                self.autoStartConfirmedTitles.append(title)
                if self.simulateAutoStartBusy {
                    // Mimic MeetingRecordingFlowCoordinator.startFromCalendar's
                    // synchronous state_busy path: reject with nil.
                    return nil
                }
                return 1
            },
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

    func testSettingsChangeNotificationTriggersImmediateRePoll() async throws {
        // When `calendarEnabled` is gated off, `coordinator.start()` returns
        // before registering the settings observer or scheduling polling, so
        // the re-poll behavior under test cannot be exercised. Skip rather
        // than assert false negatives.
        try XCTSkipUnless(
            AppFeatures.calendarEnabled,
            "Calendar feature is gated off; coordinator.start() short-circuits"
        )

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

        // Skip the actual countdown — drive the outcome handler directly
        // with a unique per-run title. The shared `testHook_` helper
        // hardcodes "Test", which would let the title assertion pass
        // even if the implementation hardcoded the title instead of
        // forwarding `event.title`. The countdown UX itself is covered
        // by toast-controller tests; here we're testing the coordinator's
        // outcome plumbing only.
        let uniqueTitle = "Roadmap Sync \(UUID().uuidString.prefix(8))"
        let event = CalendarEvent(
            id: "evt-1",
            title: uniqueTitle,
            startTime: Date(),
            endTime: Date().addingTimeInterval(1800)
        )
        coordinator.handleAutoStartOutcome(.completed, for: event)
        XCTAssertEqual(autoStartConfirmedCount, 1,
                       "Recording start callback must fire on .completed outcome")
        // Title forwarding: the calendar event name is what the saved
        // recording will be titled, not the date-based default.
        XCTAssertEqual(autoStartConfirmedTitles, [uniqueTitle],
                       "Auto-start must forward the event title so the saved recording is named after the meeting")

        coordinator.stop()
    }

    func testAutoStartCompletionIgnoredAfterModeTurnsOff() {
        calendarService.stubPermissionStatus = .granted
        seedSettings(mode: .autoStart)

        let coordinator = makeCoordinator()
        let event = CalendarEvent(
            id: "evt-1",
            title: "Standup",
            startTime: Date(),
            endTime: Date().addingTimeInterval(1800)
        )
        coordinator.testHook_markCountdownShown(event)

        settingsViewModel.calendarAutoStartMode = .off
        coordinator.handleAutoStartOutcome(.completed, for: event)

        XCTAssertEqual(autoStartConfirmedCount, 0,
                       "A countdown that completes after calendar auto-start is disabled must not start recording")
        XCTAssertFalse(coordinator.testHook_isCountdownShown(event),
                       "Disabled-mode completion should not permanently suppress a later re-enable")

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

    // MARK: - Back-to-back retry (#8)

    func testStateBusyAutoStartClearsSuppressionForRetry() async {
        calendarService.stubPermissionStatus = .granted
        seedSettings(mode: .autoStart)

        let coordinator = makeCoordinator()
        simulateAutoStartBusy = true
        coordinator.start()
        await waitForPoll()

        let event = CalendarEvent(
            id: "B",
            title: "Back-to-back",
            startTime: Date(),
            endTime: Date().addingTimeInterval(1800)
        )
        coordinator.testHook_markCountdownShown(event)
        XCTAssertTrue(coordinator.testHook_isCountdownShown(event))

        // Completion attempts the start; the stub rejects it (state_busy) and
        // clears the binding synchronously → suppression must be dropped.
        coordinator.handleAutoStartOutcome(.completed, for: event)
        XCTAssertFalse(coordinator.testHook_isCountdownShown(event),
                       "A state_busy auto-start must clear suppression so a true back-to-back meeting can retry once the first recording ends")

        coordinator.stop()
    }

    func testSuccessfulAutoStartRetainsSuppression() async {
        calendarService.stubPermissionStatus = .granted
        seedSettings(mode: .autoStart)

        let coordinator = makeCoordinator()
        simulateAutoStartBusy = false  // success path
        coordinator.start()
        await waitForPoll()

        let event = CalendarEvent(
            id: "B",
            title: "Solo",
            startTime: Date(),
            endTime: Date().addingTimeInterval(1800)
        )
        coordinator.testHook_markCountdownShown(event)
        coordinator.handleAutoStartOutcome(.completed, for: event)
        XCTAssertTrue(coordinator.testHook_isCountdownShown(event),
                      "A successful auto-start must keep its suppression — no duplicate countdown")

        coordinator.stop()
    }

    // MARK: - Poll reentrancy (#3)

    func testConcurrentPollsDoNotInterleave() async {
        // Hold one poll inside its fetch, then issue a second. The reentrancy
        // guard must drop the second so it can't double-post a reminder.
        calendarService.stubPermissionStatus = .granted
        calendarService.stubEvents = [event(startsIn: 5 * 60)]
        seedSettings(mode: .notify, reminderMinutes: 5)

        let coordinator = makeCoordinator()
        calendarService.holdNextFetch = true

        coordinator.testHook_forcePoll()   // poll A enters and parks in fetch
        await waitForPoll()
        XCTAssertEqual(calendarService.fetchUpcomingEventsCallCount, 1,
                       "First poll should be mid-fetch")

        coordinator.testHook_forcePoll()   // poll B — should be coalesced
        await waitForPoll()
        XCTAssertTrue(coordinator.testHook_pollAgainRequested,
                      "The reentrant poll must register a coalesced re-run (proves it entered and hit the guard, not merely queued)")
        XCTAssertEqual(calendarService.fetchUpcomingEventsCallCount, 1,
                       "A reentrant poll must not run a second concurrent fetch")

        // Releasing A lets it finish and run exactly one coalesced re-poll.
        calendarService.releaseHeldFetch()
        await waitForPoll()
        XCTAssertFalse(coordinator.testHook_pollAgainRequested,
                       "Coalesced flag should be consumed by the re-run")
        XCTAssertEqual(calendarService.fetchUpcomingEventsCallCount, 2,
                       "The dropped poll must be honored once after the in-flight poll completes")

        coordinator.stop()
    }

}
