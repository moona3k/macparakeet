import XCTest
@testable import MacParakeetCore

final class MeetingActivityPromptPolicyTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private let call = MeetingPromptCandidate(
        id: "room:a", app: .browser, bundleID: "com.google.Chrome", displayName: "Google Meet")
    private let anotherCall = MeetingPromptCandidate(
        id: "room:b", app: .browser, bundleID: "com.google.Chrome", displayName: "Google Meet")

    func testDwellPromptsOnceAndStopsPeriodicRefreshWhenStable() {
        var policy = MeetingActivityPromptPolicy()
        XCTAssertNil(update(&policy, at: 0))
        XCTAssertTrue(policy.needsRefresh)
        XCTAssertNil(update(&policy, at: 2.9))
        XCTAssertEqual(update(&policy, at: 3), call)
        XCTAssertEqual(policy.currentPrompt, call)
        XCTAssertFalse(policy.needsRefresh)
        XCTAssertNil(update(&policy, at: 1800))
    }

    func testDismissalSurvivesLongCallAndTransientMute() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0)
        _ = update(&policy, at: 3)
        policy.dismiss(id: call.id)
        XCTAssertNil(update(&policy, at: 3600))
        XCTAssertNil(update(&policy, at: 3601, candidates: []))
        XCTAssertTrue(policy.needsRefresh)
        XCTAssertNil(policy.activeCandidate(id: call.id))
        XCTAssertNil(update(&policy, at: 3629))
        XCTAssertFalse(policy.needsRefresh)
        XCTAssertNil(policy.currentPrompt)
    }

    func testMicBlipsDoNotAccumulateIntoStableDwell() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0)
        _ = update(&policy, at: 1, candidates: [])
        XCTAssertNil(update(&policy, at: 5))
        XCTAssertNil(update(&policy, at: 7.9))
        XCTAssertEqual(update(&policy, at: 8), call)
    }

    func testEndGraceStartsWhenAbsenceIsObservedNotAtLastTimerTick() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0)
        _ = update(&policy, at: 3)
        policy.dismiss(id: call.id)
        // Stable calls have no polling timer; the last snapshot may be hours old.
        _ = update(&policy, at: 7200, candidates: [])
        XCTAssertNil(update(&policy, at: 7201))
        XCTAssertFalse(policy.needsRefresh)
        XCTAssertNil(update(&policy, at: 7204))
        XCTAssertNil(policy.currentPrompt)
    }

    func testNewSessionAfterSustainedEndCanPromptAgain() {
        var policy = MeetingActivityPromptPolicy(sessionEndGrace: 10)
        _ = update(&policy, at: 0)
        _ = update(&policy, at: 3)
        policy.dismiss(id: call.id)
        _ = update(&policy, at: 4, candidates: [])
        _ = update(&policy, at: 14, candidates: [])
        XCTAssertFalse(policy.needsRefresh)
        XCTAssertNil(update(&policy, at: 15))
        XCTAssertEqual(update(&policy, at: 18), call)
    }

    func testReturningAfterGraceWithoutIdleTicksCreatesNewSession() {
        var policy = MeetingActivityPromptPolicy(sessionEndGrace: 10)
        _ = update(&policy, at: 0)
        _ = update(&policy, at: 3)
        policy.dismiss(id: call.id)
        _ = update(&policy, at: 4, candidates: [])
        XCTAssertNil(update(&policy, at: 20))
        XCTAssertEqual(update(&policy, at: 23), call)
    }

    func testDifferentRoomPromptsWithoutWaitingForPreviousSessionGrace() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0)
        _ = update(&policy, at: 3)
        policy.dismiss(id: call.id)
        XCTAssertNil(update(&policy, at: 4, candidates: [anotherCall]))
        XCTAssertEqual(update(&policy, at: 7, candidates: [anotherCall]), anotherCall)
    }

    func testRecordingConsumesReminderAndSuppressesPromptAfterStop() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0)
        policy.recordingDidBegin()
        XCTAssertNil(update(&policy, at: 3, recording: true))
        XCTAssertNil(update(&policy, at: 300, recording: false))
        XCTAssertNil(policy.currentPrompt)
    }

    func testUnavailablePromptSurfaceDefersUntilAvailableWithoutLosingDwell() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0, canPrompt: false)
        XCTAssertNil(update(&policy, at: 3, canPrompt: false))
        XCTAssertEqual(update(&policy, at: 4), call)
    }

    func testShownPromptSurvivesTemporaryBusyState() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0)
        _ = update(&policy, at: 3)
        XCTAssertNil(update(&policy, at: 4, canPrompt: false))
        XCTAssertEqual(policy.currentPrompt, call)
        XCTAssertNil(update(&policy, at: 5))
        XCTAssertEqual(policy.currentPrompt, call)
    }

    func testStalePromptActionInvalidatedImmediatelyOnLostSignal() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0)
        _ = update(&policy, at: 3)
        XCTAssertEqual(policy.activeCandidate(id: call.id), call)
        _ = update(&policy, at: 4, candidates: [])
        XCTAssertEqual(policy.currentPrompt, call)
        XCTAssertNil(policy.activeCandidate(id: call.id))
        XCTAssertNil(update(&policy, at: 5))
        XCTAssertEqual(policy.currentPrompt, call)
        XCTAssertEqual(policy.activeCandidate(id: call.id), call)
    }

    func testConcurrentCallsHaveDeterministicOrderAndIndependentDismissals() {
        var policy = MeetingActivityPromptPolicy()
        let candidates = [anotherCall, call, call]
        _ = update(&policy, at: 0, candidates: candidates)
        XCTAssertEqual(update(&policy, at: 3, candidates: candidates), call)
        XCTAssertNil(update(&policy, at: 4, candidates: candidates))
        policy.dismiss(id: call.id)
        XCTAssertEqual(update(&policy, at: 5, candidates: candidates), anotherCall)
    }

    func testBackgroundBrowserRetainsSuppressionWithoutRetainingActionAuthority() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0)
        _ = update(&policy, at: 3)
        policy.dismiss(id: call.id)
        _ = update(&policy, at: 4, candidates: [], preservedBrowsers: [call.bundleID])
        _ = update(&policy, at: 3600, candidates: [], preservedBrowsers: [call.bundleID])
        XCTAssertFalse(policy.needsRefresh)
        XCTAssertNil(policy.currentPrompt)
        XCTAssertNil(policy.activeCandidate(id: call.id))
        XCTAssertNil(update(&policy, at: 3601, preservedBrowsers: [call.bundleID]))
    }

    func testBrowserQuitExpiresUncertainSuppression() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0)
        _ = update(&policy, at: 3)
        policy.dismiss(id: call.id)
        _ = update(&policy, at: 4, candidates: [], preservedBrowsers: [call.bundleID])
        _ = update(&policy, at: 100, candidates: [])
        XCTAssertFalse(policy.needsRefresh)
        XCTAssertNil(update(&policy, at: 101))
        XCTAssertEqual(update(&policy, at: 104), call)
    }

    func testExplicitRoomEndResetsPreservedSuppressionForRejoin() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0)
        _ = update(&policy, at: 3)
        policy.dismiss(id: call.id)
        _ = update(&policy, at: 4, candidates: [], preservedBrowsers: [call.bundleID])
        policy.resetSessions(for: [call.id])
        XCTAssertNil(policy.activeCandidate(id: call.id))
        XCTAssertNil(update(&policy, at: 5, preservedBrowsers: [call.bundleID]))
        XCTAssertEqual(update(&policy, at: 8, preservedBrowsers: [call.bundleID]), call)
    }

    func testUnknownBrowserStateDoesNotPreserveUnshownDwell() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0)
        _ = update(&policy, at: 1, candidates: [], preservedBrowsers: [call.bundleID])
        _ = update(&policy, at: 100, candidates: [], preservedBrowsers: [call.bundleID])
        XCTAssertNil(update(&policy, at: 101, preservedBrowsers: [call.bundleID]))
        XCTAssertEqual(update(&policy, at: 104, preservedBrowsers: [call.bundleID]), call)
    }

    func testRecordingBeginningWithVisiblePromptClearsConsumedOffer() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0)
        _ = update(&policy, at: 3)
        XCTAssertEqual(policy.currentPrompt, call)
        policy.recordingDidBegin()
        XCTAssertNil(update(&policy, at: 4, recording: true))
        XCTAssertNil(policy.currentPrompt)
        XCTAssertNil(update(&policy, at: 30))
    }

    func testVisiblePromptSurvivesMissingEvidenceUntilGraceExpires() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0)
        _ = update(&policy, at: 3)
        _ = update(&policy, at: 4, candidates: [])
        XCTAssertEqual(policy.currentPrompt, call)
        XCTAssertNil(policy.activeCandidate(id: call.id))
        _ = update(&policy, at: 33.9, candidates: [])
        XCTAssertEqual(policy.currentPrompt, call)
        _ = update(&policy, at: 34, candidates: [])
        XCTAssertNil(policy.currentPrompt)
    }

    func testRecordingConsumesOnlyItsKnownCandidateAmongConcurrentCalls() {
        var policy = MeetingActivityPromptPolicy()
        let candidates = [call, anotherCall]
        _ = update(&policy, at: 0, candidates: candidates)
        _ = update(&policy, at: 3, candidates: candidates)
        policy.recordingDidBegin(candidateID: call.id)
        XCTAssertNil(update(&policy, at: 4, candidates: candidates, recording: true))
        XCTAssertNil(policy.currentPrompt)
        XCTAssertEqual(update(&policy, at: 30, candidates: candidates), anotherCall)
    }

    func testAmbiguousManualRecordingDoesNotConsumeEveryConcurrentCall() {
        var policy = MeetingActivityPromptPolicy()
        let candidates = [call, anotherCall]
        _ = update(&policy, at: 0, candidates: candidates)
        policy.recordingDidBegin()
        XCTAssertNil(update(&policy, at: 3, candidates: candidates, recording: true))
        XCTAssertEqual(update(&policy, at: 4, candidates: candidates), call)
        policy.dismiss(id: call.id)
        XCTAssertEqual(update(&policy, at: 5, candidates: candidates), anotherCall)
    }

    func testCallAppearingDuringAnotherRecordingRemainsEligibleAfterStop() {
        var policy = MeetingActivityPromptPolicy()
        _ = update(&policy, at: 0)
        policy.recordingDidBegin()
        XCTAssertNil(update(&policy, at: 4, candidates: [call, anotherCall], recording: true))
        XCTAssertEqual(update(&policy, at: 8, candidates: [call, anotherCall]), anotherCall)
    }

    private func update(
        _ policy: inout MeetingActivityPromptPolicy,
        at seconds: TimeInterval,
        candidates: [MeetingPromptCandidate]? = nil,
        canPrompt: Bool = true,
        recording: Bool = false,
        preservedBrowsers: Set<String> = []
    ) -> MeetingPromptCandidate? {
        policy.update(
            candidates: candidates ?? [call], now: epoch.addingTimeInterval(seconds),
            canPrompt: canPrompt, isRecording: recording, preservedBrowserBundleIDs: preservedBrowsers
        )
    }
}
