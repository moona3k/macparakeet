import XCTest
@testable import MacParakeetCore

final class MeetingActivityDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOffModeWithoutCandidateProducesNoEvents() {
        let result = evaluate(
            signal: snapshot(input: [.zoom]),
            mode: .off
        )

        XCTAssertEqual(result, [])
    }

    func testOffModeClearsTrackedCandidate() {
        let result = evaluate(
            signal: snapshot(input: [.zoom]),
            mode: .off,
            candidate: candidate(.zoom, since: now.addingTimeInterval(-10))
        )

        XCTAssertEqual(result, [.signalCleared])
    }

    func testActiveRecordingClearsTrackedCandidate() {
        let result = evaluate(
            signal: snapshot(input: [.zoom]),
            activeRecording: true,
            candidate: candidate(.zoom, since: now.addingTimeInterval(-10))
        )

        XCTAssertEqual(result, [.signalCleared])
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
            candidate: candidate(.zoom, since: now.addingTimeInterval(-3))
        )

        XCTAssertEqual(result, [.promptToRecord(MeetingIdentity(source: .app, app: .zoom))])
    }

    func testDedicatedMeetingAppSelectionIsDeterministic() {
        XCTAssertEqual(
            evaluate(
                signal: snapshot(input: [.teams, .zoom]),
                candidate: candidate(.zoom, since: now.addingTimeInterval(-3))
            ),
            [.promptToRecord(MeetingIdentity(source: .app, app: .zoom))]
        )

        XCTAssertEqual(
            evaluate(
                signal: snapshot(input: [.zoom, .teams]),
                candidate: candidate(.zoom, since: now.addingTimeInterval(-3))
            ),
            [.promptToRecord(MeetingIdentity(source: .app, app: .zoom))]
        )
    }

    func testCandidateMustPersistThroughDwell() {
        let result = evaluate(
            signal: snapshot(input: [.zoom]),
            candidate: candidate(.zoom, since: now.addingTimeInterval(-2.9))
        )

        XCTAssertEqual(result, [])
    }

    func testCandidateIdentityChangeClearsTrackedCandidate() {
        let result = evaluate(
            signal: snapshot(input: [.teams]),
            candidate: candidate(.zoom, since: now.addingTimeInterval(-3))
        )

        XCTAssertEqual(result, [.signalCleared])
    }

    func testAutoStartModeReturnsAutoStartDue() {
        let result = evaluate(
            signal: snapshot(input: [.teams]),
            mode: .autoStart,
            candidate: candidate(.teams, since: now.addingTimeInterval(-3))
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
                candidate: candidate(.slack, since: now.addingTimeInterval(-3))
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
                candidate: candidate(
                    identity: MeetingIdentity(source: .app, app: .browser),
                    since: now.addingTimeInterval(-3)
                )
            ),
            [.promptToRecord(MeetingIdentity(source: .app, app: .browser))]
        )

        XCTAssertEqual(
            evaluate(
                signal: snapshot(
                    input: [.chrome],
                    recognizedMeetingURLBundleIDs: [TestProcess.chrome.bundleID!]
                ),
                candidate: candidate(
                    identity: MeetingIdentity(source: .app, app: .browser),
                    since: now.addingTimeInterval(-3)
                )
            ),
            [.promptToRecord(MeetingIdentity(source: .app, app: .browser))]
        )
    }

    func testRecognizedMeetingURLMustMatchAudioBrowser() {
        XCTAssertEqual(
            evaluate(
                signal: snapshot(
                    input: [.safari],
                    recognizedMeetingURLBundleIDs: [TestProcess.chrome.bundleID!]
                ),
                candidate: candidate(
                    identity: MeetingIdentity(source: .app, app: .browser),
                    since: now.addingTimeInterval(-3)
                )
            ),
            [.signalCleared]
        )
    }

    func testMicAndCameraTriggerWithoutRecognizedApp() {
        let result = evaluate(
            signal: snapshot(input: [.unknown], cameraRunning: true),
            candidate: candidate(
                identity: MeetingIdentity(source: .camera, app: nil),
                since: now.addingTimeInterval(-3)
            )
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
                candidate: candidate(.zoom, since: now.addingTimeInterval(-3)),
                suppressedIdentities: [identity: now.addingTimeInterval(60)]
            ),
            [.signalCleared]
        )

        XCTAssertEqual(
            evaluate(
                signal: signal,
                candidate: candidate(.zoom, since: now.addingTimeInterval(-3)),
                suppressedIdentities: [identity: now.addingTimeInterval(-1)]
            ),
            [.promptToRecord(identity)]
        )
    }

    func testSignalClearedWhenCandidateDrops() {
        let result = evaluate(
            signal: snapshot(),
            candidate: candidate(.zoom, since: now.addingTimeInterval(-3))
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
        candidate: MeetingActivityDetector.Candidate? = nil,
        suppressedIdentities: [MeetingIdentity: Date] = [:]
    ) -> [MeetingActivityDetector.DetectionEvent] {
        MeetingActivityDetector.evaluate(
            signal: signal,
            now: now,
            config: .init(mode: mode),
            activeRecording: activeRecording,
            candidate: candidate,
            suppressedIdentities: suppressedIdentities
        )
    }

    private func candidate(
        _ process: TestProcess,
        since: Date
    ) -> MeetingActivityDetector.Candidate {
        guard let app = process.meetingApp else {
            XCTFail("Test process has no meeting app identity")
            return candidate(identity: MeetingIdentity(source: .camera, app: nil), since: since)
        }
        return candidate(identity: MeetingIdentity(source: .app, app: app), since: since)
    }

    private func candidate(
        identity: MeetingIdentity,
        since: Date
    ) -> MeetingActivityDetector.Candidate {
        MeetingActivityDetector.Candidate(identity: identity, since: since)
    }

    private func snapshot(
        input: [TestProcess] = [],
        output: [TestProcess] = [],
        cameraRunning: Bool = false,
        frontmost: String? = nil,
        recognizedMeetingURLBundleIDs: Set<String> = []
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
            recognizedMeetingURLBundleIDs: recognizedMeetingURLBundleIDs
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
    case safari
    case unknown

    var pid: Int32 {
        switch self {
        case .zoom: return 100
        case .teams: return 200
        case .slack: return 300
        case .chrome: return 400
        case .safari: return 500
        case .unknown: return 600
        }
    }

    var bundleID: String? {
        switch self {
        case .zoom: return "us.zoom.xos"
        case .teams: return "com.microsoft.teams2"
        case .slack: return "com.tinyspeck.slackmacgap"
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        case .unknown: return "com.example.voice"
        }
    }

    var meetingApp: MeetingApp? {
        switch self {
        case .zoom: return .zoom
        case .teams: return .teams
        case .slack: return .slack
        case .chrome, .safari: return .browser
        case .unknown: return nil
        }
    }
}
