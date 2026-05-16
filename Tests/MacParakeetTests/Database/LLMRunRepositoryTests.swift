import XCTest
@testable import MacParakeetCore

final class LLMRunRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var repo: LLMRunRepository!
    private var dictationRepo: DictationRepository!
    private var transcriptionRepo: TranscriptionRepository!

    override func setUp() async throws {
        manager = try DatabaseManager()
        repo = LLMRunRepository(dbQueue: manager.dbQueue)
        dictationRepo = DictationRepository(dbQueue: manager.dbQueue)
        transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
    }

    func testSaveAndFetchRecentOrdersNewestFirst() async throws {
        let dictation = Dictation(durationMs: 1000, rawTranscript: "older")
        let transcription = Transcription(fileName: "newer.wav", status: .completed)
        try dictationRepo.save(dictation)
        try transcriptionRepo.save(transcription)

        let older = LLMRun(
            feature: .formatterDictation,
            status: .succeeded,
            source: LLMRunSource(dictationId: dictation.id),
            provider: "ollama",
            model: "qwen3",
            latencyMs: 120,
            inputChars: 10,
            outputChars: 12,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = LLMRun(
            feature: .formatterTranscription,
            status: .failed,
            source: LLMRunSource(transcriptionId: transcription.id),
            provider: "openai",
            model: "gpt-5.1",
            errorType: "rate_limit",
            inputChars: 20,
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        try await repo.save(older)
        try await repo.save(newer)

        let runs = try repo.fetchRecent(limit: 10)
        XCTAssertEqual(runs.map(\.id), [newer.id, older.id])
        XCTAssertEqual(runs.first?.feature, .formatterTranscription)
        XCTAssertEqual(runs.first?.status, .failed)
        XCTAssertEqual(runs.first?.errorType, "rate_limit")
    }

    func testSaveWithoutSourceFailsIntegrityCheck() async throws {
        let run = LLMRun(
            feature: .chat,
            status: .succeeded,
            provider: "openai",
            model: "gpt",
            inputChars: 5
        )

        do {
            try await repo.save(run)
            XCTFail("Expected llm_runs source-link check to reject unlinked rows")
        } catch {
            // Expected.
        }
    }

    func testFetchForDictationUsesSourceLink() async throws {
        let dictation = Dictation(durationMs: 1000, rawTranscript: "hello")
        let transcription = Transcription(fileName: "unrelated.wav", status: .completed)
        try dictationRepo.save(dictation)
        try transcriptionRepo.save(transcription)

        let linked = LLMRun(
            feature: .formatterDictation,
            status: .succeeded,
            source: LLMRunSource(dictationId: dictation.id),
            provider: "lmstudio",
            model: "local-model",
            inputChars: 5
        )
        let unrelated = LLMRun(
            feature: .formatterTranscription,
            status: .succeeded,
            source: LLMRunSource(transcriptionId: transcription.id),
            provider: "openai",
            model: "gpt",
            inputChars: 5
        )
        try await repo.save(linked)
        try await repo.save(unrelated)

        XCTAssertEqual(try repo.fetchForDictation(id: dictation.id).map(\.id), [linked.id])
    }

    func testDeletingDictationCascadesRuns() async throws {
        let dictation = Dictation(durationMs: 1000, rawTranscript: "hello")
        try dictationRepo.save(dictation)
        try await repo.save(LLMRun(
            feature: .formatterDictation,
            status: .succeeded,
            source: LLMRunSource(dictationId: dictation.id),
            provider: "ollama",
            model: "qwen",
            inputChars: 5
        ))

        XCTAssertEqual(try repo.count(), 1)
        _ = try dictationRepo.delete(id: dictation.id)

        XCTAssertEqual(try repo.count(), 0)
    }

    func testDeletingTranscriptionCascadesRuns() async throws {
        let transcription = Transcription(fileName: "sample.wav", status: .completed)
        try transcriptionRepo.save(transcription)
        try await repo.save(LLMRun(
            feature: .formatterTranscription,
            status: .succeeded,
            source: LLMRunSource(transcriptionId: transcription.id),
            provider: "ollama",
            model: "qwen",
            inputChars: 5
        ))

        XCTAssertEqual(try repo.count(), 1)
        _ = try transcriptionRepo.delete(id: transcription.id)

        XCTAssertEqual(try repo.count(), 0)
    }
}
