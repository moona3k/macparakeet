import Foundation
import GRDB
import XCTest
@testable import MacParakeetCore

final class SpeakerVoiceprintExportTests: XCTestCase {
    func testPopulatedVoiceprintTablesDoNotEnterTranscriptExports() async throws {
        let database = try DatabaseManager()
        let transcriptions = TranscriptionRepository(dbQueue: database.dbQueue)
        let profiles = SpeakerProfileRepository(dbQueue: database.dbQueue)
        let service = SpeakerVoiceprintService(
            profiles: profiles,
            candidates: SpeakerEmbeddingCandidateRepository(dbQueue: database.dbQueue),
            journal: SpeakerMatchJournalRepository(dbQueue: database.dbQueue),
            isEnabled: { true }
        )
        let enrollment = Transcription(fileName: "enrollment.wav", status: .completed)
        let meeting = Transcription(
            fileName: "meeting.wav", rawTranscript: "Hello from the meeting.",
            speakerCount: 1, speakers: [SpeakerInfo(id: "system:S1", label: "Others 1")],
            status: .completed
        )
        try transcriptions.save(enrollment)
        try transcriptions.save(meeting)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceprint-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let exporter = ExportService()
        try exporter.exportToJSON(transcription: meeting, url: output)
        let before = try Data(contentsOf: output)
        var vector = [Float](repeating: 0, count: 256)
        vector[0] = 1
        let embedding = try XCTUnwrap(
            SpeakerEmbedding(
                rawVector: vector,
                identity: SpeakerModelIdentity(
                    embeddingModelId: "private-model", aggregationProfileId: "private-config")
            ))
        let observation = SpeakerClusterObservation(
            speakerId: "system:S1", embedding: embedding, speechSeconds: 30, captureDomain: .system
        )
        _ = try await service.enroll(
            displayName: "VoiceprintOnlyName", observation: observation,
            transcriptionId: enrollment.id,
            fingerprint: SpeakerAttributionResolver.fingerprint(for: enrollment),
            allowMergeIntoExistingName: false
        )
        let suggestions = try await service.evaluate(
            transcriptionId: meeting.id,
            fingerprint: SpeakerAttributionResolver.fingerprint(for: meeting), clusters: [observation]
        )
        XCTAssertEqual(suggestions.count, 1)
        try await database.dbQueue.read { db in
            for table in [
                "speaker_profiles", "speaker_profile_exemplars", "speaker_profile_links",
                "speaker_match_journal", "speaker_embedding_candidates",
            ] {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"), 1, table)
            }
        }
        try exporter.exportToJSON(transcription: meeting, url: output)
        XCTAssertEqual(try Data(contentsOf: output), before)
        let rendered = [
            String(decoding: before, as: UTF8.self), exporter.formatPlainText(transcription: meeting),
            exporter.formatMarkdown(transcription: meeting), exporter.formatSRT(transcription: meeting),
            exporter.formatVTT(transcription: meeting), exporter.formatDAPT(transcription: meeting),
        ]
        for text in rendered {
            for secret in [
                "VoiceprintOnlyName", "private-model", "private-config", suggestions[0].profileId.uuidString,
            ] {
                XCTAssertFalse(text.contains(secret))
            }
        }
    }
}
