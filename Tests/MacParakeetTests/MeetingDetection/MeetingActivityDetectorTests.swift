import XCTest
@testable import MacParakeetCore

final class MeetingActivityDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOffModeProducesNoEvents() {
        let result = evaluate(
            signal: snapshot(input: [.zoom]),
            mode: .off,
            candidateSince: now.addingTimeInterval(-10)
        )

        XCTAssertEqual(result, [])
    }

    func testActiveRecordingSuppressesDetection() {
        let result = evaluate(
            signal: snapshot(input: [.zoom]),
            activeRecording: true,
            candidateSince: now.addingTimeInterval(-10)
        )

        XCTAssertEqual(result, [])
    }

    func testMicAloneDoesNotTrigger() {
        let result = evaluate(
            signal: snapshot(input: [.unknown])
        )

        XCTAssertEqual(result, [])
    }

    func testOutputAloneDoesNotTrigger() {
        let result = evaluate(
            signal: snapshot(output: [.zoom])
        )

        XCTAssertEqual(result, [])
    }

    func testDedicatedMeetingAppWithMicTriggersAfterDwell() {
        let result = evaluate(
            signal: snapshot(input: [.zoom]),
            candidateSince: now.addingTimeInterval(-3)
        )

        XCTAssertEqual(result, [.promptToRecord(MeetingIdentity(source: .app, app: .zoom))])
    }

    func testCandidateMustPersistThroughDwell() {
        let result = evaluate(
            signal: snapshot(input: [.zoom]),
            candidateSince: now.addingTimeInterval(-2.9)
        )

        XCTAssertEqual(result, [])
    }

    func testAutoStartModeReturnsAutoStartDue() {
        let result = evaluate(
            signal: snapshot(input: [.teams]),
            mode: .autoStart,
            candidateSince: now.addingTimeInterval(-3)
        )

        XCTAssertEqual(result, [.autoStartDue(MeetingIdentity(source: .app, app: .teams))])
    }

    func testSlackRequiresFullDuplexAudio() {
        XCTAssertEqual(
            evaluate(signal: snapshot(input: [.slack])),
            []
        )

        XCTAssertEqual(
            evaluate(
                signal: snapshot(input: [.slack], output: [.slack]),
                candidateSince: now.addingTimeInterval(-3)
            ),
            [.promptToRecord(MeetingIdentity(source: .app, app: .slack))]
        )
    }

    func testBrowserRequiresFrontmostOrRecognizedMeetingURL() {
        XCTAssertEqual(
            evaluate(signal: snapshot(input: [.chrome])),
            []
        )

        XCTAssertEqual(
            evaluate(
                signal: snapshot(input: [.chrome], frontmost: TestProcess.chrome.bundleID),
                candidateSince: now.addingTimeInterval(-3)
            ),
            [.promptToRecord(MeetingIdentity(source: .app, app: .browser))]
        )

        XCTAssertEqual(
            evaluate(
                signal: snapshot(input: [.chrome], hasRecognizedMeetingURL: true),
                candidateSince: now.addingTimeInterval(-3)
            ),
            [.promptToRecord(MeetingIdentity(source: .app, app: .browser))]
        )
    }

    func testMicAndCameraTriggerWithoutRecognizedApp() {
        let result = evaluate(
            signal: snapshot(input: [.unknown], cameraRunning: true),
            candidateSince: now.addingTimeInterval(-3)
        )

        XCTAssertEqual(result, [.promptToRecord(MeetingIdentity(source: .camera, app: nil))])
    }

    func testCameraAloneDoesNotTrigger() {
        let result = evaluate(
            signal: snapshot(cameraRunning: true)
        )

        XCTAssertEqual(result, [])
    }

    func testMicAndCameraWithSelfFilteredAudioDoesNotTrigger() {
        let processes = [
            AudioProcessActivity(pid: 100, bundleID: "com.macparakeet", isRunningInput: true, isRunningOutput: false),
        ]
        let filtered = AudioProcessActivityCollector.filterSelf(
            processes: processes,
            selfProcessID: 100,
            selfBundleID: "com.macparakeet"
        )

        let result = evaluate(
            signal: ActivitySignalSnapshot(
                audio: ProcessAudioSnapshot(processes: filtered),
                cameraRunning: true
            )
        )

        XCTAssertEqual(result, [])
    }

    func testSuppressedIdentityDoesNotPromptUntilCooldownExpires() {
        let identity = MeetingIdentity(source: .app, app: .zoom)
        let signal = snapshot(input: [.zoom])

        XCTAssertEqual(
            evaluate(
                signal: signal,
                candidateSince: now.addingTimeInterval(-3),
                suppressedIdentities: [identity: now.addingTimeInterval(60)]
            ),
            []
        )

        XCTAssertEqual(
            evaluate(
                signal: signal,
                candidateSince: now.addingTimeInterval(-3),
                suppressedIdentities: [identity: now.addingTimeInterval(-1)]
            ),
            [.promptToRecord(identity)]
        )
    }

    func testSignalClearedWhenCandidateDrops() {
        let result = evaluate(
            signal: snapshot(),
            candidateSince: now.addingTimeInterval(-3)
        )

        XCTAssertEqual(result, [.signalCleared])
    }

    func testCollectorSelfFilterRemovesOwnPIDAndBundleID() {
        let processes = [
            activity(.zoom, pid: 100, input: true),
            activity(.teams, pid: 200, input: true),
            AudioProcessActivity(pid: 300, bundleID: "com.macparakeet", isRunningInput: true, isRunningOutput: false),
        ]

        let filtered = AudioProcessActivityCollector.filterSelf(
            processes: processes,
            selfProcessID: 100,
            selfBundleID: "com.macparakeet"
        )

        XCTAssertEqual(filtered, [activity(.teams, pid: 200, input: true)])
    }

    func testCameraCollectorAggregatesAnyRunningDevice() {
        XCTAssertFalse(CameraActivityCollector.cameraRunning(deviceStates: []))
        XCTAssertFalse(CameraActivityCollector.cameraRunning(deviceStates: [false, false]))
        XCTAssertTrue(CameraActivityCollector.cameraRunning(deviceStates: [false, true, false]))
    }

    private func evaluate(
        signal: ActivitySignalSnapshot,
        mode: MeetingActivityDetectionMode = .prompt,
        activeRecording: Bool = false,
        candidateSince: Date? = nil,
        suppressedIdentities: [MeetingIdentity: Date] = [:]
    ) -> [MeetingActivityDetector.DetectionEvent] {
        MeetingActivityDetector.evaluate(
            signal: signal,
            now: now,
            config: .init(mode: mode),
            activeRecording: activeRecording,
            candidateSince: candidateSince,
            suppressedIdentities: suppressedIdentities
        )
    }

    private func snapshot(
        input: [TestProcess] = [],
        output: [TestProcess] = [],
        cameraRunning: Bool = false,
        frontmost: String? = nil,
        hasRecognizedMeetingURL: Bool = false
    ) -> ActivitySignalSnapshot {
        let inputActivities = input.map { activity($0, input: true, output: output.contains($0)) }
        let inputPIDs = Set(inputActivities.map(\.pid))
        let outputOnlyActivities = output
            .filter { process in !inputPIDs.contains(process.pid) }
            .map { activity($0, input: false, output: true) }
        return ActivitySignalSnapshot(
            audio: ProcessAudioSnapshot(processes: inputActivities + outputOnlyActivities),
            cameraRunning: cameraRunning,
            frontmostBundleID: frontmost,
            hasRecognizedMeetingURL: hasRecognizedMeetingURL
        )
    }

    private func activity(
        _ process: TestProcess,
        pid: Int32? = nil,
        input: Bool,
        output: Bool = false
    ) -> AudioProcessActivity {
        AudioProcessActivity(
            pid: pid ?? process.pid,
            bundleID: process.bundleID,
            isRunningInput: input,
            isRunningOutput: output
        )
    }
}

private enum TestProcess: CaseIterable {
    case zoom
    case teams
    case slack
    case chrome
    case unknown

    var pid: Int32 {
        switch self {
        case .zoom: return 100
        case .teams: return 200
        case .slack: return 300
        case .chrome: return 400
        case .unknown: return 500
        }
    }

    var bundleID: String? {
        switch self {
        case .zoom: return "us.zoom.xos"
        case .teams: return "com.microsoft.teams2"
        case .slack: return "com.tinyspeck.slackmacgap"
        case .chrome: return "com.google.Chrome"
        case .unknown: return "com.example.voice"
        }
    }
}
