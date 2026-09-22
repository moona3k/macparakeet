import GRDB
import XCTest
@testable import MacParakeetCore

final class SpeakerParityRegressionTests: XCTestCase {
    func testAutomaticNilWordInheritsSpeakerWhileExplicitUnassignmentStaysUnassigned() async throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)
        let service = SpeakerCorrectionService(dbQueue: db.dbQueue)
        let reader = SpeakerAttributionReadService(dbQueue: db.dbQueue)
        let row = fixture()
        try repo.save(row)
        _ = try await service.apply(
            transcriptionId: row.id, command: .rename(speakerID: "S1", label: "Alice"),
            expectedFingerprint: SpeakerAttributionResolver.fingerprint(for: row), expectedRevision: 0
        )
        let renamed = try reader.resolve(transcription: row)
        XCTAssertEqual(renamed.attribution.editableSegments.map(\.assignment), [.speaker(id: "S1")])
        XCTAssertEqual(renamed.attribution.words.map(\.speakerId), ["S1", "S1", "S1"])
        XCTAssertNil(renamed.attribution.provenanceByWord[1].automaticSpeakerID)
        XCTAssertNil(try repo.fetch(id: row.id)?.wordTimestamps?[1].speakerId)
        _ = try await service.apply(
            transcriptionId: row.id,
            command: .assign(targets: [.init(
                anchorTranscriptSegmentIDs: row.transcriptSegments!.map(\.id),
                wordRange: .init(startIndex: 0, endIndexExclusive: 3)
            )], to: .unassigned),
            expectedFingerprint: renamed.attribution.fingerprint, expectedRevision: 1
        )
        let assigned = try reader.resolve(transcription: row)
        XCTAssertEqual(assigned.attribution.editableSegments.map(\.assignment), [.unassigned])
        XCTAssertNil(assigned.attribution.words[1].speakerId)
    }

    func testCurrentFingerprintReadDoesNotDecodeRetiredPayloads() throws {
        let db = try DatabaseManager()
        let row = fixture()
        try TranscriptionRepository(dbQueue: db.dbQueue).save(row)
        let old = SpeakerCorrection(
            transcriptionId: row.id, parentId: nil, sequence: 1,
            transcriptFingerprint: .init(rawValue: "retired"),
            payload: .rename(speakerID: "S1", label: "Old")
        )
        let current = SpeakerCorrection(
            transcriptionId: row.id, parentId: nil, sequence: 2,
            transcriptFingerprint: .init(rawValue: "current"),
            payload: .rename(speakerID: "S1", label: "Current")
        )
        try db.dbQueue.write { database in
            try old.insert(database)
            try current.insert(database)
            try database.execute(sql: "UPDATE speaker_corrections SET payload = ? WHERE transcriptFingerprint = ?",
                                 arguments: ["unsupported retired payload", "retired"])
            let history = try SpeakerCorrectionRepository.fetchHistory(
                transcriptionId: row.id, fingerprint: "current", in: database
            )
            XCTAssertEqual(history.map(\.id), [current.id])
        }
    }

    func testRetrievalTimestampsExcludeBlankEdgeWords() {
        var row = fixture()
        row.wordTimestamps = [
            .init(word: "  ", startMs: 0, endMs: 50, confidence: 1, speakerId: "S1"),
            .init(word: "Actual", startMs: 100, endMs: 200, confidence: 1, speakerId: "S1"),
            .init(word: "text", startMs: 250, endMs: 350, confidence: 1, speakerId: "S1"),
            .init(word: "\n", startMs: 400, endMs: 450, confidence: 1, speakerId: "S1")
        ]
        row.transcriptSegments = [.init(
            startMs: 0, endMs: 450, speakerId: "S1", speakerLabel: "Speaker 1", text: "Actual text",
            wordRange: .init(startIndex: 0, endIndexExclusive: 4)
        )]
        let segments = KnowledgeSegmenter.deriveSegments(
            for: row, effectiveAttribution: SpeakerAttributionResolver.resolve(transcription: row)
        )
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.text, "Actual text")
        XCTAssertEqual(segments.first?.startMs, 100)
        XCTAssertEqual(segments.first?.endMs, 350)
    }

    private func fixture() -> Transcription {
        let words: [WordTimestamp] = [
            .init(word: "One", startMs: 0, endMs: 100, confidence: 1, speakerId: "S1"),
            .init(word: "two", startMs: 150, endMs: 250, confidence: 1, speakerId: nil),
            .init(word: "three.", startMs: 300, endMs: 400, confidence: 1, speakerId: "S1")
        ]
        let speakers = [SpeakerInfo(id: "S1", label: "Speaker 1")]
        return Transcription(
            fileName: "Speaker parity", rawTranscript: "One two three.", wordTimestamps: words,
            speakers: speakers, transcriptSegments: TranscriptSegmenter.materializeSegments(words: words, speakers: speakers),
            status: .completed, sourceType: .meeting
        )
    }
}
