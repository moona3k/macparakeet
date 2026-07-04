import Foundation
import XCTest
@testable import MacParakeetCore

final class MeetingCleanedMicrophoneReadinessPolicyTests: XCTestCase {
    func testShouldAttemptRenderAtProductionBoundary() {
        let policy = MeetingCleanedMicrophoneReadinessPolicy.production
        let threshold =
            policy.capSeconds
            * MeetingCleanedMicrophoneReadinessPolicy
            .bestMeasuredRealtimeFactor

        XCTAssertTrue(policy.shouldAttemptRender(for: threshold - 0.001))
        XCTAssertTrue(policy.shouldAttemptRender(for: threshold))
        XCTAssertFalse(policy.shouldAttemptRender(for: threshold + 0.001))
    }

    func testShouldAttemptRenderUsesFloorWhenItDominatesTimeout() {
        let policy = MeetingCleanedMicrophoneReadinessPolicy(
            floorSeconds: 5,
            durationMultiplier: 0.01,
            capSeconds: 1_000
        )
        let floorThreshold =
            policy.floorSeconds
            * MeetingCleanedMicrophoneReadinessPolicy
            .bestMeasuredRealtimeFactor

        XCTAssertTrue(policy.shouldAttemptRender(for: floorThreshold))
        XCTAssertFalse(policy.shouldAttemptRender(for: floorThreshold + 0.001))
    }

    func testShouldAttemptRenderUsesCapWhenItDominatesTimeout() {
        let policy = MeetingCleanedMicrophoneReadinessPolicy(
            floorSeconds: 0,
            durationMultiplier: 1,
            capSeconds: 3
        )
        let capThreshold =
            policy.capSeconds
            * MeetingCleanedMicrophoneReadinessPolicy
            .bestMeasuredRealtimeFactor

        XCTAssertTrue(policy.shouldAttemptRender(for: capThreshold))
        XCTAssertFalse(policy.shouldAttemptRender(for: capThreshold + 0.001))
    }

    func testShouldAttemptRenderForZeroAndUnknownDurations() {
        let policy = MeetingCleanedMicrophoneReadinessPolicy.production

        XCTAssertTrue(policy.shouldAttemptRender(for: 0))
        XCTAssertTrue(policy.shouldAttemptRender(for: -1))
        XCTAssertTrue(policy.shouldAttemptRender(for: .infinity))
        XCTAssertTrue(policy.shouldAttemptRender(for: .nan))
    }
}
