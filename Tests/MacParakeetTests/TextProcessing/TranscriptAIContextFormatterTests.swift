import XCTest
@testable import MacParakeetCore

final class TranscriptAIContextFormatterTests: XCTestCase {
    func testRichTranscriptIncludesTimestampsAndSpeakerLabels() {
        let transcription = Transcription(
            fileName: "meeting.wav",
            rawTranscript: "Hello there. Thanks.",
            cleanTranscript: "Hello there. Thanks.",
            wordTimestamps: [
                WordTimestamp(word: "Hello", startMs: 0, endMs: 400, confidence: 0.99, speakerId: "microphone"),
                WordTimestamp(word: "there.", startMs: 450, endMs: 900, confidence: 0.98, speakerId: "microphone"),
                WordTimestamp(word: "Thanks.", startMs: 2_000, endMs: 2_400, confidence: 0.97, speakerId: "system")
            ],
            speakers: [
                SpeakerInfo(id: "microphone", label: "Me"),
                SpeakerInfo(id: "system", label: "Others")
            ],
            status: .completed,
            sourceType: .meeting
        )

        let formatted = TranscriptAIContextFormatter.format(
            transcription: transcription,
            mode: .richTranscript
        )

        XCTAssertEqual(
            formatted,
            """
            [0:00] Me: Hello there.
            [0:02] Others: Thanks.
            """
        )
    }

    func testRichTranscriptFallsBackToSpeakerIdWhenSpeakerMapIsMissing() {
        let transcription = Transcription(
            fileName: "meeting.wav",
            rawTranscript: "Hello there.",
            cleanTranscript: "Hello there.",
            wordTimestamps: [
                WordTimestamp(word: "Hello", startMs: 0, endMs: 400, confidence: 0.99, speakerId: "microphone"),
                WordTimestamp(word: "there.", startMs: 450, endMs: 900, confidence: 0.98, speakerId: "microphone")
            ],
            speakers: nil,
            status: .completed,
            sourceType: .meeting
        )

        let formatted = TranscriptAIContextFormatter.format(
            transcription: transcription,
            mode: .richTranscript
        )

        XCTAssertEqual(formatted, "[0:00] microphone: Hello there.")
    }

    func testPlainTranscriptUsesCleanTextWithoutTimingOrSpeakerLabels() {
        let transcription = Transcription(
            fileName: "meeting.wav",
            rawTranscript: "raw",
            cleanTranscript: "  Clean transcript\n",
            wordTimestamps: [
                WordTimestamp(word: "Clean", startMs: 0, endMs: 200, confidence: 0.9, speakerId: "speaker-1")
            ],
            speakers: [SpeakerInfo(id: "speaker-1", label: "Speaker 1")],
            status: .completed,
            sourceType: .meeting
        )

        let formatted = TranscriptAIContextFormatter.format(
            transcription: transcription,
            mode: .plainTranscript
        )

        XCTAssertEqual(formatted, "Clean transcript")
    }

    func testRichTranscriptFallsBackToPreferredTextWhenNoTimestampsExist() {
        let transcription = Transcription(
            fileName: "audio.wav",
            rawTranscript: "  Raw fallback\n",
            cleanTranscript: nil,
            wordTimestamps: nil,
            status: .completed
        )

        let formatted = TranscriptAIContextFormatter.format(
            transcription: transcription,
            mode: .richTranscript
        )

        XCTAssertEqual(formatted, "Raw fallback")
    }

    func testEditedTranscriptUsesEditedTextEvenInRichMode() {
        let transcription = Transcription(
            fileName: "meeting.wav",
            rawTranscript: "Old raw",
            cleanTranscript: "Edited transcript",
            wordTimestamps: [
                WordTimestamp(word: "Old", startMs: 0, endMs: 300, confidence: 0.9, speakerId: "speaker-1")
            ],
            speakers: [SpeakerInfo(id: "speaker-1", label: "Speaker 1")],
            status: .completed,
            sourceType: .meeting,
            isTranscriptEdited: true
        )

        let formatted = TranscriptAIContextFormatter.format(
            transcription: transcription,
            mode: .richTranscript
        )

        XCTAssertEqual(formatted, "Edited transcript")
    }

    func testSegmentTimedCorrectionUsesCorrectedLineEnvelopeAndPreservesUntouchedWordTiming() {
        let transcription = Transcription(
            fileName: "meeting.wav",
            rawTranscript: "Old greeting. Later words.",
            cleanTranscript: "Corrected greeting. Later words.",
            wordTimestamps: [
                WordTimestamp(word: "Old", startMs: 0, endMs: 200, confidence: 1, speakerId: "S1"),
                WordTimestamp(word: "greeting.", startMs: 220, endMs: 500, confidence: 1, speakerId: "S1"),
                WordTimestamp(word: "Later", startMs: 2_000, endMs: 2_200, confidence: 1, speakerId: "S2"),
                WordTimestamp(word: "words.", startMs: 2_220, endMs: 2_500, confidence: 1, speakerId: "S2"),
            ],
            speakers: [
                SpeakerInfo(id: "S1", label: "Alice"),
                SpeakerInfo(id: "S2", label: "Bob"),
            ],
            transcriptSegments: [
                TranscriptSegmentRecord(
                    startMs: 0,
                    endMs: 500,
                    speakerId: "S1",
                    speakerLabel: "Alice",
                    text: "Corrected greeting.",
                    wordRange: .init(startIndex: 0, endIndexExclusive: 2),
                    isTextEdited: true
                ),
                TranscriptSegmentRecord(
                    startMs: 2_000,
                    endMs: 2_500,
                    speakerId: "S2",
                    speakerLabel: "Bob",
                    text: "Later words.",
                    wordRange: .init(startIndex: 2, endIndexExclusive: 4)
                ),
            ],
            status: .completed,
            sourceType: .meeting
        )

        let formatted = TranscriptAIContextFormatter.format(transcription: transcription)

        XCTAssertEqual(
            formatted,
            """
            [0:00] Alice: Corrected greeting.
            [0:02] Bob: Later words.
            """
        )
        XCTAssertFalse(formatted.contains("Old greeting"))
    }
}
