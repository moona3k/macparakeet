import Foundation
import XCTest
@testable import MacParakeetCore

/// Ensures the derived `microphone-cleaned.m4a` (plan #605 U3) is treated as a
/// standard managed meeting artifact so retention/detach removes it alongside
/// the raw sources instead of orphaning it.
final class TranscriptionAssetCleanupCleanedMicTests: XCTestCase {
    func testCleanedMicIsAStandardMeetingAudioFileName() {
        XCTAssertTrue(
            TranscriptionAssetCleanup.isStandardMeetingAudioFileName("microphone-cleaned.m4a"),
            "the targeted Remove-Audio-Only detach path keys off this set")
        XCTAssertTrue(TranscriptionAssetCleanup.isStandardMeetingAudioFileName("microphone-raw.m4a"))
        XCTAssertTrue(TranscriptionAssetCleanup.isStandardMeetingAudioFileName("system-raw.m4a"))
        XCTAssertTrue(TranscriptionAssetCleanup.isStandardMeetingAudioFileName("meeting-playback.m4a"))
        XCTAssertFalse(TranscriptionAssetCleanup.isStandardMeetingAudioFileName("microphone.m4a"))
        XCTAssertFalse(TranscriptionAssetCleanup.isStandardMeetingAudioFileName("system.m4a"))
        XCTAssertFalse(TranscriptionAssetCleanup.isStandardMeetingAudioFileName("meeting.m4a"))
        XCTAssertEqual(
            "microphone-cleaned.m4a",
            MeetingCleanedMicRenderer.cleanedMicrophoneFileName,
            "retention must track the same filename the renderer writes")
    }

    func testRemoveManagedMeetingAudioSweepsCleanedMic() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audioFiles = ["meeting-playback.m4a", "microphone-raw.m4a", "system-raw.m4a", "microphone-cleaned.m4a"]
        for name in audioFiles {
            try Data([0x00]).write(to: session.appendingPathComponent(name))
        }
        let notesURL = session.appendingPathComponent("notes.txt")
        try Data([0x00]).write(to: notesURL)

        try TranscriptionAssetCleanup.removeManagedMeetingAudioFiles(under: root.path)

        for name in audioFiles {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: session.appendingPathComponent(name).path),
                "\(name) should be removed by the managed-audio sweep")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: notesURL.path),
            "non-audio sidecars are preserved")
    }
}
