import GRDB
import XCTest
@testable import MacParakeetCore

final class SpeakerAttributionReadServiceTests: XCTestCase {
    func testNoCorrectionsPreservesTranscriptionAndRendererParity() throws {
        let manager = try DatabaseManager()
        let transcription = fixture()
        try TranscriptionRepository(dbQueue: manager.dbQueue).save(transcription)
        let projection = try XCTUnwrap(
            SpeakerAttributionReadService(dbQueue: manager.dbQueue)
                .resolve(transcriptionId: transcription.id)
        )
        let effective = projection.effectiveTranscription
        let exporter = ExportService()

        XCTAssertFalse(projection.correctionsApplied)
        XCTAssertEqual(projection.correctionRevision, 0)
        XCTAssertEqual(effective.wordTimestamps, transcription.wordTimestamps)
        XCTAssertEqual(effective.speakers, transcription.speakers)
        XCTAssertEqual(effective.diarizationSegments, transcription.diarizationSegments)
        XCTAssertEqual(effective.transcriptSegments, transcription.transcriptSegments)
        XCTAssertEqual(
            exporter.formatSRT(projection: projection),
            exporter.formatSRT(transcription: transcription)
        )
        XCTAssertEqual(
            exporter.formatVTT(projection: projection),
            exporter.formatVTT(transcription: transcription)
        )
        XCTAssertEqual(
            exporter.formatDAPT(projection: projection),
            exporter.formatDAPT(transcription: transcription)
        )
        XCTAssertEqual(
            exporter.formatMarkdown(projection: projection),
            exporter.formatMarkdown(transcription: transcription)
        )
        XCTAssertEqual(
            TranscriptAIContextFormatter.format(projection: projection),
            TranscriptAIContextFormatter.format(transcription: transcription)
        )
    }

    func testCorrectedProjectionFeedsExportsDAPTAndAIContext() throws {
        let manager = try DatabaseManager()
        let transcription = fixture()
        try TranscriptionRepository(dbQueue: manager.dbQueue).save(transcription)
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let wholeRange = TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 4)
        let rightRange = TranscriptSegmentWordRange(startIndex: 2, endIndexExclusive: 4)
        let anchors = try XCTUnwrap(transcription.transcriptSegments?.map(\.id))
        let wholeTarget = SpeakerCorrectionTarget(
            anchorTranscriptSegmentIDs: anchors,
            wordRange: wholeRange
        )
        let rightTarget = SpeakerCorrectionTarget(
            anchorTranscriptSegmentIDs: anchors,
            wordRange: rightRange
        )
        let split = SpeakerCorrection(
            transcriptionId: transcription.id,
            parentId: nil,
            sequence: 1,
            transcriptFingerprint: fingerprint,
            payload: .split(target: wholeTarget, atWordIndex: 2)
        )
        let manualSpeakerID = "user:\(UUID().uuidString)"
        let assign = SpeakerCorrection(
            transcriptionId: transcription.id,
            parentId: split.id,
            sequence: 2,
            transcriptFingerprint: fingerprint,
            payload: .add(
                speaker: ManualSpeaker(id: manualSpeakerID, label: "Alice"),
                assigning: [rightTarget]
            )
        )
        let state = SpeakerCorrectionState(
            transcriptionId: transcription.id,
            transcriptFingerprint: fingerprint.rawValue,
            headId: assign.id,
            revision: 2
        )
        try manager.dbQueue.write { db in
            try split.insert(db)
            try assign.insert(db)
            try state.insert(db)
        }

        let projection = try XCTUnwrap(
            SpeakerAttributionReadService(dbQueue: manager.dbQueue)
                .resolve(transcriptionId: transcription.id)
        )
        let effective = projection.effectiveTranscription
        let exporter = ExportService()

        XCTAssertTrue(projection.correctionsApplied)
        XCTAssertEqual(projection.correctionRevision, 2)
        XCTAssertEqual(
            effective.wordTimestamps?.map(\.speakerId),
            [
                "S1", "S1", manualSpeakerID, manualSpeakerID,
            ])
        XCTAssertEqual(effective.speakers?.last, SpeakerInfo(id: manualSpeakerID, label: "Alice"))
        XCTAssertEqual(effective.speakerCount, 3)
        XCTAssertEqual(effective.transcriptSegments?.first?.speakerId, nil)
        XCTAssertEqual(effective.transcriptSegments?.first?.speakerLabel, "Multiple speakers")

        let srt = exporter.formatSRT(projection: projection)
        XCTAssertTrue(srt.contains("Speaker 1: one two"))
        XCTAssertTrue(srt.contains("Alice: three four"))

        let vtt = exporter.formatVTT(projection: projection)
        XCTAssertTrue(vtt.contains("<v Speaker 1>one two</v>"))
        XCTAssertTrue(vtt.contains("<v Alice>three four</v>"))

        let plainText = exporter.formatPlainText(projection: projection)
        XCTAssertTrue(plainText.contains("Speaker 1:"))
        XCTAssertTrue(plainText.contains("Alice:"))

        let markdown = exporter.formatMarkdown(projection: projection)
        XCTAssertTrue(markdown.contains("**Speaker 1**"))
        XCTAssertTrue(markdown.contains("**Alice**"))

        let dapt = DAPTDocumentRenderer.render(projection: projection)
        XCTAssertTrue(dapt.contains("<ttm:name type=\"alias\">Speaker 1</ttm:name>"))
        XCTAssertTrue(dapt.contains("<ttm:name type=\"alias\">Alice</ttm:name>"))

        let context = TranscriptAIContextFormatter.format(projection: projection)
        XCTAssertTrue(context.contains("Speaker 1: one two"))
        XCTAssertTrue(context.contains("Alice: three four"))

        XCTAssertEqual(transcription.wordTimestamps?.map(\.speakerId), ["S1", "S1", "S1", "S1"])
        XCTAssertEqual(transcription.transcriptSegments?.first?.speakerId, "S1")
    }

    private func fixture() -> Transcription {
        let words = [
            WordTimestamp(word: "one", startMs: 0, endMs: 150, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: "two", startMs: 200, endMs: 350, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: "three", startMs: 400, endMs: 550, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: "four", startMs: 600, endMs: 750, confidence: 0.9, speakerId: "S1"),
        ]
        let speakers = [
            SpeakerInfo(id: "S1", label: "Speaker 1"),
            SpeakerInfo(id: "S2", label: "Speaker 2"),
        ]
        return Transcription(
            fileName: "fixture.wav",
            wordTimestamps: words,
            speakerCount: speakers.count,
            speakers: speakers,
            diarizationSegments: [
                .init(speakerId: "S1", startMs: 0, endMs: 750)
            ],
            transcriptSegments: [
                TranscriptSegmentRecord(
                    startMs: 0,
                    endMs: 750,
                    speakerId: "S1",
                    speakerLabel: "Speaker 1",
                    text: "one two three four",
                    wordRange: .init(startIndex: 0, endIndexExclusive: 4)
                )
            ],
            status: .completed
        )
    }
}
