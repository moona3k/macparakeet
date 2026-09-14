import GRDB
import XCTest
@testable import MacParakeetCore

final class SpeakerAttributionReadServiceTests: XCTestCase {
    func testEffectiveTranscriptionReturnsStoredValueWithoutActiveCorrections() throws {
        let manager = try DatabaseManager()
        let transcription = fixture()
        try TranscriptionRepository(dbQueue: manager.dbQueue).save(transcription)

        let effective = try SpeakerAttributionReadService(dbQueue: manager.dbQueue)
            .effectiveTranscription(for: transcription)

        XCTAssertEqual(effective.id, transcription.id)
        XCTAssertEqual(effective.rawTranscript, transcription.rawTranscript)
        XCTAssertEqual(effective.cleanTranscript, transcription.cleanTranscript)
        XCTAssertEqual(effective.wordTimestamps, transcription.wordTimestamps)
        XCTAssertEqual(effective.speakers, transcription.speakers)
        XCTAssertEqual(effective.diarizationSegments, transcription.diarizationSegments)
        XCTAssertEqual(effective.transcriptSegments, transcription.transcriptSegments)
        XCTAssertEqual(effective.isTranscriptEdited, transcription.isTranscriptEdited)
        XCTAssertNil(
            try SpeakerCorrectionRepository(dbQueue: manager.dbQueue)
                .fetchState(transcriptionId: transcription.id)
        )
    }

    func testTextOnlyCorrectionPublishesOneSegmentTimedTranscript() async throws {
        let manager = try DatabaseManager()
        let transcription = fixture()
        try TranscriptionRepository(dbQueue: manager.dbQueue).save(transcription)
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        let target = SpeakerCorrectionTarget(
            anchorTranscriptSegmentIDs: try XCTUnwrap(transcription.transcriptSegments?.map(\.id)),
            wordRange: .init(startIndex: 0, endIndexExclusive: 4)
        )

        _ = try await SpeakerCorrectionService(dbQueue: manager.dbQueue).apply(
            transcriptionId: transcription.id,
            command: .editText(target: target, text: "A corrected sentence."),
            expectedFingerprint: fingerprint,
            expectedRevision: 0
        )

        let reader = SpeakerAttributionReadService(dbQueue: manager.dbQueue)
        let first = try XCTUnwrap(reader.resolve(transcriptionId: transcription.id))
        let second = try XCTUnwrap(reader.resolve(transcriptionId: transcription.id))
        let effective = first.effectiveTranscription
        XCTAssertEqual(effective.cleanTranscript, "A corrected sentence.")
        XCTAssertEqual(effective.transcriptTextAlignment, .segment)
        XCTAssertEqual(effective.transcriptSegments?.map(\.text), ["A corrected sentence."])
        XCTAssertEqual(effective.transcriptSegments?.first?.isTextEdited, true)
        XCTAssertEqual(
            effective.transcriptSegments?.first?.id,
            transcription.transcriptSegments?.first?.id
        )
        XCTAssertNil(effective.transcriptSegments?.first?.anchorTranscriptSegmentIDs)
        XCTAssertEqual(
            effective.transcriptSegments?.map(\.id),
            second.effectiveTranscription.transcriptSegments?.map(\.id)
        )
        XCTAssertEqual(effective.rawTranscript, transcription.rawTranscript)
        XCTAssertEqual(effective.wordTimestamps, transcription.wordTimestamps)
    }

    func testMergedCorrectionPublishesNewIDWithDurableAnchors() async throws {
        let manager = try DatabaseManager()
        var transcription = fixture()
        var words = try XCTUnwrap(transcription.wordTimestamps)
        words[2].startMs = 2_000
        words[2].endMs = 2_150
        words[3].startMs = 2_200
        words[3].endMs = 2_350
        transcription.wordTimestamps = words
        transcription.transcriptSegments = [
            TranscriptSegmentRecord(
                startMs: words[0].startMs,
                endMs: words[1].endMs,
                speakerId: "S1",
                speakerLabel: "Speaker 1",
                text: "one two",
                wordRange: .init(startIndex: 0, endIndexExclusive: 2)
            ),
            TranscriptSegmentRecord(
                startMs: words[2].startMs,
                endMs: words[3].endMs,
                speakerId: "S1",
                speakerLabel: "Speaker 1",
                text: "three four",
                wordRange: .init(startIndex: 2, endIndexExclusive: 4)
            ),
        ]
        try TranscriptionRepository(dbQueue: manager.dbQueue).save(transcription)
        let automaticIDs = try XCTUnwrap(transcription.transcriptSegments?.map(\.id))
        let targets = SpeakerAttributionResolver.resolve(transcription: transcription)
            .editableSegments.map {
                SpeakerCorrectionTarget(
                    anchorTranscriptSegmentIDs: $0.anchorTranscriptSegmentIDs,
                    wordRange: $0.wordRange
                )
            }
        _ = try await SpeakerCorrectionService(dbQueue: manager.dbQueue).apply(
            transcriptionId: transcription.id,
            command: .mergeSegments(targets: targets),
            expectedFingerprint: SpeakerAttributionResolver.fingerprint(for: transcription),
            expectedRevision: 0
        )

        let projection = try XCTUnwrap(
            SpeakerAttributionReadService(dbQueue: manager.dbQueue)
                .resolve(transcriptionId: transcription.id)
        )
        let segment = try XCTUnwrap(projection.effectiveTranscription.transcriptSegments?.first)
        XCTAssertFalse(automaticIDs.contains(segment.id))
        XCTAssertEqual(segment.anchorTranscriptSegmentIDs, automaticIDs)
    }

    func testNoCorrectionsPreservesNilSpeakerGapsInExportedProjection() throws {
        let manager = try DatabaseManager()
        var transcription = fixture()
        transcription.wordTimestamps?[1].speakerId = nil
        try TranscriptionRepository(dbQueue: manager.dbQueue).save(transcription)
        let projection = try XCTUnwrap(
            SpeakerAttributionReadService(dbQueue: manager.dbQueue)
                .resolve(transcriptionId: transcription.id)
        )

        XCTAssertFalse(projection.correctionsApplied)
        // Timed display may inherit automatic gaps, but exported evidence must
        // remain the untouched automatic transcript without active corrections.
        XCTAssertEqual(projection.attribution.words[1].speakerId, "S1")
        XCTAssertNil(projection.effectiveTranscription.wordTimestamps?[1].speakerId)
        XCTAssertEqual(projection.effectiveTranscription.transcriptSegments, transcription.transcriptSegments)
        let exporter = ExportService()
        XCTAssertEqual(exporter.formatSRT(projection: projection), exporter.formatSRT(transcription: transcription))
        XCTAssertEqual(exporter.formatDAPT(projection: projection), exporter.formatDAPT(transcription: transcription))
    }

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
