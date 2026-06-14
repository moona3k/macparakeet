import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class MeetingAutoStopCoordinatorTests: XCTestCase {
    private typealias StopReason = MeetingAutoStopPolicy.StopReason

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: SettingsViewModel!
    private var recordingActive = true
    private var paused = false
    private var runningApps: Set<String> = ["us.zoom.xos"]
    private var levels = MeetingAudioLevels(microphone: 0.5, system: 0.5)
    private var shownReasons: [StopReason] = []
    private var closeCount = 0
    private var stoppedReasons: [StopReason] = []
    private var countdownCallbacks: [StopReason: (MeetingCountdownToastOutcome) -> Void] = [:]

    override func setUp() {
        super.setUp()
        let suite = "com.macparakeet.tests.auto-stop.\(UUID().uuidString)"
        suiteName = suite
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        Telemetry.configure(NoOpTelemetryService())
        settings = SettingsViewModel(defaults: defaults)
        settings.meetingAutoStopEnabled = true
        recordingActive = true
        paused = false
        runningApps = ["us.zoom.xos"]
        levels = MeetingAudioLevels(microphone: 0.5, system: 0.5)
        shownReasons = []
        closeCount = 0
        stoppedReasons = []
        countdownCallbacks = [:]
    }

    override func tearDown() {
        Telemetry.configure(NoOpTelemetryService())
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        settings = nil
        super.tearDown()
    }

    private func makeCoordinator(
        appQuitGrace: TimeInterval = 15,
        silenceGrace: TimeInterval = 240,
        isPausedProvider: (@MainActor () async -> Bool)? = nil,
        audioLevelsProvider: (@MainActor () async -> MeetingAudioLevels)? = nil,
        onAutoStopConfirmed: (@MainActor (StopReason) -> Bool)? = nil
    ) -> MeetingAutoStopCoordinator {
        MeetingAutoStopCoordinator(
            settingsViewModel: settings,
            isRecordingActive: { [weak self] in self?.recordingActive ?? false },
            isPaused: { [weak self] in
                if let isPausedProvider {
                    return await isPausedProvider()
                }
                return self?.paused ?? false
            },
            runningMeetingAppsProvider: { [weak self] in self?.runningApps ?? [] },
            audioLevelsProvider: { [weak self] in
                if let audioLevelsProvider {
                    return await audioLevelsProvider()
                }
                return self?.levels ?? MeetingAudioLevels()
            },
            onAutoStopConfirmed: { [weak self] reason in
                if let onAutoStopConfirmed {
                    return onAutoStopConfirmed(reason)
                }
                self?.stoppedReasons.append(reason)
                return true
            },
            showCountdown: { [weak self] reason, callback in
                self?.shownReasons.append(reason)
                self?.countdownCallbacks[reason] = callback
            },
            closeCountdown: { [weak self] in
                self?.closeCount += 1
            },
            featureEnabled: true,
            config: MeetingAutoStopPolicy.Config(
                appQuitEnabled: true,
                silenceEnabled: true,
                appQuitGraceSeconds: appQuitGrace,
                silenceGraceSeconds: silenceGrace
            ),
            pollInterval: 60
        )
    }

    private func waitForCountdownOutcome() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for predicate", file: file, line: line)
    }

    func testAppQuitGraceShowsCountdownAfterContinuousGrace() async {
        let now = Date()
        let coordinator = makeCoordinator(appQuitGrace: 15)
        coordinator.recordingDidStart(now: now)
        runningApps = []

        await coordinator.testHook_recordAppTerminated(bundleID: "us.zoom.xos", now: now)
        XCTAssertTrue(shownReasons.isEmpty)

        await coordinator.testHook_forceEvaluate(now: now.addingTimeInterval(14.9))
        XCTAssertTrue(shownReasons.isEmpty)

        await coordinator.testHook_forceEvaluate(now: now.addingTimeInterval(15))
        XCTAssertEqual(shownReasons, [.meetingAppClosed(bundleID: "us.zoom.xos")])

        coordinator.stop()
    }

    func testGraceReversalCancelsAppQuitSignal() async {
        let now = Date()
        let coordinator = makeCoordinator(appQuitGrace: 15)
        coordinator.recordingDidStart(now: now)
        runningApps = []

        await coordinator.testHook_recordAppTerminated(bundleID: "us.zoom.xos", now: now)
        await coordinator.testHook_forceEvaluate(now: now.addingTimeInterval(10))
        runningApps = ["us.zoom.xos"]
        await coordinator.testHook_forceEvaluate(now: now.addingTimeInterval(11))
        runningApps = []
        await coordinator.testHook_recordAppTerminated(bundleID: "us.zoom.xos", now: now.addingTimeInterval(12))

        await coordinator.testHook_forceEvaluate(now: now.addingTimeInterval(26.9))
        XCTAssertTrue(shownReasons.isEmpty)

        await coordinator.testHook_forceEvaluate(now: now.addingTimeInterval(27))
        XCTAssertEqual(shownReasons, [.meetingAppClosed(bundleID: "us.zoom.xos")])

        coordinator.stop()
    }

    func testVetoSuppressesSameReasonForSession() async {
        let now = Date()
        let reason = StopReason.meetingAppClosed(bundleID: "us.zoom.xos")
        let coordinator = makeCoordinator(appQuitGrace: 0)
        coordinator.recordingDidStart(now: now)
        runningApps = []

        await coordinator.testHook_recordAppTerminated(bundleID: "us.zoom.xos", now: now)
        XCTAssertEqual(shownReasons, [reason])

        countdownCallbacks[reason]?(.userDismissed)
        XCTAssertEqual(coordinator.testHook_vetoedReasons, [reason])

        await coordinator.testHook_forceEvaluate(now: now.addingTimeInterval(60))
        XCTAssertEqual(shownReasons, [reason])

        coordinator.stop()
    }

    func testToggleOffMidCountdownTearsDownSignals() async {
        let now = Date()
        let coordinator = makeCoordinator(appQuitGrace: 0)
        coordinator.start()
        runningApps = []

        await coordinator.testHook_recordAppTerminated(bundleID: "us.zoom.xos", now: now)
        XCTAssertNotNil(coordinator.testHook_countdownReason)
        XCTAssertTrue(coordinator.testHook_isSignalObservationActive)

        settings.meetingAutoStopEnabled = false
        await waitForCountdownOutcome()

        XCTAssertNil(coordinator.testHook_countdownReason)
        XCTAssertFalse(coordinator.testHook_isSignalObservationActive)
        XCTAssertGreaterThan(closeCount, 0)

        coordinator.stop()
    }

    func testCompletedCountdownDoesNotStopPausedRecording() async {
        let now = Date()
        let reason = StopReason.meetingAppClosed(bundleID: "us.zoom.xos")
        let coordinator = makeCoordinator(appQuitGrace: 0)
        coordinator.recordingDidStart(now: now)
        runningApps = []

        await coordinator.testHook_recordAppTerminated(bundleID: "us.zoom.xos", now: now)
        paused = true
        countdownCallbacks[reason]?(.completed)
        await waitForCountdownOutcome()

        XCTAssertTrue(stoppedReasons.isEmpty)

        coordinator.stop()
    }

    func testCompletedCountdownRevalidatesSignalBeforeStopping() async {
        let now = Date()
        let reason = StopReason.meetingAppClosed(bundleID: "us.zoom.xos")
        let coordinator = makeCoordinator(appQuitGrace: 0)
        coordinator.recordingDidStart(now: now)
        runningApps = []

        await coordinator.testHook_recordAppTerminated(bundleID: "us.zoom.xos", now: now)
        XCTAssertEqual(shownReasons, [reason])

        runningApps = ["us.zoom.xos"]
        countdownCallbacks[reason]?(.completed)
        await waitForCountdownOutcome()

        XCTAssertTrue(stoppedReasons.isEmpty)

        coordinator.stop()
    }

    func testCompletedCountdownDoesNotStopAfterRecordingBecomesInactive() async {
        let now = Date()
        let reason = StopReason.meetingAppClosed(bundleID: "us.zoom.xos")
        let coordinator = makeCoordinator(appQuitGrace: 0)
        coordinator.recordingDidStart(now: now)
        runningApps = []

        await coordinator.testHook_recordAppTerminated(bundleID: "us.zoom.xos", now: now)
        recordingActive = false
        countdownCallbacks[reason]?(.completed)
        await waitForCountdownOutcome()

        XCTAssertTrue(stoppedReasons.isEmpty)

        coordinator.stop()
    }

    func testVetoedClosedAppDoesNotHideLaterClosedApp() async {
        let now = Date()
        let faceTime = StopReason.meetingAppClosed(bundleID: "com.apple.FaceTime")
        let zoom = StopReason.meetingAppClosed(bundleID: "us.zoom.xos")
        let coordinator = makeCoordinator(appQuitGrace: 0)
        runningApps = ["com.apple.FaceTime", "us.zoom.xos"]
        coordinator.recordingDidStart(now: now)

        runningApps = []
        await coordinator.testHook_recordAppTerminated(bundleID: "com.apple.FaceTime", now: now)
        XCTAssertEqual(shownReasons, [faceTime])

        countdownCallbacks[faceTime]?(.userDismissed)
        await coordinator.testHook_forceEvaluate(now: now.addingTimeInterval(1))

        XCTAssertEqual(shownReasons, [faceTime, zoom])

        coordinator.stop()
    }

    func testSuspendedCountdownCompletionDoesNotStopAfterToggleOff() async {
        let now = Date()
        let reason = StopReason.meetingAppClosed(bundleID: "us.zoom.xos")
        var suspendPause = false
        var isPausedCallCount = 0
        var releasePause = false
        let coordinator = makeCoordinator(
            appQuitGrace: 0,
            isPausedProvider: {
                if suspendPause {
                    isPausedCallCount += 1
                    while !releasePause {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                return false
            }
        )
        coordinator.recordingDidStart(now: now)
        runningApps = []

        await coordinator.testHook_recordAppTerminated(bundleID: "us.zoom.xos", now: now)
        XCTAssertEqual(shownReasons, [reason])

        suspendPause = true
        countdownCallbacks[reason]?(.completed)
        await waitUntil { isPausedCallCount > 0 }

        settings.meetingAutoStopEnabled = false
        await waitForCountdownOutcome()
        releasePause = true
        await waitForCountdownOutcome()

        XCTAssertTrue(stoppedReasons.isEmpty)

        coordinator.stop()
    }

    func testCompletedCountdownStopsExactlyOnceThroughFlowClosure() async {
        let now = Date()
        let reason = StopReason.meetingAppClosed(bundleID: "us.zoom.xos")
        let coordinator = makeCoordinator(appQuitGrace: 0)
        coordinator.recordingDidStart(now: now)
        runningApps = []

        await coordinator.testHook_recordAppTerminated(bundleID: "us.zoom.xos", now: now)
        countdownCallbacks[reason]?(.completed)
        countdownCallbacks[reason]?(.completed)
        await waitForCountdownOutcome()

        XCTAssertEqual(stoppedReasons, [reason])

        coordinator.stop()
    }

    func testCompletedCountdownCleansUpWhenStopFlowIsAlreadyInactive() async {
        let now = Date()
        let reason = StopReason.meetingAppClosed(bundleID: "us.zoom.xos")
        var stopAttemptCount = 0
        let coordinator = makeCoordinator(
            appQuitGrace: 0,
            onAutoStopConfirmed: { [weak self] _ in
                stopAttemptCount += 1
                self?.recordingActive = false
                return false
            }
        )
        coordinator.recordingDidStart(now: now)
        runningApps = []

        await coordinator.testHook_recordAppTerminated(bundleID: "us.zoom.xos", now: now)
        countdownCallbacks[reason]?(.completed)
        await waitForCountdownOutcome()

        XCTAssertEqual(stopAttemptCount, 1)
        XCTAssertFalse(coordinator.testHook_isSignalObservationActive)
        XCTAssertNil(coordinator.testHook_context)

        coordinator.stop()
    }

    func testRecordingDidEndClosesCountdownAndTearsDownSignals() async {
        let now = Date()
        let coordinator = makeCoordinator(appQuitGrace: 0)
        coordinator.recordingDidStart(now: now)
        runningApps = []

        await coordinator.testHook_recordAppTerminated(bundleID: "us.zoom.xos", now: now)
        XCTAssertNotNil(coordinator.testHook_countdownReason)
        XCTAssertTrue(coordinator.testHook_isSignalObservationActive)

        coordinator.recordingDidEnd()

        XCTAssertNil(coordinator.testHook_countdownReason)
        XCTAssertFalse(coordinator.testHook_isSignalObservationActive)
        XCTAssertGreaterThan(closeCount, 0)

        coordinator.stop()
    }

    func testSuspendedEvaluationDoesNotShowCountdownAfterRecordingEnds() async {
        let now = Date()
        var suspendAudioLevels = false
        var audioLevelsCallCount = 0
        var releaseAudioLevels = false
        let coordinator = makeCoordinator(
            appQuitGrace: 0,
            audioLevelsProvider: {
                if suspendAudioLevels {
                    audioLevelsCallCount += 1
                    while !releaseAudioLevels {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                return MeetingAudioLevels(microphone: 0.5, system: 0.5)
            }
        )
        coordinator.recordingDidStart(now: now)
        await waitForCountdownOutcome()
        runningApps = []
        suspendAudioLevels = true

        let evaluation = Task { @MainActor in
            await coordinator.testHook_recordAppTerminated(bundleID: "us.zoom.xos", now: now)
        }
        await waitUntil { audioLevelsCallCount > 0 }

        coordinator.recordingDidEnd()
        releaseAudioLevels = true
        await evaluation.value

        XCTAssertTrue(shownReasons.isEmpty)

        coordinator.stop()
    }

    func testSustainedSilenceShowsCountdownAtGrace() async {
        let now = Date()
        let coordinator = makeCoordinator(silenceGrace: 240)
        runningApps = []
        coordinator.recordingDidStart(now: now)
        levels = MeetingAudioLevels(microphone: 0, system: 0)

        await coordinator.testHook_forceEvaluate(now: now)
        await coordinator.testHook_forceEvaluate(now: now.addingTimeInterval(239.9))
        XCTAssertTrue(shownReasons.isEmpty)

        await coordinator.testHook_forceEvaluate(now: now.addingTimeInterval(240))
        XCTAssertEqual(shownReasons, [.prolongedSilence])

        coordinator.stop()
    }

    func testSignalReversalClosesVisibleCountdown() async {
        let now = Date()
        let coordinator = makeCoordinator(silenceGrace: 1)
        runningApps = []
        coordinator.recordingDidStart(now: now)
        levels = MeetingAudioLevels(microphone: 0, system: 0)

        await coordinator.testHook_forceEvaluate(now: now)
        await coordinator.testHook_forceEvaluate(now: now.addingTimeInterval(1))
        XCTAssertEqual(shownReasons, [.prolongedSilence])

        levels = MeetingAudioLevels(microphone: 0.5, system: 0)
        await coordinator.testHook_forceEvaluate(now: now.addingTimeInterval(2))

        XCTAssertNil(coordinator.testHook_countdownReason)
        XCTAssertGreaterThan(closeCount, 0)

        coordinator.stop()
    }
}
