import XCTest

@testable import MacParakeet

final class MeetingDeletionCopyTests: XCTestCase {
    func testAudioOnlyCopyKeepsMeetingAndNamesOptionalArtifacts() {
        let message = MeetingDeletionCopy.singleAudioOnlyMessage(surface: .library)

        XCTAssertTrue(message.contains("removes the saved audio"))
        XCTAssertTrue(message.contains("meeting stays in Library"))
        XCTAssertTrue(message.contains("Notes, AI results, and chats stay too if they exist"))
        XCTAssertTrue(message.contains("Playback and retranscription will no longer be available"))
    }

    func testFullDeleteCopyDeletesOptionalArtifactsOnlyIfTheyExist() {
        let message = MeetingDeletionCopy.singleFullDeleteMessage(title: "Roadmap sync")

        XCTAssertTrue(message.contains("permanently deletes \"Roadmap sync\""))
        XCTAssertTrue(message.contains("including its transcript and saved audio"))
        XCTAssertTrue(message.contains("Notes, AI results, and chats for this meeting are also deleted if they exist"))
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
        XCTAssertTrue(message.contains("removes saved audio from 1 meeting"))
        XCTAssertTrue(message.contains("meeting stays in Meetings"))
        XCTAssertTrue(message.contains("2 selected meetings already have no saved audio"))
    }

    func testBulkAudioOnlyCopyOmitsSelectionPrefixWhenNothingIsSkipped() {
        let message = MeetingDeletionCopy.bulkAudioOnlyMessage(
            count: 3,
            skippedCount: 0,
            surface: .meetings
        )

        XCTAssertFalse(message.contains("3 selected meetings"))
        XCTAssertTrue(message.contains("removes saved audio from 3 meetings"))
    }

    func testBulkAudioOnlyCopyUsesSingularSkippedGrammar() {
        let message = MeetingDeletionCopy.bulkAudioOnlyMessage(
            count: 1,
            skippedCount: 1,
            surface: .meetings
        )

        XCTAssertTrue(message.contains("2 selected meetings"))
        XCTAssertTrue(message.contains("1 selected meeting already has no saved audio"))
        XCTAssertTrue(message.contains("it will be skipped"))
    }

    // Mixed Library selection (the surface where the miscount bug appeared):
    // the skipped count is meeting-scoped, so the rendered copy only ever talks
    // about meetings and stays consistent with the Delete dialog's meeting count
    // — e.g. 7 meetings selected, 2 with saved audio, 5 already removed.
    func testBulkAudioOnlyCopyForLibrarySurfaceOnlyCountsMeetings() {
        let message = MeetingDeletionCopy.bulkAudioOnlyMessage(
            count: 2,
            skippedCount: 5,
            surface: .library
        )

        XCTAssertTrue(message.contains("7 selected meetings"))
        XCTAssertTrue(message.contains("removes saved audio from 2 meetings"))
        XCTAssertTrue(message.contains("meetings stay in Library"))
        XCTAssertTrue(message.contains("5 selected meetings already have no saved audio"))
    }
}
