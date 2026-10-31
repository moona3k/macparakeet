import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class MeetingActivityDetectionCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: SettingsViewModel!
    private var audio: PromptAudioCollector!
    private var shown: [MeetingPromptCandidate] = []
    private var callbacks: [@MainActor (MeetingActivityPromptOutcome) -> Void] = []
    private var closeCount = 0
    private var starts = 0
    private var recording = false
    private var meetingBusy = false
    private var nativePIDs: [String: Set<Int32>] = ["us.zoom.xos": [7]]
    private var recordingAvailable = true
    private var dictation = false
    private var onboarding = false
    private var quitting = false
    private var rejectStart = false
    private var rejectionIsBusy = true
    private var beginCaptureSynchronously = false
    private var markFlowBusyOnStart = false
    private var coordinator: MeetingActivityDetectionCoordinator?
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private var clockNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: makeIsolatedDefaultsSuite("com.macparakeet.tests.meeting-prompts."))!
        defaults.set("prompt", forKey: MeetingActivityDetectionPreferences.modeKey)
        settings = SettingsViewModel(defaults: defaults)
        audio = PromptAudioCollector()
    }

    override func tearDown() {
        coordinator?.stop()
        coordinator = nil
        settings = nil
        audio = nil
        defaults = nil
        super.tearDown()
    }

    private func makeCoordinator(
        featureEnabled: Bool = true,
        meetingURLProvider: @escaping @Sendable () async -> BrowserMeetingObservation = { BrowserMeetingObservation() }
    ) -> MeetingActivityDetectionCoordinator {
        let coordinator = MeetingActivityDetectionCoordinator(
            settingsViewModel: settings,
            audioCollector: audio,
            meetingURLProvider: meetingURLProvider,
            isRecordingActive: { [unowned self] in recording },
            isMeetingFlowBusy: { [unowned self] in meetingBusy || recording },
            runningNativeProcessIDsProvider: { [unowned self] in nativePIDs },
            isDictationActive: { [unowned self] in dictation },
            isStartSuppressed: { [unowned self] in onboarding || quitting },
            onRecordingConfirmed: { [unowned self] in
                starts += 1
                if rejectStart {
                    if rejectionIsBusy { meetingBusy = true }
                    return nil
                }
                if markFlowBusyOnStart { meetingBusy = true }
                if beginCaptureSynchronously {
                    recording = true
                    meetingBusy = true
                    self.coordinator?.recordingDidBegin()
                }
                return 1
            },
            showPrompt: { [unowned self] candidate, callback in
                shown.append(candidate)
                callbacks.append(callback)
            },
            closePrompt: { [unowned self] in closeCount += 1 },
            setRecordingAvailable: { [unowned self] in recordingAvailable = $0 },
            featureEnabled: featureEnabled,
            policy: MeetingActivityPromptPolicy(candidateDwellSeconds: 3, sessionEndGrace: 30),
            pollInterval: 0,
            nowProvider: { [unowned self] in clockNow }
        )
        self.coordinator = coordinator
        coordinator.start()
        return coordinator
    }

    private func tick(_ seconds: TimeInterval, _ coordinator: MeetingActivityDetectionCoordinator) async {
        // Drain initial/start-button work at the current clock value before
        // advancing time. Test discovery or unrelated test duration cannot
        // affect the policy's firstSeen timestamp.
        await coordinator.testHook_waitForScheduledEvaluation()
        clockNow = base.addingTimeInterval(seconds)
        await coordinator.testHook_evaluate(now: clockNow)
    }

    func testOffAndFeatureDisabledDoNotStartCollectors() {
        let disabled = makeCoordinator(featureEnabled: false)
        XCTAssertFalse(disabled.testHook_isCollecting)
        settings.meetingActivityDetectionMode = .off
        let off = makeCoordinator()
        XCTAssertFalse(off.testHook_isCollecting)
        XCTAssertEqual(audio.startCount, 0)
    }

    func testStableSnapshotPromptsAfterPeriodicDwellAndStaysVisible() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(1, coordinator)
        XCTAssertTrue(shown.isEmpty)
        await tick(4, coordinator)
        XCTAssertEqual(shown.count, 1)
        await tick(5, coordinator)
        XCTAssertNotNil(coordinator.testHook_presentedID)
        XCTAssertEqual(closeCount, 0)
    }

    func testDeclineSuppressesSameCallBeyondThirtyMinutes() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        (try XCTUnwrap(callbacks.first))(.declined)
        await tick(1900, coordinator)
        XCTAssertEqual(shown.count, 1)
        audio.value = ProcessAudioSnapshot(processes: [])
        await tick(1901, coordinator)
        await tick(1932, coordinator)
        audio.setZoom()
        await tick(1933, coordinator)
        await tick(1937, coordinator)
        XCTAssertEqual(shown.count, 2)
    }

    func testStaleRecordButtonCannotStartEndedCall() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        let callback = try XCTUnwrap(callbacks.first)
        audio.value = ProcessAudioSnapshot(processes: [])
        callback(.accepted)
        await tick(5, coordinator)
        XCTAssertEqual(starts, 0)
        XCTAssertNil(coordinator.testHook_pendingRecordID)
    }

    func testClickDuringDictationWaitsAndStartsSameCallAfterward() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        dictation = true
        (try XCTUnwrap(callbacks.first))(.accepted)
        await tick(5, coordinator)
        XCTAssertEqual(starts, 0)
        XCTAssertNotNil(coordinator.testHook_pendingRecordID)
        dictation = false
        await tick(6, coordinator)
        XCTAssertEqual(starts, 1)
        XCTAssertNil(coordinator.testHook_pendingRecordID)
    }

    func testRejectedStartRetriesAndStopInvalidatesOldCallbacks() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        rejectStart = true
        (try XCTUnwrap(callbacks.first))(.accepted)
        await tick(5, coordinator)
        XCTAssertNotNil(coordinator.testHook_pendingRecordID)
        rejectStart = false
        meetingBusy = false
        await tick(6, coordinator)
        XCTAssertNil(coordinator.testHook_pendingRecordID)
        let successfulStarts = starts
        coordinator.stop()
        (try XCTUnwrap(callbacks.first))(.accepted)
        await tick(7, coordinator)
        XCTAssertEqual(starts, successfulStarts)
        XCTAssertEqual(audio.stopCount, 1)
    }

    func testMutedMeetRequiresFreshInCallControlsAndRejectsStaleClickAfterLeaving() async throws {
        let room = URL(string: "https://meet.google.com/abc-defg-hij")!
        let stub = BrowserObservationStub(
            BrowserMeetingObservation(
                urls: ["com.google.Chrome": [room]], inCallURLs: ["com.google.Chrome": [room]]
            ))
        let coordinator = makeCoordinator(meetingURLProvider: { await stub.snapshot() })
        await tick(4, coordinator)
        XCTAssertEqual(shown.first?.displayName, "Google Meet")
        let callback = try XCTUnwrap(callbacks.first)
        await stub.set(BrowserMeetingObservation(urls: ["com.google.Chrome": [room]]))
        callback(.accepted)
        await tick(5, coordinator)
        XCTAssertEqual(starts, 0)
        XCTAssertNil(coordinator.testHook_pendingRecordID)
    }

    func testMicPreviewPreJoinAndSwitchingTabsDoNotPromptThenJoiningDoes() async throws {
        let room = URL(string: "https://meet.google.com/abc-defg-hij")!
        audio.value = ProcessAudioSnapshot(processes: [
            AudioProcessActivity(pid: 8, bundleID: "com.google.Chrome", isRunningInput: true, isRunningOutput: true)
        ])
        let stub = BrowserObservationStub(
            BrowserMeetingObservation(
                urls: ["com.google.Chrome": [room]], preJoinURLs: ["com.google.Chrome": [room]]
            ))
        let coordinator = makeCoordinator(meetingURLProvider: { await stub.snapshot() })
        await tick(4, coordinator)
        XCTAssertTrue(shown.isEmpty)
        await stub.set(BrowserMeetingObservation())
        await tick(8, coordinator)
        XCTAssertTrue(
            shown.isEmpty, "A hidden pre-join tab must not become a call just because its controls are unavailable")
        await stub.set(
            BrowserMeetingObservation(
                urls: ["com.google.Chrome": [room]], inCallURLs: ["com.google.Chrome": [room]]
            ))
        await tick(9, coordinator)
        await tick(13, coordinator)
        XCTAssertEqual(shown.count, 1)
    }

    func testStaleBrowserRoomCannotRecordWhenAnotherTabStillUsesMicrophone() async throws {
        let room = URL(string: "https://meet.google.com/abc-defg-hij")!
        audio.value = ProcessAudioSnapshot(processes: [
            AudioProcessActivity(pid: 8, bundleID: "com.google.Chrome", isRunningInput: true, isRunningOutput: true)
        ])
        let stub = BrowserObservationStub(browserObservation(room: room, inCall: true))
        let coordinator = makeCoordinator(meetingURLProvider: { await stub.snapshot() })
        await tick(4, coordinator)
        let callback = try XCTUnwrap(callbacks.first)
        // The browser still owns input, but no current document confirms the
        // original room. An old URL cannot authorize this click.
        await stub.set(browserObservation())
        callback(.accepted)
        await tick(5, coordinator)
        XCTAssertEqual(starts, 0)
        XCTAssertNil(coordinator.testHook_pendingRecordID)
        XCTAssertNotNil(coordinator.testHook_presentedID)
        XCTAssertFalse(recordingAvailable)
    }

    func testMutedBrowserDismissalSurvivesUnknownBackgroundTabUntilExplicitEnd() async throws {
        let room = URL(string: "https://meet.google.com/abc-defg-hij")!
        let stub = BrowserObservationStub(browserObservation(room: room, inCall: true))
        let coordinator = makeCoordinator(meetingURLProvider: { await stub.snapshot() })
        await tick(4, coordinator)
        (try XCTUnwrap(callbacks.first))(.declined)
        await stub.set(browserObservation())
        await tick(5, coordinator)
        await tick(80, coordinator)
        await stub.set(browserObservation(room: room, inCall: true))
        await tick(81, coordinator)
        await tick(85, coordinator)
        XCTAssertEqual(shown.count, 1, "Switching tabs for more than 30 seconds cannot repeat a dismissed reminder")
        await stub.set(browserObservation(room: room, preJoin: true))
        await tick(86, coordinator)
        await stub.set(browserObservation(room: room, inCall: true))
        await tick(87, coordinator)
        await tick(91, coordinator)
        XCTAssertEqual(shown.count, 2, "An explicit end followed by a new join starts a new call session")
    }

    func testJoiningDoesNotRetainPreJoinVetoAcrossDifferentQueries() async throws {
        let preJoinRoom = URL(string: "https://meet.google.com/abc-defg-hij?authuser=0")!
        let joinedRoom = URL(string: "https://meet.google.com/abc-defg-hij?authuser=1")!
        audio.value = ProcessAudioSnapshot(processes: [
            AudioProcessActivity(pid: 8, bundleID: "com.google.Chrome", isRunningInput: true, isRunningOutput: true)
        ])
        let stub = BrowserObservationStub(browserObservation(room: preJoinRoom, preJoin: true))
        let coordinator = makeCoordinator(meetingURLProvider: { await stub.snapshot() })
        await tick(4, coordinator)
        XCTAssertTrue(shown.isEmpty)
        await stub.set(browserObservation(room: joinedRoom, inCall: true))
        await tick(5, coordinator)
        // The next AX snapshot still knows the room, but its leave button is
        // temporarily unavailable. The old query variant must no longer veto it.
        await stub.set(browserObservation(room: joinedRoom))
        await tick(9, coordinator)
        XCTAssertEqual(shown.count, 1)
    }

    private func browserObservation(
        room: URL? = nil, inCall: Bool = false, preJoin: Bool = false
    ) -> BrowserMeetingObservation {
        var observation = BrowserMeetingObservation()
        observation.runningBrowserBundleIDs = ["com.google.Chrome"]
        if let room {
            observation.urls = ["com.google.Chrome": [room]]
            if inCall { observation.inCallURLs = observation.urls }
            if preJoin { observation.preJoinURLs = observation.urls }
        }
        return observation
    }

    func testZoomPreJoinThenJoinedMicrophonePrompts() async {
        await assertPreJoinThenJoinedMicrophone(
            room: URL(string: "https://us02web.zoom.us/j/12345678901?pwd=join")!,
            expectedName: "Zoom"
        )
    }

    func testTeamsPreJoinThenJoinedMicrophonePrompts() async {
        await assertPreJoinThenJoinedMicrophone(
            room: URL(string: "https://teams.microsoft.com/meet/1234567890123?p=join")!,
            expectedName: "Microsoft Teams"
        )
    }

    private func assertPreJoinThenJoinedMicrophone(room: URL, expectedName: String) async {
        audio.value = ProcessAudioSnapshot(processes: [
            AudioProcessActivity(pid: 8, bundleID: "com.google.Chrome", isRunningInput: true, isRunningOutput: true)
        ])
        let stub = BrowserObservationStub(browserObservation(room: room, preJoin: true))
        let coordinator = makeCoordinator(meetingURLProvider: { await stub.snapshot() })
        await tick(4, coordinator)
        XCTAssertTrue(shown.isEmpty)
        // Zoom and Teams do not use Meet's independent leave-control signal.
        // Once fresh pre-join controls disappear, the current room + microphone
        // evidence must be eligible for the normal dwell and recording offer.
        await stub.set(browserObservation(room: room))
        await tick(5, coordinator)
        await tick(9, coordinator)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.first?.displayName, expectedName)
    }

    func testSynchronousCaptureSuccessConsumesOnlyTheRequestedConcurrentRoom() async throws {
        let first = URL(string: "https://meet.google.com/abc-defg-hij")!
        let second = URL(string: "https://meet.google.com/klm-nopq-rst")!
        let rooms = ["com.google.Chrome": [first, second]]
        let observation = BrowserMeetingObservation(
            urls: rooms, inCallURLs: rooms, runningBrowserBundleIDs: ["com.google.Chrome"])
        let coordinator = makeCoordinator(meetingURLProvider: { observation })
        await tick(4, coordinator)
        beginCaptureSynchronously = true
        (try XCTUnwrap(callbacks.first))(.accepted)
        await tick(5, coordinator)
        XCTAssertEqual(starts, 1)
        recording = false
        meetingBusy = false
        await tick(6, coordinator)
        let expectedSecond = try XCTUnwrap(
            MeetingPromptCandidateResolver.browserCandidate(bundleID: "com.google.Chrome", meetingURL: second))
        XCTAssertEqual(shown.last?.id, expectedSecond.id)
    }

    func testCancelledActivityAttributionClearsBeforeBlockedAXReadAndManualCapture() async throws {
        let first = URL(string: "https://meet.google.com/abc-defg-hij")!
        let second = URL(string: "https://meet.google.com/klm-nopq-rst")!
        let rooms = ["com.google.Chrome": [first, second]]
        let observation = BrowserMeetingObservation(
            urls: rooms, inCallURLs: rooms, runningBrowserBundleIDs: ["com.google.Chrome"])
        let gate = BlockingBrowserObservation(observation)
        let coordinator = makeCoordinator(meetingURLProvider: { await gate.snapshot() })
        await tick(4, coordinator)
        let firstCandidate = try XCTUnwrap(shown.first)
        markFlowBusyOnStart = true
        (try XCTUnwrap(callbacks.first))(.accepted)
        await tick(5, coordinator)
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(meetingBusy)
        // A metadata read is still in flight when the activity attempt is
        // cancelled and another recording starts. Its old room attribution
        // must be cleared synchronously, without waiting for this AX result.
        await gate.blockNextRead()
        coordinator.recordingStateDidChange()
        await gate.waitUntilBlocked()
        meetingBusy = false
        coordinator.recordingFlowDidReturnToIdle()
        recording = true
        meetingBusy = true
        coordinator.recordingDidBegin()
        // With two possible rooms, this manual recording has no known room
        // identity. It must not consume the cancelled activity request's room.
        recording = false
        meetingBusy = false
        coordinator.recordingFlowDidReturnToIdle()
        await gate.releaseRead()
        await coordinator.testHook_waitForScheduledEvaluation()
        XCTAssertEqual(shown.last?.id, firstCandidate.id)
        XCTAssertEqual(starts, 1)
    }

    func testRejectedStartWithoutBusyOwnerReturnsOfferInsteadOfRetrying() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        rejectStart = true
        rejectionIsBusy = false
        (try XCTUnwrap(callbacks.first))(.accepted)
        await tick(5, coordinator)
        XCTAssertNil(coordinator.testHook_pendingRecordID)
        XCTAssertNotNil(coordinator.testHook_presentedID)
        let attemptedStarts = starts
        await tick(6, coordinator)
        XCTAssertEqual(starts, attemptedStarts)
    }

    func testDeferredRecordIsConsumedByAnotherRecordingEvenBetweenPolls() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        dictation = true
        (try XCTUnwrap(callbacks.first))(.accepted)
        await tick(5, coordinator)
        XCTAssertNotNil(coordinator.testHook_pendingRecordID)
        // Successful capture can begin and stop between metadata polls. The
        // synchronous event must cancel the deferred click without a poll latch.
        coordinator.recordingDidBegin()
        XCTAssertNil(coordinator.testHook_pendingRecordID)
        dictation = false
        await tick(6, coordinator)
        XCTAssertEqual(starts, 0)
        XCTAssertNil(coordinator.testHook_presentedID)
    }

    func testPermissionOrFailedStartBusyStateDefersButDoesNotConsumeOffer() async throws {
        audio.setZoom()
        meetingBusy = true
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        XCTAssertTrue(shown.isEmpty)
        meetingBusy = false
        await tick(5, coordinator)
        XCTAssertEqual(shown.count, 1)
        meetingBusy = true
        await tick(6, coordinator)
        XCTAssertNil(coordinator.testHook_presentedID)
        meetingBusy = false
        await tick(7, coordinator)
        XCTAssertEqual(shown.count, 2, "A cancelled or failed start must restore the same offer")
    }

    func testVisiblePromptRemainsDismissibleDuringBriefMissingEvidence() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        let callback = try XCTUnwrap(callbacks.first)
        audio.value = ProcessAudioSnapshot(processes: [])
        await tick(5, coordinator)
        XCTAssertNotNil(coordinator.testHook_presentedID)
        XCTAssertFalse(recordingAvailable)
        callback(.accepted)
        XCTAssertEqual(starts, 0)
        XCTAssertNotNil(coordinator.testHook_presentedID)
        callback(.declined)
        XCTAssertNil(coordinator.testHook_presentedID)
        audio.setZoom()
        await tick(6, coordinator)
        XCTAssertEqual(shown.count, 1)
    }

    func testBriefObservationLossRestoresRecordWithoutLosingVisibleOffer() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        audio.value = ProcessAudioSnapshot(processes: [])
        await tick(5, coordinator)
        XCTAssertFalse(recordingAvailable)
        audio.setZoom()
        await tick(6, coordinator)
        XCTAssertTrue(recordingAvailable)
        XCTAssertEqual(shown.count, 1)
    }

    func testAdditionalNativeInstanceAndPartialExitPreserveDismissal() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        (try XCTUnwrap(callbacks.first))(.declined)
        nativePIDs["us.zoom.xos"] = [7, 8]
        await tick(5, coordinator)
        nativePIDs["us.zoom.xos"] = [8]
        audio.setZoom(pid: 8)
        await tick(6, coordinator)
        await tick(10, coordinator)
        XCTAssertEqual(shown.count, 1, "A surviving instance keeps the same call session")
    }

    func testPartialNativeExitPreservesAcceptedDeferredStart() async throws {
        nativePIDs["us.zoom.xos"] = [7, 8]
        audio.setZoom(pid: 8)
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        dictation = true
        (try XCTUnwrap(callbacks.first))(.accepted)
        await tick(5, coordinator)
        nativePIDs["us.zoom.xos"] = [8]
        await tick(6, coordinator)
        XCTAssertNotNil(coordinator.testHook_pendingRecordID)
        dictation = false
        await tick(7, coordinator)
        XCTAssertEqual(starts, 1)
    }

    func testNativeAppRestartCancelsDeferredClickForPreviousProcess() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        dictation = true
        (try XCTUnwrap(callbacks.first))(.accepted)
        await tick(5, coordinator)
        XCTAssertNotNil(coordinator.testHook_pendingRecordID)
        nativePIDs["us.zoom.xos"] = [8]
        audio.setZoom(pid: 8)
        await tick(6, coordinator)
        XCTAssertNil(coordinator.testHook_pendingRecordID)
        dictation = false
        await tick(10, coordinator)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(shown.count, 2, "The replacement process needs a new recording decision")
    }

    func testNativeAppRestartResetsDismissalBeforeMicGraceExpires() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        (try XCTUnwrap(callbacks.first))(.declined)
        nativePIDs["us.zoom.xos"] = [8]
        audio.setZoom(pid: 8)
        await tick(5, coordinator)
        await tick(9, coordinator)
        XCTAssertEqual(shown.count, 2)
    }

    func testNativeAppExitAndRelaunchResetsDismissalBeforeMicGraceExpires() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        (try XCTUnwrap(callbacks.first))(.declined)
        nativePIDs = [:]
        audio.value = ProcessAudioSnapshot(processes: [])
        await tick(5, coordinator)
        nativePIDs = ["us.zoom.xos": [8]]
        audio.setZoom(pid: 8)
        await tick(6, coordinator)
        await tick(10, coordinator)
        XCTAssertEqual(shown.count, 2)
    }

    func testNativeMicGapWithinGraceDoesNotInventNewCallIdentity() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        (try XCTUnwrap(callbacks.first))(.declined)
        audio.value = ProcessAudioSnapshot(processes: [])
        await tick(5, coordinator)
        audio.setZoom()
        await tick(10, coordinator)
        await tick(14, coordinator)
        XCTAssertEqual(shown.count, 1, "Same-process mic gaps cannot distinguish mute from a separate call")
    }

    func testStablePollingSlowsDownButStillDetectsMutedJoinWithoutAudioEvent() async throws {
        let stub = BrowserObservationStub(browserObservation())
        let coordinator = makeCoordinator(meetingURLProvider: { await stub.snapshot() })
        await tick(0, coordinator)
        let initialCount = await stub.snapshotCount
        clockNow = base.addingTimeInterval(1)
        await coordinator.testHook_periodicTick()
        let skippedCount = await stub.snapshotCount
        XCTAssertEqual(skippedCount, initialCount)
        clockNow = base.addingTimeInterval(2)
        await coordinator.testHook_periodicTick()
        let nextCount = await stub.snapshotCount
        XCTAssertEqual(nextCount, initialCount + 1)
        await stub.set(browserObservation(room: URL(string: "https://meet.google.com/abc-defg-hij")!, inCall: true))
        clockNow = base.addingTimeInterval(4)
        await coordinator.testHook_periodicTick()
        clockNow = base.addingTimeInterval(5)
        await coordinator.testHook_periodicTick()
        clockNow = base.addingTimeInterval(7)
        await coordinator.testHook_periodicTick()
        XCTAssertEqual(shown.first?.displayName, "Google Meet")
    }

    func testBrowserPreJoinURLWithoutMicrophoneNeverPrompts() async throws {
        let room = URL(string: "https://meet.google.com/abc-defg-hij")!
        let coordinator = makeCoordinator(meetingURLProvider: {
            BrowserMeetingObservation(urls: ["com.google.Chrome": [room]])
        })
        await tick(4, coordinator)
        await tick(50, coordinator)
        XCTAssertTrue(shown.isEmpty)
    }

    func testPreviousCallCallbackCannotAcceptNewCallWithSameAppIdentity() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        let oldCallback = try XCTUnwrap(callbacks.first)
        audio.value = ProcessAudioSnapshot(processes: [])
        await tick(5, coordinator)
        await tick(36, coordinator)
        audio.setZoom()
        await tick(37, coordinator)
        await tick(41, coordinator)
        XCTAssertEqual(shown.count, 2)
        oldCallback(.accepted)
        await tick(42, coordinator)
        XCTAssertEqual(starts, 0)
        XCTAssertNotNil(coordinator.testHook_presentedID)
    }

    func testOnboardingDefersAnUnshownOffer() async {
        audio.setZoom()
        onboarding = true
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        XCTAssertTrue(shown.isEmpty)
        XCTAssertEqual(starts, 0)
        onboarding = false
        await tick(5, coordinator)
        XCTAssertEqual(shown.count, 1)
    }

    func testOnboardingDismissesVisiblePromptAndInvalidatesItsCallback() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        let callback = try XCTUnwrap(callbacks.first)
        onboarding = true
        await tick(5, coordinator)
        XCTAssertNil(coordinator.testHook_presentedID)
        XCTAssertEqual(closeCount, 1)
        callback(.accepted)
        onboarding = false
        await tick(6, coordinator)
        XCTAssertEqual(starts, 0)
        XCTAssertNil(coordinator.testHook_pendingRecordID)
        XCTAssertEqual(shown.count, 2)
    }

    func testClickWhileOnboardingIsVisibleCannotQueueAStartBeforeNextPoll() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        onboarding = true
        (try XCTUnwrap(callbacks.first))(.accepted)
        XCTAssertNil(coordinator.testHook_presentedID)
        XCTAssertNil(coordinator.testHook_pendingRecordID)
        onboarding = false
        await tick(5, coordinator)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(shown.count, 2)
    }

    func testAcceptedStartRechecksOnboardingAfterMetadataReadAndWaitsForItToClose() async throws {
        audio.setZoom()
        let gate = BlockingBrowserObservation(BrowserMeetingObservation())
        let coordinator = makeCoordinator(meetingURLProvider: { await gate.snapshot() })
        await tick(4, coordinator)
        await gate.blockNextRead()
        (try XCTUnwrap(callbacks.first))(.accepted)
        await gate.waitUntilBlocked()
        onboarding = true
        await gate.releaseRead()
        await coordinator.testHook_waitForScheduledEvaluation()
        XCTAssertEqual(starts, 0)
        XCTAssertNotNil(coordinator.testHook_pendingRecordID)
        onboarding = false
        await tick(5, coordinator)
        XCTAssertEqual(starts, 1)
        XCTAssertNil(coordinator.testHook_pendingRecordID)
    }

    func testQuitSuppressionDefersAnUnshownOfferUntilCancelled() async {
        audio.setZoom()
        quitting = true
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        XCTAssertTrue(shown.isEmpty)
        quitting = false
        await tick(5, coordinator)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(starts, 0)
    }

    func testQuitEntryDismissesOfferAndInvalidatesStaleClickWithoutConsumingIt() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        let callback = try XCTUnwrap(callbacks.first)
        coordinator.dismissPromptForQuit()
        quitting = true
        XCTAssertNil(coordinator.testHook_presentedID)
        callback(.accepted)
        await tick(5, coordinator)
        quitting = false
        await tick(6, coordinator)
        XCTAssertEqual(starts, 0)
        XCTAssertNil(coordinator.testHook_pendingRecordID)
        XCTAssertEqual(shown.count, 2)
    }

    func testCancelledQuitPreservesExistingCallDismissal() async throws {
        audio.setZoom()
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        (try XCTUnwrap(callbacks.first))(.declined)
        coordinator.dismissPromptForQuit()
        quitting = true
        await tick(5, coordinator)
        quitting = false
        await tick(6, coordinator)
        XCTAssertEqual(shown.count, 1)
    }

    func testAcceptedStartRechecksQuitStateAfterMetadataRead() async throws {
        audio.setZoom()
        let gate = BlockingBrowserObservation(BrowserMeetingObservation())
        let coordinator = makeCoordinator(meetingURLProvider: { await gate.snapshot() })
        await tick(4, coordinator)
        await gate.blockNextRead()
        (try XCTUnwrap(callbacks.first))(.accepted)
        await gate.waitUntilBlocked()
        quitting = true
        await gate.releaseRead()
        await coordinator.testHook_waitForScheduledEvaluation()
        XCTAssertEqual(starts, 0)
        XCTAssertNotNil(coordinator.testHook_pendingRecordID)
        quitting = false
        await tick(5, coordinator)
        XCTAssertEqual(starts, 1)
    }

    func testApprovedTerminationInvalidatesDeferredStartAndInFlightMetadataRead() async throws {
        audio.setZoom()
        let gate = BlockingBrowserObservation(BrowserMeetingObservation())
        let coordinator = makeCoordinator(meetingURLProvider: { await gate.snapshot() })
        await tick(4, coordinator)
        let callback = try XCTUnwrap(callbacks.first)
        await gate.blockNextRead()
        callback(.accepted)
        await gate.waitUntilBlocked()
        quitting = true
        coordinator.stop()
        await gate.releaseRead()
        quitting = false
        callback(.accepted)
        await tick(5, coordinator)
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(coordinator.testHook_isCollecting)
        XCTAssertNil(coordinator.testHook_pendingRecordID)
        XCTAssertNil(coordinator.testHook_presentedID)
    }

    func testBusyDictationDefersAnUnshownOffer() async throws {
        audio.setZoom()
        dictation = true
        let coordinator = makeCoordinator()
        await tick(4, coordinator)
        XCTAssertTrue(shown.isEmpty)
        dictation = false
        await tick(5, coordinator)
        XCTAssertEqual(shown.count, 1)
    }
}

