import Foundation
import XCTest
@testable import MacParakeetCore

final class MeetingAutomationHookRunnerTests: XCTestCase {
    private var folderURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingAutomationHookRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folderURL.appendingPathComponent("meeting.m4a"))

        suiteName = "macparakeet.test.meeting-hook.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        if let folderURL {
            try? FileManager.default.removeItem(at: folderURL)
        }
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        folderURL = nil
        defaults = nil
        suiteName = nil
    }

    func testDisabledHookIsSkippedWithoutWritingResultFile() async throws {
        let transcription = makeMeeting()
        let artifact = try await MeetingArtifactStore().materialize(
            transcription: transcription,
            promptResults: []
        )

        let result = await MeetingAutomationHookRunner(defaults: defaults)
            .runCompletedMeetingHook(transcription: transcription, artifact: artifact)

        XCTAssertEqual(result.status, .skipped)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folderURL.appendingPathComponent(MeetingAutomationHookRunner.resultFileName).path
        ))
    }

    func testEnabledHookReceivesJSONEventAndWritesResult() async throws {
        let transcription = makeMeeting()
        let artifact = try await MeetingArtifactStore().materialize(
            transcription: transcription,
            promptResults: []
        )
        let eventPath = folderURL.appendingPathComponent("hook-event.json")
        let script = folderURL.appendingPathComponent("capture-hook.sh")
        try """
        #!/bin/sh
        cat > "$MACPARAKEET_ARTIFACT_DIR/hook-event.json"
        test "$MACPARAKEET_MEETING_ID" = "\(transcription.id.uuidString)"
        test "$MACPARAKEET_ARTIFACT_MANIFEST" = "\(artifact.manifestPath)"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )

        defaults.set(true, forKey: MeetingAutomationHookConfiguration.enabledKey)
        defaults.set(script.path, forKey: MeetingAutomationHookConfiguration.executablePathKey)
        defaults.set(5.0, forKey: MeetingAutomationHookConfiguration.timeoutSecondsKey)

        let result = await MeetingAutomationHookRunner(defaults: defaults)
            .runCompletedMeetingHook(transcription: transcription, artifact: artifact)

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: eventPath.path))

        let event = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: eventPath)) as? [String: Any]
        )
        XCTAssertEqual(event["schema"] as? String, MeetingAutomationHookRunner.eventSchema)
        XCTAssertEqual(event["event"] as? String, "meeting.completed")
        let meeting = try XCTUnwrap(event["meeting"] as? [String: Any])
        XCTAssertEqual(meeting["id"] as? String, transcription.id.uuidString)

        let resultPath = folderURL.appendingPathComponent(MeetingAutomationHookRunner.resultFileName)
        let resultJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: resultPath)) as? [String: Any]
        )
        XCTAssertEqual(resultJSON["status"] as? String, "success")
        XCTAssertEqual(resultJSON["meetingID"] as? String, transcription.id.uuidString)
    }

    func testConfiguredNonExecutablePathFailsSafely() async throws {
        let transcription = makeMeeting()
        let artifact = try await MeetingArtifactStore().materialize(
            transcription: transcription,
            promptResults: []
        )
        let file = folderURL.appendingPathComponent("not-executable")
        try "nope".write(to: file, atomically: true, encoding: .utf8)

        defaults.set(true, forKey: MeetingAutomationHookConfiguration.enabledKey)
        defaults.set(file.path, forKey: MeetingAutomationHookConfiguration.executablePathKey)

        let result = await MeetingAutomationHookRunner(defaults: defaults)
            .runCompletedMeetingHook(transcription: transcription, artifact: artifact)

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.error?.contains("not executable") == true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folderURL.appendingPathComponent(MeetingAutomationHookRunner.resultFileName).path
        ))
    }

    private func makeMeeting() -> Transcription {
        Transcription(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            fileName: "Automation Review",
            filePath: folderURL.appendingPathComponent("meeting.m4a").path,
            durationMs: 1_000,
            rawTranscript: "Discuss hook safety.",
            status: .completed,
            sourceType: .meeting
        )
    }
}
