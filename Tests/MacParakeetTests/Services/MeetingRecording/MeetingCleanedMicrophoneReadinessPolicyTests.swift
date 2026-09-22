import Foundation
import XCTest
@testable import MacParakeetCore

final class MeetingCleanedMicrophoneReadinessPolicyTests: XCTestCase {
    func testBestMeasuredRealtimeFactorUsesFastestAuditedThroughput() {
        XCTAssertEqual(
            MeetingCleanedMicrophoneReadinessPolicy.bestMeasuredRealtimeFactor,
            12.59,
            accuracy: 0.001
        )
    }

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

final class MeetingSourceAlignmentDurationTests: XCTestCase {
    func testStartOffsetRequiresCompleteWriterTimelineOrigins() {
        XCTAssertEqual(
            MeetingSourceAlignment.startOffsetMs(
                timelineOriginSeconds: 101.25,
                meetingOriginTimelineSeconds: 100
            ),
            1_250
        )
        XCTAssertEqual(
            MeetingSourceAlignment.startOffsetMs(
                timelineOriginSeconds: nil,
                meetingOriginTimelineSeconds: 100
            ),
            0
        )
        XCTAssertEqual(
            MeetingSourceAlignment.startOffsetMs(
                timelineOriginSeconds: 101.25,
                meetingOriginTimelineSeconds: nil
            ),
            0
        )
    }

    func testCleanedMicRenderDurationUsesLongestCapturedSource() {
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: nil,
            microphone: .init(
                firstHostTime: nil,
                lastHostTime: nil,
                startOffsetMs: 0,
                writtenFrameCount: 48_000 * 120,
                sampleRate: 48_000
            ),
            system: .init(
                firstHostTime: nil,
                lastHostTime: nil,
                startOffsetMs: 0,
                writtenFrameCount: 48_000 * 90,
                sampleRate: 48_000
            )
        )

        XCTAssertEqual(alignment.cleanedMicrophoneRenderDurationSeconds, 120, accuracy: 0.001)
    }

    func testCleanedMicRenderDurationTreatsInvalidMetricsAsUnknown() {
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: nil,
            microphone: .init(
                firstHostTime: nil,
                lastHostTime: nil,
                startOffsetMs: 0,
                writtenFrameCount: -1,
                sampleRate: 48_000
            ),
            system: .init(
                firstHostTime: nil,
                lastHostTime: nil,
                startOffsetMs: 0,
                writtenFrameCount: 48_000,
                sampleRate: 0
            )
        )

        XCTAssertEqual(alignment.cleanedMicrophoneRenderDurationSeconds, 0, accuracy: 0.001)
    }

    func testCapturedMediaDurationFeedsPredictedTimeoutPolicy() {
        let policy = MeetingCleanedMicrophoneReadinessPolicy.production
        let threshold =
            policy.capSeconds
            * MeetingCleanedMicrophoneReadinessPolicy
            .bestMeasuredRealtimeFactor
        let sampleRate = 48_000.0
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: nil,
            microphone: .init(
                firstHostTime: nil,
                lastHostTime: nil,
                startOffsetMs: 0,
                writtenFrameCount: Int64(((threshold + 1) * sampleRate).rounded()),
                sampleRate: sampleRate
            ),
            system: nil
        )

        XCTAssertFalse(
            policy.shouldAttemptRender(
                for: alignment.cleanedMicrophoneRenderDurationSeconds
            )
        )
    }
}
