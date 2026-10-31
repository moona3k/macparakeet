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

        XCTAssertEqual(presentation.title, "Processing meeting")
        XCTAssertTrue(presentation.message.contains("audio is saved"))
        XCTAssertTrue(presentation.message.contains("Playback and transcription"))
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

    func testSourceOnlyFailureAndCancellationExplainRecovery() throws {
        for status in [Transcription.TranscriptionStatus.error, .cancelled] {
            let presentation = try XCTUnwrap(
                MeetingTranscriptRecoveryPresentation.make(
                    sourceType: .meeting, status: status, audioState: .sourcesSaved
                ))
            XCTAssertEqual(
                presentation.title,
                status == .cancelled ? "Meeting processing stopped" : "Meeting processing failed"
            )
            XCTAssertTrue(presentation.message.contains("audio is saved"))
            XCTAssertTrue(presentation.message.contains("Retry"))
        }
    }

    func testRecoveryDoesNotOfferSourceOnlyRetryForOtherStates() {
        for status in [Transcription.TranscriptionStatus.processing, .completed] {
            XCTAssertNil(
                MeetingTranscriptRecoveryPresentation.make(
                    sourceType: .meeting, status: status, audioState: .sourcesSaved
                ))
        }
        for audioState in [MeetingAudioFile.State.saved, .removed, .missing, .notMeeting] {
            XCTAssertNil(
                MeetingTranscriptRecoveryPresentation.make(
                    sourceType: .meeting, status: .error, audioState: audioState
                ))
        }
        XCTAssertNil(
            MeetingTranscriptRecoveryPresentation.make(
                sourceType: .file, status: .error, audioState: .sourcesSaved
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
    }

    func testWholeTranscriptEditingIsLimitedToUntimedOrLegacyEdits() {
        XCTAssertTrue(
            TranscriptDetailActionAvailability.canEditWholeTranscript(
                status: .completed,
                hasTimestamps: false,
                isLegacyWholeTextEdit: false
            ))
        XCTAssertTrue(
            TranscriptDetailActionAvailability.canEditWholeTranscript(
                status: .completed,
                hasTimestamps: true,
                isLegacyWholeTextEdit: true
            ))
        XCTAssertFalse(
            TranscriptDetailActionAvailability.canEditWholeTranscript(
                status: .completed,
                hasTimestamps: true,
                isLegacyWholeTextEdit: false
            ))
    }
}
