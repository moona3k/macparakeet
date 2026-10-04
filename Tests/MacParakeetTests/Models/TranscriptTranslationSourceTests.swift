import XCTest
@testable import MacParakeetCore

final class TranscriptTranslationSourceTests: XCTestCase {
    private func word(_ text: String, _ startMs: Int, speaker: String? = nil) -> WordTimestamp {
        WordTimestamp(word: text, startMs: startMs, endMs: startMs + 300, confidence: 1, speakerId: speaker)
    }

    func testTimedTranscriptProducesTimedSegmentsWithSpeakers() {
        let transcription = Transcription(
            fileName: "meeting",
            rawTranscript: "Hello there friend. Fine thanks.",
            wordTimestamps: [
                word("Hello", 0, speaker: "S1"), word("there", 400, speaker: "S1"), word("friend.", 800, speaker: "S1"),
                word("Fine", 2_000, speaker: "S2"), word("thanks.", 2_400, speaker: "S2"),
            ],
            status: .completed
        )

        let segments = TranscriptTranslationSource.segments(for: transcription)

        XCTAssertEqual(segments.map(\.text), ["Hello there friend.", "Fine thanks."])
        XCTAssertEqual(segments.map(\.speakerId), ["S1", "S2"])
        XCTAssertEqual(segments[0].startMs, 0)
        XCTAssertEqual(segments[0].endMs, 1_100)
        XCTAssertEqual(segments[1].startMs, 2_000)
    }

    func testEditedTranscriptUsesEditedTextWithoutTiming() {
        let transcription = Transcription(
            fileName: "meeting",
            rawTranscript: "Helo there.",
            cleanTranscript: "Hello there.\n\nSecond paragraph.",
            wordTimestamps: [word("Helo", 0), word("there.", 400)],
            status: .completed,
            isTranscriptEdited: true
        )

        let segments = TranscriptTranslationSource.segments(for: transcription)

        XCTAssertEqual(segments.map(\.text), ["Hello there.", "Second paragraph."])
        XCTAssertTrue(segments.allSatisfy { $0.startMs == nil && $0.endMs == nil })
    }

    func testTextCorrectedSegmentsAreTranslatedInsteadOfAutomaticWords() {
        let transcription = Transcription(
            fileName: "meeting",
            rawTranscript: "Helo there friend.",
            wordTimestamps: [
                word("Helo", 0, speaker: "S1"), word("there", 400, speaker: "S1"), word("friend.", 800, speaker: "S1"),
            ],
            transcriptSegments: [
                TranscriptSegmentRecord(
                    startMs: 0,
                    endMs: 1_100,
                    speakerId: "S1",
                    speakerLabel: "Anna",
                    text: "Hello there, friend.",
                    wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 3),
                    isTextEdited: true
                )
            ],
            status: .completed
        )
        XCTAssertEqual(transcription.transcriptTextAlignment, .segment)

        let segments = TranscriptTranslationSource.segments(for: transcription)

        XCTAssertEqual(
            segments,
            [TranslationSourceSegment(startMs: 0, endMs: 1_100, speakerId: "S1", text: "Hello there, friend.")]
        )
    }

    func testLongUntimedParagraphIsSplitIntoBoundedChunks() {
        let sentence = "This is a reasonably long sentence used to fill the paragraph."
        let paragraph = Array(repeating: sentence, count: 30).joined(separator: " ")

        let segments = TranscriptTranslationSource.untimedSegments(from: paragraph)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(
            segments.allSatisfy {
                $0.text.count <= TranscriptTranslationSource.maxUntimedSegmentCharacters + sentence.count
            })
        XCTAssertEqual(segments.map(\.text).joined(separator: " "), paragraph)
    }

    func testEmptyTranscriptProducesNoSegments() {
        let transcription = Transcription(fileName: "empty", rawTranscript: "  \n ", status: .completed)
        XCTAssertTrue(TranscriptTranslationSource.segments(for: transcription).isEmpty)
    }

    func testHashChangesWithTextOnly() {
        let a = [TranslationSourceSegment(startMs: 0, endMs: 10, text: "Hello")]
        let sameTextDifferentTiming = [TranslationSourceSegment(startMs: 5, endMs: 50, text: "Hello")]
        let differentText = [TranslationSourceSegment(startMs: 0, endMs: 10, text: "Hello!")]

        XCTAssertEqual(
            TranscriptTranslationSource.hash(of: a), TranscriptTranslationSource.hash(of: sameTextDifferentTiming))
        XCTAssertNotEqual(TranscriptTranslationSource.hash(of: a), TranscriptTranslationSource.hash(of: differentText))
    }

    func testLanguageResolveAcceptsCodesAndEnglishNames() {
        XCTAssertEqual(TranslationLanguage.resolve("fa"), .persian)
        XCTAssertEqual(TranslationLanguage.resolve(" Persian "), .persian)
        XCTAssertEqual(TranslationLanguage.resolve("german"), .german)
        XCTAssertNil(TranslationLanguage.resolve("Klingon"))
        XCTAssertNil(TranslationLanguage.resolve(nil))
        XCTAssertTrue(TranslationLanguage.persian.isRightToLeft)
        XCTAssertFalse(TranslationLanguage.german.isRightToLeft)
    }

    func testExportFormatsTranslationAsSRTAndPlainText() {
        let translation = TranscriptTranslation(
            transcriptionId: UUID(),
            languageCode: "de",
            segments: [
                TranslatedSegment(startMs: 0, endMs: 1_500, speakerId: "S1", text: "Hallo."),
                TranslatedSegment(startMs: 1_500, endMs: 3_000, speakerId: "S1", text: "Wie geht's?"),
                TranslatedSegment(startMs: 3_000, endMs: 4_000, speakerId: "S2", text: "Gut."),
            ],
            sourceHash: "h"
        )
        let speakers = [SpeakerInfo(id: "S1", label: "Anna"), SpeakerInfo(id: "S2", label: "Ben")]
        let export = ExportService()

        XCTAssertEqual(
            export.formatPlainText(translation: translation, speakers: speakers),
            "Anna: Hallo. Wie geht's?\n\nBen: Gut."
        )
        let srt = export.formatSRT(translation: translation, speakers: speakers)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,000 --> 00:00:01,500\nAnna: Hallo.\n"))
        XCTAssertTrue(srt.contains("3\n00:00:03,000 --> 00:00:04,000\nBen: Gut."))
    }
}
