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
            count: 3,
            skippedCount: 2,
            surface: .meetings
        )

        XCTAssertTrue(message.contains("removes saved audio from 3 meetings"))
        XCTAssertTrue(message.contains("meetings stay in Meetings"))
        XCTAssertTrue(message.contains("2 selected items will be skipped"))
    }
}
