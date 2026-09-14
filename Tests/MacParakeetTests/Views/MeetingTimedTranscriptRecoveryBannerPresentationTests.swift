import XCTest
import MacParakeetCore
@testable import MacParakeet

final class MeetingTimedTranscriptRecoveryBannerPresentationTests: XCTestCase {
    func testDoesNotShowForEmptyTranscriptText() {
        let presentation = MeetingTimedTranscriptRecoveryBannerPresentation.make(
            transcriptText: " \n\t ",
            hasRetainedAudio: true,
            timestampCapableRerun: SpeechEngineSelection(engine: .nemotron)
        )

        XCTAssertNil(presentation)
    }

    func testTimestampCapableRerunFramesActionAsTimedRetry() throws {
        let rerun = SpeechEngineSelection(engine: .nemotron)
        let presentation = try XCTUnwrap(MeetingTimedTranscriptRecoveryBannerPresentation.make(
            transcriptText: "Already transcribed text.",
            hasRetainedAudio: true,
            timestampCapableRerun: rerun
        ))

        XCTAssertEqual(presentation.title, "No timed transcript")
        XCTAssertEqual(presentation.action?.title, "Add timestamps…")
        XCTAssertEqual(presentation.action?.selection, rerun)
        XCTAssertTrue(presentation.message.contains("try adding timestamps"))
        XCTAssertTrue(presentation.message.contains("may download a model"))
        XCTAssertTrue(presentation.message.contains("take several minutes"))
        XCTAssertTrue(presentation.message.contains("Speaker labels depend on the captured audio"))
        XCTAssertFalse(presentation.message.contains("to add them"))
    }

    func testRetainedAudioWithoutTimestampEngineExplainsUnavailableEngine() throws {
        let presentation = try XCTUnwrap(MeetingTimedTranscriptRecoveryBannerPresentation.make(
            transcriptText: "Already transcribed text.",
            hasRetainedAudio: true,
            timestampCapableRerun: nil
        ))

        XCTAssertEqual(presentation.title, "No timed transcript")
        XCTAssertNil(presentation.action)
        XCTAssertTrue(presentation.message.contains("none is available right now"))
    }

    func testMissingAudioExplainsRerunIsUnavailable() throws {
        let presentation = try XCTUnwrap(MeetingTimedTranscriptRecoveryBannerPresentation.make(
            transcriptText: "Already transcribed text.",
            hasRetainedAudio: false,
            timestampCapableRerun: nil
        ))

        XCTAssertEqual(presentation.title, "No timed transcript")
        XCTAssertNil(presentation.action)
        XCTAssertTrue(presentation.message.contains("Saved audio is no longer available"))
    }
}
