import Foundation
import XCTest
@testable import MacParakeetCore

/// Test-owned seed step for scripts/testing/native-library-e2e.py; no product seed API.
final class NativeLibraryJourneyFixtureTests: XCTestCase {
    func testSeedOwnedNativeJourney() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["MACPARAKEET_NATIVE_E2E_ROOT"] else {
            throw XCTSkip("Only run through the isolated native Library journey runner")
        }
        guard NSUserName() == "macparakeet-e2e" else {
            XCTFail("Requires dedicated disposable macparakeet-e2e account")
            return
        }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let marker = root.appendingPathComponent("owned-native-journey")
        guard try String(contentsOf: marker) == "macparakeet-e2e\n" else {
            XCTFail("Missing owned fixture marker")
            return
        }
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        let database = try DatabaseManager(path: state.appendingPathComponent("macparakeet.db").path)
        let folder = state.appendingPathComponent("meetings/native-library-fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meeting = Transcription(
            fileName: "Native Library qualification",
            meetingArtifactFolderPath: folder.path,
            rawTranscript: "Synthetic meeting transcript: the cedar launch is approved.",
            cleanTranscript: "Synthetic meeting transcript: the cedar launch is approved.",
            status: .completed,
            sourceType: .meeting,
            userNotes: "Original synthetic notes"
        )
        try TranscriptionRepository(dbQueue: database.dbQueue).save(meeting)
        _ = try await MeetingArtifactStore().materialize(transcription: meeting)
        try meeting.id.uuidString.write(to: root.appendingPathComponent("meeting-id"), atomically: true, encoding: .utf8)
    }
}
