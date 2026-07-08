import XCTest

@testable import MacParakeet
@testable import MacParakeetCore

final class MeetingDeletionCopyTests: XCTestCase {
    func testAudioOnlyCopyKeepsMeetingAndNamesOptionalArtifacts() {
        let message = MeetingDeletionCopy.singleAudioOnlyMessage(surface: .library)

        XCTAssertTrue(message.contains("permanently deletes the saved audio"))
        XCTAssertTrue(message.contains("meeting stays in Library"))
        XCTAssertTrue(message.contains("Notes, AI results, and chats stay too if they exist"))
        XCTAssertTrue(message.contains("Playback and re-transcription will no longer be available"))
        XCTAssertTrue(message.contains("detect or backfill speakers for this recording"))
        XCTAssertEqual(message.components(separatedBy: "permanently").count - 1, 1)
    }

    func testFullDeleteCopyDeletesOptionalArtifactsOnlyIfTheyExist() {
        let message = MeetingDeletionCopy.singleFullDeleteMessage(title: "Roadmap sync")

        XCTAssertTrue(message.contains("permanently deletes \"Roadmap sync\""))
        XCTAssertTrue(message.contains("including its transcript and saved audio"))
        XCTAssertTrue(message.contains("Notes, AI results, and chats for this meeting are also deleted if they exist"))
    }

    func testAudioOnlyCopyWarnsWhenMeetingIsNotCompleted() {
        let message = MeetingDeletionCopy.singleAudioOnlyMessage(
            surface: .library,
            status: .processing
        )

        XCTAssertTrue(
            message.hasPrefix("This meeting hasn't been transcribed yet — deleting the audio makes that permanent."))
        XCTAssertTrue(message.contains("permanently deletes the saved audio"))
    }

    func testCompletedAudioOnlyCopyDoesNotShowRetentionWarning() {
        let message = MeetingDeletionCopy.singleAudioOnlyMessage(
            surface: .library,
            status: .completed
        )

        XCTAssertFalse(message.contains("hasn't been transcribed yet"))
    }

    func testFullDeleteCopyWarnsWhenMeetingIsNotCompleted() {
        let message = MeetingDeletionCopy.singleFullDeleteMessage(
            title: "Roadmap sync",
            status: .error
        )

        XCTAssertTrue(
            message.hasPrefix("This meeting hasn't been transcribed yet — deleting the audio makes that permanent."))
        XCTAssertTrue(message.contains("permanently deletes \"Roadmap sync\""))
    }

    func testBulkFullDeleteCopyUsesSingularMeetingCopy() {
        let message = MeetingDeletionCopy.bulkFullDeleteMessage(count: 1)

        XCTAssertTrue(message.contains("permanently deletes 1 meeting"))
        XCTAssertTrue(message.contains("including its transcript and saved audio"))
        XCTAssertTrue(message.contains("Notes, AI results, and chats for this meeting are also deleted if they exist"))
    }

    func testBulkAudioOnlyCopyMentionsSkippedUnavailableAudio() {
        let message = MeetingDeletionCopy.bulkAudioOnlyMessage(
            count: 1,
            skippedCount: 2,
            surface: .meetings
        )

        XCTAssertTrue(message.contains("3 selected meetings"))
        XCTAssertTrue(message.contains("permanently deletes saved audio from 1 meeting"))
        XCTAssertTrue(message.contains("meeting stays in Meetings"))
        XCTAssertTrue(message.contains("detect or backfill speakers for this recording"))
        XCTAssertTrue(message.contains("2 selected meetings cannot have their audio removed right now"))
    }

    func testBulkAudioOnlyCopyOmitsSelectionPrefixWhenNothingIsSkipped() {
        let message = MeetingDeletionCopy.bulkAudioOnlyMessage(
            count: 3,
            skippedCount: 0,
            surface: .meetings
        )

        XCTAssertFalse(message.contains("3 selected meetings"))
        XCTAssertTrue(message.contains("permanently deletes saved audio from 3 meetings"))
        XCTAssertTrue(message.contains("detect or backfill speakers for these recordings"))
    }

    func testBulkAudioOnlyCopyUsesSingularSkippedGrammar() {
        let message = MeetingDeletionCopy.bulkAudioOnlyMessage(
            count: 1,
            skippedCount: 1,
            surface: .meetings
        )

        XCTAssertTrue(message.contains("2 selected meetings"))
        XCTAssertTrue(message.contains("1 selected meeting cannot have its audio removed right now"))
        XCTAssertTrue(message.contains("it will be skipped"))
    }

    func testAudioRemovalUnavailableHelpTreatsLockedSavedAudioAsFinalizing() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-deletion-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let audioURL = folderURL.appendingPathComponent("meeting-playback.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
        try MeetingRecordingLockFileStore().write(
            MeetingRecordingLockFile(
                sessionId: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                pid: 99,
                displayName: "Recovering Meeting",
                state: .awaitingTranscription
            ),
            folderURL: folderURL
        )
        let transcription = Transcription(
            fileName: "Meeting",
            filePath: audioURL.path,
            status: .error,
            sourceType: .meeting
        )

        XCTAssertEqual(
            MeetingDeletionCopy.audioRemovalUnavailableHelp(for: transcription, state: .saved),
            TranscriptionAssetCleanup.meetingAudioFinalizationInProgressMessage
        )
    }

    func testBulkDeleteCopyWarnsWhenAnySelectedMeetingIsNotCompleted() {
        let message = MeetingDeletionCopy.bulkFullDeleteMessage(
            count: 2,
            hasNonCompletedMeeting: true
        )

        XCTAssertTrue(
            message.hasPrefix(
                "At least one selected meeting hasn't been transcribed yet — deleting the audio makes that permanent."))
        XCTAssertTrue(message.contains("permanently deletes 2 meetings"))
    }

    // Mixed Library selection (the surface where the miscount bug appeared):
    // the skipped count is meeting-scoped, so the rendered copy only ever talks
    // about meetings and stays consistent with the Delete dialog's meeting count
    // — e.g. 7 meetings selected, 2 with removable audio, 5 not removable.
    func testBulkAudioOnlyCopyForLibrarySurfaceOnlyCountsMeetings() {
        let message = MeetingDeletionCopy.bulkAudioOnlyMessage(
            count: 2,
            skippedCount: 5,
            surface: .library
        )

        XCTAssertTrue(message.contains("7 selected meetings"))
        XCTAssertTrue(message.contains("permanently deletes saved audio from 2 meetings"))
        XCTAssertTrue(message.contains("meetings stay in Library"))
        XCTAssertTrue(message.contains("5 selected meetings cannot have their audio removed right now"))
    }
}
