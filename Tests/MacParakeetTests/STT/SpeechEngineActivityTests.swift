import XCTest
@testable import MacParakeetCore

final class SpeechEngineActivityTests: XCTestCase {
    func testColdSecondaryEngineConstructionIgnoresUnrelatedActiveEngine() {
        var activity = SpeechEngineActivity()

        activity.begin(.parakeet)
        activity.begin(.whisper)

        XCTAssertEqual(activity.totalCount, 2)
        XCTAssertEqual(activity.count(for: .whisper), 1)
        XCTAssertTrue(activity.canConstruct(.whisper, includingCurrentJob: true))
    }

    func testConstructionRejectsAnotherJobAlreadyUsingTheSameEngine() {
        var activity = SpeechEngineActivity()

        activity.begin(.whisper)
        activity.begin(.whisper)

        XCTAssertFalse(activity.canConstruct(.whisper, includingCurrentJob: true))
    }

    func testColdNemotronConstructionIgnoresUnrelatedActiveEngine() {
        var activity = SpeechEngineActivity()

        activity.begin(.parakeet)
        activity.begin(.nemotron)

        XCTAssertEqual(activity.count(for: .nemotron), 1)
        XCTAssertTrue(activity.canConstruct(.nemotron, includingCurrentJob: true))
    }

    func testWarmUpMayConstructOnlyWhenTargetEngineIsInactive() {
        var activity = SpeechEngineActivity()

        activity.begin(.parakeet)

        XCTAssertTrue(activity.canConstruct(.whisper, includingCurrentJob: false))

        activity.begin(.whisper)

        XCTAssertFalse(activity.canConstruct(.whisper, includingCurrentJob: false))
    }

    func testEndingWorkRestoresEngineAndGlobalIdleState() {
        var activity = SpeechEngineActivity()

        activity.begin(.parakeet)
        activity.begin(.whisper)
        activity.end(.whisper)

        XCTAssertEqual(activity.count(for: .whisper), 0)
        XCTAssertFalse(activity.isIdle)

        activity.end(.parakeet)

        XCTAssertTrue(activity.isIdle)
    }
}
