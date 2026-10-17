import XCTest
@testable import MacParakeetCore

final class TranscriptTranslationRepositoryTests: XCTestCase {
    var repo: TranscriptTranslationRepository!
    var transcriptionRepo: TranscriptionRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = TranscriptTranslationRepository(dbQueue: manager.dbQueue)
        transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
    }

    private func makeTranscription() throws -> Transcription {
        let transcription = Transcription(fileName: "test.mp3", status: .completed)
        try transcriptionRepo.save(transcription)
        return transcription
    }

    private func makeTranslation(
        for transcription: Transcription,
        language: TranslationLanguage,
        text: String
    ) -> TranscriptTranslation {
        TranscriptTranslation(
            transcriptionId: transcription.id,
            languageCode: language.rawValue,
            segments: [TranslatedSegment(startMs: 0, endMs: 1200, speakerId: "S1", text: text)],
            sourceHash: "hash",
            modelName: "test-model"
        )
    }

    func testSaveAndFetchRoundTripsSegments() throws {
        let transcription = try makeTranscription()
        let translation = makeTranslation(for: transcription, language: .persian, text: "سلام دنیا")
        try repo.save(translation)

        let fetched = try XCTUnwrap(repo.fetch(transcriptionId: transcription.id, languageCode: "fa"))
        XCTAssertEqual(fetched.id, translation.id)
        XCTAssertEqual(fetched.segments, translation.segments)
        XCTAssertEqual(fetched.modelName, "test-model")
        XCTAssertEqual(fetched.language, .persian)
    }

    func testSaveReplacesExistingTranslationForSameLanguage() throws {
        let transcription = try makeTranscription()
        try repo.save(makeTranslation(for: transcription, language: .german, text: "Alt"))
        let replacement = makeTranslation(for: transcription, language: .german, text: "Neu")
        try repo.save(replacement)

        let all = try repo.fetchAll(transcriptionId: transcription.id)
        XCTAssertEqual(all.map(\.id), [replacement.id])
        XCTAssertEqual(all.first?.segments.first?.text, "Neu")
    }

    func testLanguagesAreStoredIndependently() throws {
        let transcription = try makeTranscription()
        try repo.save(makeTranslation(for: transcription, language: .german, text: "Hallo"))
        try repo.save(makeTranslation(for: transcription, language: .english, text: "Hello"))

        XCTAssertEqual(try repo.fetchAll(transcriptionId: transcription.id).count, 2)
        XCTAssertNil(try repo.fetch(transcriptionId: transcription.id, languageCode: "fa"))
    }

    func testDeleteRemovesOnlyThatTranslation() throws {
        let transcription = try makeTranscription()
        let german = makeTranslation(for: transcription, language: .german, text: "Hallo")
        try repo.save(german)
        try repo.save(makeTranslation(for: transcription, language: .english, text: "Hello"))

        XCTAssertTrue(try repo.delete(id: german.id))
        XCTAssertEqual(try repo.fetchAll(transcriptionId: transcription.id).map(\.languageCode), ["en"])
    }

    func testDeletingTranscriptionCascadesToTranslations() throws {
        let transcription = try makeTranscription()
        try repo.save(makeTranslation(for: transcription, language: .german, text: "Hallo"))

        XCTAssertTrue(try transcriptionRepo.delete(id: transcription.id))
        XCTAssertTrue(try repo.fetchAll(transcriptionId: transcription.id).isEmpty)
    }
}
