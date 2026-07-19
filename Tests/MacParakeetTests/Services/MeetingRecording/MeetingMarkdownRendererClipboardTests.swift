import XCTest
@testable import MacParakeetCore

final class MeetingMarkdownRendererClipboardTests: XCTestCase {
    func testRenderForClipboardIncludesTitleNotesAndPreferredTranscript() {
        let transcription = Transcription(
            fileName: "Weekly Product Sync",
            rawTranscript: "Unedited transcript.",
            cleanTranscript: "Edited transcript.",
            status: .completed,
            sourceType: .meeting,
            userNotes: "  Decision: Ship Friday.\nOwner: Dana.  "
        )

        let markdown = MeetingMarkdownRenderer().renderForClipboard(
            transcription: transcription
        )

        XCTAssertEqual(
            markdown,
            """
            # Weekly Product Sync

            ## Notes

            Decision: Ship Friday.
            Owner: Dana.

            ## Transcript

            Edited transcript.

            """
        )
    }

    func testRenderForClipboardOmitsBlankNotesAndFallsBackToRawTranscript() {
        let transcription = Transcription(
            fileName: "Customer Call",
            rawTranscript: "Raw transcript.",
            cleanTranscript: "  \n",
            status: .completed,
            sourceType: .meeting,
            userNotes: " \n\t "
        )

        let markdown = MeetingMarkdownRenderer().renderForClipboard(
            transcription: transcription
        )

        XCTAssertEqual(
            markdown,
            """
            # Customer Call

            ## Transcript

            Raw transcript.

            """
        )
    }

    func testRenderForClipboardIncludesReliableSpeakerLabels() {
        let transcription = Transcription(
            fileName: "Design Review",
            rawTranscript: "Ship it.",
            wordTimestamps: [
                WordTimestamp(
                    word: "Ship",
                    startMs: 0,
                    endMs: 400,
                    confidence: 0.9,
                    speakerId: "S1"
                ),
                WordTimestamp(
                    word: "it.",
                    startMs: 450,
                    endMs: 800,
                    confidence: 0.9,
                    speakerId: "S1"
                ),
            ],
            speakers: [SpeakerInfo(id: "S1", label: "Dana")],
            status: .completed,
            sourceType: .meeting
        )

        let markdown = MeetingMarkdownRenderer().renderForClipboard(
            transcription: transcription
        )

        XCTAssertEqual(
            markdown,
            """
            # Design Review

            ## Transcript

            **Dana**

            Ship it.

            """
        )
    }
}
