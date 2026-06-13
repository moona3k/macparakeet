import XCTest
@testable import MacParakeetCore

/// Phase 4.5 — universal launch-time VAD model availability
/// (`plans/completed/2026-05-meeting-vad-guided-live-chunking.md` §6).
///
/// These cover the flag-and-cache gate that `AppDelegate.scheduleDeferredSpeechPreWarm`
/// rides on every launch, without driving the deferred launch timer. The prep
/// must be a no-op when the feature is off or the model is already cached, must
/// download when enabled + uncached, and must never throw — a download failure
/// is swallowed so the meeting path falls back to fixed chunking.
final class MeetingVADLaunchPrepTests: XCTestCase {
    private enum FakeVADPrepError: Error { case boom }

    func testReturnsDisabledAndSkipsPrepWhenFeatureOff() async {
        let preparer = MockMeetingVADModelPreparer()
        await preparer.configureCached(false)

        let outcome = await MeetingVADLaunchPrep.run(featureEnabled: false, preparer: preparer)

        XCTAssertEqual(outcome, .disabled)
        let called = await preparer.prepareModelCalled
        XCTAssertFalse(called, "feature-off launch must not fetch the VAD model")
    }

    func testReturnsAlreadyCachedAndSkipsPrepWhenModelReady() async {
        let preparer = MockMeetingVADModelPreparer()
        await preparer.configureCached(true)

        let outcome = await MeetingVADLaunchPrep.run(featureEnabled: true, preparer: preparer)

        XCTAssertEqual(outcome, .alreadyCached)
        let called = await preparer.prepareModelCalled
        XCTAssertFalse(called, "already-cached model must not be re-fetched")
    }

    func testPreparesWhenEnabledAndUncached() async {
        let preparer = MockMeetingVADModelPreparer()
        await preparer.configureCached(false)

        let outcome = await MeetingVADLaunchPrep.run(featureEnabled: true, preparer: preparer)

        XCTAssertEqual(outcome, .prepared)
        let called = await preparer.prepareModelCalled
        XCTAssertTrue(called, "enabled + uncached must fetch the VAD model")
        let ready = await preparer.isModelReady()
        XCTAssertTrue(ready, "a successful prep must leave the model cached")
    }

    func testSwallowsFailureAndReturnsFailed() async {
        let preparer = MockMeetingVADModelPreparer()
        await preparer.configureCached(false)
        await preparer.configurePrepareModel(error: FakeVADPrepError.boom)

        // Must not throw out of `run` — VAD prep is optional and never a launch
        // blocker.
        let outcome = await MeetingVADLaunchPrep.run(featureEnabled: true, preparer: preparer)

        XCTAssertEqual(outcome, .failed)
        let called = await preparer.prepareModelCalled
        XCTAssertTrue(called)
    }

    /// Cancellation (the deferred launch task is cancelled on app quit) must be
    /// reported as `.cancelled`, never `.failed` — the AppDelegate caller drops
    /// `.cancelled` silently, so this is what prevents a spurious
    /// `vad_model_prep failed` telemetry event on every quit-mid-download.
    func testReportsCancelledRatherThanFailedOnCancellation() async {
        let preparer = MockMeetingVADModelPreparer()
        await preparer.configureCached(false)
        await preparer.configurePrepareModel(error: CancellationError())

        let outcome = await MeetingVADLaunchPrep.run(featureEnabled: true, preparer: preparer)

        XCTAssertEqual(outcome, .cancelled)
        let called = await preparer.prepareModelCalled
        XCTAssertTrue(called)
    }
}
