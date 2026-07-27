import XCTest
import MacParakeetCore
@testable import MacParakeet

final class MeetingTranscriptProcessingPresentationTests: XCTestCase {
    func testEmptyProcessingMeetingExplainsDurableBackgroundWork() throws {
        let presentation = try XCTUnwrap(
            MeetingTranscriptProcessingPresentation.make(
                sourceType: .meeting,
                status: .processing
            ))

        XCTAssertEqual(presentation.title, "Transcribing meeting")
        XCTAssertTrue(presentation.message.contains("audio is saved"))
        XCTAssertTrue(presentation.message.contains("background"))
        XCTAssertTrue(presentation.message.contains("leave this page"))
    }

    func testPresentationIsLimitedToProcessingMeetings() {
        XCTAssertNil(
            MeetingTranscriptProcessingPresentation.make(
                sourceType: .meeting,
                status: .completed
            ))
        XCTAssertNil(
            MeetingTranscriptProcessingPresentation.make(
                sourceType: .file,
                status: .processing
            ))
    }

    func testActionsStayUnavailableWhileMeetingFinalizationIsProcessing() {
        XCTAssertFalse(
            TranscriptDetailActionAvailability.canEdit(
                status: .processing
            ))
        XCTAssertFalse(
            TranscriptDetailActionAvailability.canRetranscribe(
                hasRetainedAudio: true,
                status: .processing
            ))
    }

    func testCompletedTranscriptRetainsExistingActionAvailability() {
        XCTAssertTrue(
            TranscriptDetailActionAvailability.canEdit(
                status: .completed
            ))
        XCTAssertTrue(
            TranscriptDetailActionAvailability.canRetranscribe(
                hasRetainedAudio: true,
                status: .completed
            ))
        XCTAssertTrue(
            TranscriptDetailActionAvailability.canEdit(
                status: .completed
            ))
    }
}
