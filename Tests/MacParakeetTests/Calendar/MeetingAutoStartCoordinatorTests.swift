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
    private var autoStopConfirmedCount = 0
    private var autoStopConfirmedGenerations: [Int] = []
    /// When true, the `onAutoStartConfirmed` stub mimics the real flow
    /// coordinator's `state_busy` rejection by clearing the binding —
    /// exercising the back-to-back retry path (#8).
    private var simulateAutoStartBusy = false
    private weak var coordinatorRef: MeetingAutoStartCoordinator?

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
        autoStopConfirmedCount = 0
        autoStopConfirmedGenerations = []
        simulateAutoStartBusy = false
        coordinatorRef = nil
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
            onAutoStartConfirmed: { [weak self] title in
                guard let self else { return nil }
                self.autoStartConfirmedCount += 1
                self.autoStartConfirmedTitles.append(title)
                if self.simulateAutoStartBusy {
                    // Mimic MeetingRecordingFlowCoordinator.startFromCalendar's
                    // synchronous state_busy path: clear the optimistic binding.
                    self.coordinatorRef?.clearAutoStartBinding()
                    return nil
                }
                return 1
            },
            onAutoStopConfirmed: { [weak self] generation in
                self?.autoStopConfirmedCount += 1
                self?.autoStopConfirmedGenerations.append(generation)
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

    // MARK: - Back-to-back retry (#8)

    func testStateBusyAutoStartClearsSuppressionForRetry() async {
        calendarService.stubPermissionStatus = .granted
        seedSettings(mode: .autoStart)

        let coordinator = makeCoordinator()
        coordinatorRef = coordinator
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
        coordinatorRef = coordinator
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

    // MARK: - Owned-event merge for reliable auto-stop (#2)

    func testMergeReinjectsOwnedEventWhenDroppedFromFetch() {
        // EventKit stops returning the event once `now` passes its endTime, so
        // a still-active owned recording must be re-injected for the auto-stop
        // window to remain evaluable.
        let owned = event(id: "owned", startsIn: -1800)
        let merged = MeetingAutoStartCoordinator.mergingOwnedEvent(
            into: [],
            owned: owned,
            activeRecording: true
        )
        XCTAssertEqual(merged.map(\.id), ["owned"])
    }

    func testMergeDoesNotDuplicateWhenOwnedEventStillPresent() {
        let owned = event(id: "owned", startsIn: -600)
        let merged = MeetingAutoStartCoordinator.mergingOwnedEvent(
            into: [owned],
            owned: owned,
            activeRecording: true
        )
        XCTAssertEqual(merged.map(\.id), ["owned"], "Must not duplicate an event already in the fetch")
    }

    func testMergeNoOpWhenNotRecording() {
        let owned = event(id: "owned", startsIn: -600)
        let merged = MeetingAutoStartCoordinator.mergingOwnedEvent(
            into: [],
            owned: owned,
            activeRecording: false
        )
        XCTAssertTrue(merged.isEmpty, "No merge when there's no active recording to protect")
    }

    // MARK: - Auto-stop idempotency (#1 — privacy)

    func testAutoStopCompletionAfterExternalStopDoesNotConfirm() async {
        // The privacy regression: a calendar auto-stop countdown was up,
        // the user manually stopped the recording during the 30s window, and
        // when the countdown completed the old code blindly toggled — which,
        // with no recording in flight, *started* a brand-new one. The fix:
        // the completion re-verifies ownership (cleared by the self-heal) and
        // routes through an idempotent stop. Here we assert the completion is
        // a no-op once the binding is gone.
        calendarService.stubPermissionStatus = .granted
        seedSettings(mode: .autoStart)

        let coordinator = makeCoordinator()
        coordinator.start()
        await waitForPoll()

        recordingActiveStub = true
        coordinator.testHook_simulateAutoStartConfirmed(eventId: "evt-1")
        XCTAssertEqual(coordinator.testHook_autoStartedEventId, "evt-1")

        // User stops the recording themselves; the next poll self-heals the
        // binding (and dismisses any live auto-stop toast).
        recordingActiveStub = false
        calendarService.stubEvents = []
        coordinator.testHook_forcePoll()
        await waitForPoll()
        XCTAssertNil(coordinator.testHook_autoStartedEventId)

        // The auto-stop countdown completes *after* the external stop.
        let event = CalendarEvent(
            id: "evt-1",
            title: "Wrap",
            startTime: Date().addingTimeInterval(-1800),
            endTime: Date().addingTimeInterval(5)
        )
        coordinator.handleAutoStopOutcome(.completed, for: event)
        XCTAssertEqual(autoStopConfirmedCount, 0,
                       "Auto-stop completion after an external stop must NOT confirm — otherwise the idempotent stop could hit a replacement recording, and the old toggle would have *started* one")

        coordinator.stop()
    }

    func testAutoStopCompletionWhileOwnedAndActiveConfirms() async {
        // Guard against the ownership recheck being too aggressive: the happy
        // path (binding still owns the active recording) must still stop.
        calendarService.stubPermissionStatus = .granted
        seedSettings(mode: .autoStart)

        let coordinator = makeCoordinator()
        coordinator.start()
        await waitForPoll()

        recordingActiveStub = true
        coordinator.testHook_simulateAutoStartConfirmed(eventId: "evt-1")

        let event = CalendarEvent(
            id: "evt-1",
            title: "Wrap",
            startTime: Date().addingTimeInterval(-1800),
            endTime: Date().addingTimeInterval(5)
        )
        coordinator.handleAutoStopOutcome(.completed, for: event)
        XCTAssertEqual(autoStopConfirmedCount, 1,
                       "An owned, still-active recording must auto-stop on completion")
        XCTAssertEqual(autoStopConfirmedGenerations, [1],
                       "Auto-stop must target the recording generation returned by calendar auto-start")

        coordinator.stop()
    }

    func testAutoStopCompletionIgnoredAfterAutoStopDisabled() async {
        calendarService.stubPermissionStatus = .granted
        seedSettings(mode: .autoStart)

        let coordinator = makeCoordinator()
        coordinator.start()
        await waitForPoll()

        recordingActiveStub = true
        coordinator.testHook_simulateAutoStartConfirmed(eventId: "evt-1")
        settingsViewModel.calendarAutoStopEnabled = false

        let event = CalendarEvent(
            id: "evt-1",
            title: "Wrap",
            startTime: Date().addingTimeInterval(-1800),
            endTime: Date().addingTimeInterval(5)
        )
        coordinator.handleAutoStopOutcome(.completed, for: event)

        XCTAssertEqual(autoStopConfirmedCount, 0,
                       "A countdown that completes after calendar auto-stop is disabled must not stop recording")

        coordinator.stop()
    }

    func testKeepRecordingDoesNotLeaveFastPollingStuck() async {
        calendarService.stubPermissionStatus = .granted
        seedSettings(mode: .autoStart)

        let coordinator = makeCoordinator()
        coordinator.start()
        await waitForPoll()

        recordingActiveStub = true
        let event = CalendarEvent(
            id: "evt-1",
            title: "Wrap",
            startTime: Date().addingTimeInterval(-1800),
            endTime: Date().addingTimeInterval(5)
        )
        coordinator.handleAutoStartOutcome(.completed, for: event)
        coordinator.handleAutoStopOutcome(.userDismissed, for: event)

        calendarService.stubEvents = []
        coordinator.testHook_forcePoll()
        await waitForPoll()

        XCTAssertEqual(coordinator.testHook_pollingInterval, 60,
                       "After Keep Recording, dismissed auto-stop should not force 5s polling forever")

        coordinator.stop()
    }
}
