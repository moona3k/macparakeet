import XCTest
@testable import MacParakeetCore

final class MeetingAutoStopPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func context(
        observed: Set<String> = ["us.zoom.xos"]
    ) -> MeetingAutoStopPolicy.MeetingContext {
        MeetingAutoStopPolicy.MeetingContext(
            observedMeetingAppBundleIDs: observed,
            startedAt: now.addingTimeInterval(-60)
        )
    }

    private func observation(
        isRecording: Bool = true,
        isPaused: Bool = false,
        running: Set<String> = ["us.zoom.xos"],
        silenceSeconds: TimeInterval = 0
    ) -> MeetingAutoStopPolicy.Observation {
        MeetingAutoStopPolicy.Observation(
            now: now,
            isRecording: isRecording,
            isPaused: isPaused,
            runningMeetingAppBundleIDs: running,
            continuousSilenceSeconds: silenceSeconds
        )
    }

    private func config(
        appQuitEnabled: Bool = true,
        silenceEnabled: Bool = true,
        silenceGrace: TimeInterval = 240
    ) -> MeetingAutoStopPolicy.Config {
        MeetingAutoStopPolicy.Config(
            appQuitEnabled: appQuitEnabled,
            silenceEnabled: silenceEnabled,
            appQuitGraceSeconds: 15,
            silenceGraceSeconds: silenceGrace
        )
    }

    func testObservedMeetingAppDisappearsProposesStop() {
        let decision = MeetingAutoStopPolicy.evaluate(
            context: context(observed: ["us.zoom.xos"]),
            observation: observation(running: []),
            config: config()
        )

        XCTAssertEqual(decision, .proposeStop(reason: .meetingAppClosed(bundleID: "us.zoom.xos")))
    }

    func testDifferentAppQuitKeepsRecording() {
        let decision = MeetingAutoStopPolicy.evaluate(
            context: context(observed: ["us.zoom.xos"]),
            observation: observation(running: ["us.zoom.xos"]),
            config: config()
        )

        XCTAssertEqual(decision, .keepRecording)
    }

    func testAppNeverObservedDuringRecordingKeepsRecording() {
        let decision = MeetingAutoStopPolicy.evaluate(
            context: context(observed: []),
            observation: observation(running: []),
            config: config()
        )

        XCTAssertEqual(decision, .keepRecording)
    }

    func testPausedRecordingKeepsRecordingEvenWhenSignalEligible() {
        let decision = MeetingAutoStopPolicy.evaluate(
            context: context(observed: ["us.zoom.xos"]),
            observation: observation(isPaused: true, running: [], silenceSeconds: 300),
            config: config()
        )

        XCTAssertEqual(decision, .keepRecording)
    }

    func testNotRecordingKeepsRecordingEvenWhenSignalEligible() {
        let decision = MeetingAutoStopPolicy.evaluate(
            context: context(observed: ["us.zoom.xos"]),
            observation: observation(isRecording: false, running: [], silenceSeconds: 300),
            config: config()
        )

        XCTAssertEqual(decision, .keepRecording)
    }

    func testSilenceAtGraceProposesStop() {
        let decision = MeetingAutoStopPolicy.evaluate(
            context: context(observed: []),
            observation: observation(running: [], silenceSeconds: 240),
            config: config(silenceGrace: 240)
        )

        XCTAssertEqual(decision, .proposeStop(reason: .prolongedSilence))
    }

    func testSilenceBelowGraceKeepsRecording() {
        let decision = MeetingAutoStopPolicy.evaluate(
            context: context(observed: []),
            observation: observation(running: [], silenceSeconds: 239.9),
            config: config(silenceGrace: 240)
        )

        XCTAssertEqual(decision, .keepRecording)
    }

    func testSilenceDisabledKeepsRecording() {
        let decision = MeetingAutoStopPolicy.evaluate(
            context: context(observed: []),
            observation: observation(running: [], silenceSeconds: 300),
            config: config(silenceEnabled: false, silenceGrace: 240)
        )

        XCTAssertEqual(decision, .keepRecording)
    }

    func testAppQuitDisabledKeepsRecordingForClosedApp() {
        let decision = MeetingAutoStopPolicy.evaluate(
            context: context(observed: ["us.zoom.xos"]),
            observation: observation(running: []),
            config: config(appQuitEnabled: false)
        )

        XCTAssertEqual(decision, .keepRecording)
    }

    func testAppQuitWinsWhenBothSignalsAreEligible() {
        let decision = MeetingAutoStopPolicy.evaluate(
            context: context(observed: ["us.zoom.xos"]),
            observation: observation(running: [], silenceSeconds: 300),
            config: config(silenceGrace: 240)
        )

        XCTAssertEqual(decision, .proposeStop(reason: .meetingAppClosed(bundleID: "us.zoom.xos")))
    }

    func testClosedBundleChoiceIsDeterministic() {
        let decision = MeetingAutoStopPolicy.evaluate(
            context: context(observed: ["us.zoom.xos", "com.apple.FaceTime"]),
            observation: observation(running: []),
            config: config()
        )

        XCTAssertEqual(decision, .proposeStop(reason: .meetingAppClosed(bundleID: "com.apple.FaceTime")))
    }

    func testMeetingAppRegistryIncludesNativeAppsFromADR() {
        XCTAssertTrue(MeetingAppRegistry.isRecognizedNativeApp(bundleID: "us.zoom.xos"))
        XCTAssertTrue(MeetingAppRegistry.isRecognizedNativeApp(bundleID: "com.microsoft.teams2"))
        XCTAssertTrue(MeetingAppRegistry.isRecognizedNativeApp(bundleID: "com.microsoft.teams"))
        XCTAssertTrue(MeetingAppRegistry.isRecognizedNativeApp(bundleID: "com.cisco.webexmeetingsapp"))
        XCTAssertTrue(MeetingAppRegistry.isRecognizedNativeApp(bundleID: "Cisco-Systems.Spark"))
        XCTAssertTrue(MeetingAppRegistry.isRecognizedNativeApp(bundleID: "com.apple.FaceTime"))
        XCTAssertFalse(MeetingAppRegistry.isRecognizedNativeApp(bundleID: "com.apple.Safari"))
    }
}
