import XCTest
@testable import MacParakeet

@MainActor
final class SparkleUpdateGuardTests: XCTestCase {
    // MARK: - isDevBuildVersion

    func testIsDevBuildVersionTrueForNil() {
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion(nil))
    }

    func testIsDevBuildVersionTrueForEmpty() {
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion(""))
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion("   "))
    }

    func testIsDevBuildVersionTrueForZeroSentinel() {
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion("0.0.0"))
    }

    func testIsDevBuildVersionTrueForDevSentinel() {
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion("dev"))
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion("DEV"))
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion("Dev"))
    }

    func testIsDevBuildVersionTrueForPdxSubstring() {
        // OSS-cohort sentinel per memory note (project_telemetry_time_anchor).
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion("0.6.0-pdx"))
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion("pdx"))
    }

    func testIsDevBuildVersionFalseForSemverRelease() {
        XCTAssertFalse(SparkleUpdateGuard.isDevBuildVersion("0.5.7"))
        XCTAssertFalse(SparkleUpdateGuard.isDevBuildVersion("1.0.0"))
        XCTAssertFalse(SparkleUpdateGuard.isDevBuildVersion("0.6.0"))
        XCTAssertFalse(SparkleUpdateGuard.isDevBuildVersion("10.20.30"))
    }

    // MARK: - blockReason

    func testBlockReasonBlocksDevBuildBeforeMeetingState() {
        XCTAssertEqual(
            SparkleUpdateGuard.blockReason(appVersion: "0.0.0", isMeetingRecordingActive: true),
            .devBuild(version: "0.0.0")
        )
    }

    func testBlockReasonBlocksReleaseBuildDuringMeeting() {
        XCTAssertEqual(
            SparkleUpdateGuard.blockReason(appVersion: "0.6.0", isMeetingRecordingActive: true),
            .meetingRecordingActive
        )
    }

    func testBlockReasonAllowsReleaseBuildWhenIdle() {
        XCTAssertNil(
            SparkleUpdateGuard.blockReason(appVersion: "0.6.0", isMeetingRecordingActive: false)
        )
    }
}