private final class PromptAudioCollector: AudioProcessActivityCollecting {
    var value = ProcessAudioSnapshot(processes: [])
    var startCount = 0
    var stopCount = 0
    func start(handler: @escaping @Sendable (ProcessAudioSnapshot) -> Void) { startCount += 1 }
    func stop() { stopCount += 1 }
    func snapshot() -> ProcessAudioSnapshot { value }
    func setZoom(pid: Int32 = 7) {
        value = ProcessAudioSnapshot(processes: [
            AudioProcessActivity(pid: pid, bundleID: "us.zoom.xos", isRunningInput: true, isRunningOutput: false)
        ])
    }
}

private actor BrowserObservationStub {
    var value: BrowserMeetingObservation
    var snapshotCount = 0
    init(_ value: BrowserMeetingObservation) { self.value = value }
    func snapshot() -> BrowserMeetingObservation { snapshotCount += 1; return value }
    func set(_ value: BrowserMeetingObservation) { self.value = value }
}

private actor BlockingBrowserObservation {
    private let value: BrowserMeetingObservation
    private var shouldBlock = false
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(_ value: BrowserMeetingObservation) { self.value = value }

    func blockNextRead() { shouldBlock = true }

    func snapshot() async -> BrowserMeetingObservation {
        if shouldBlock {
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return value
    }

    func waitUntilBlocked() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func releaseRead() {
        shouldBlock = false
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
