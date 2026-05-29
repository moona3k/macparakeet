import XCTest
@testable import MacParakeetCore

/// Phase 4.5 — universal launch-time VAD model availability
/// (`plans/active/2026-05-meeting-vad-guided-live-chunking.md` §6).
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
}
