import XCTest
@testable import MacParakeetCore

final class PromptResultRepositoryTests: XCTestCase {
    var manager: DatabaseManager!
    var repo: PromptResultRepository!
    var transcriptionRepo: TranscriptionRepository!

    override func setUp() async throws {
        manager = try DatabaseManager()
        repo = PromptResultRepository(dbQueue: manager.dbQueue)
        transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
    }

    private func makeTranscription() throws -> Transcription {
        let transcription = Transcription(fileName: "test.mp3", status: .completed)
        try transcriptionRepo.save(transcription)
        return transcription
    }

    func testSaveAndFetchAllOrdersNewestFirst() throws {
        let transcription = try makeTranscription()
        let older = PromptResult(
            transcriptionId: transcription.id,
            promptName: "General Summary",
            promptContent: Prompt.defaultPrompt.content,
            content: "Older",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Action Items",
            promptContent: "Action items only.",
            content: "Newer",
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        try repo.save(older)
        try repo.save(newer)

        let fetched = try repo.fetchAll(transcriptionId: transcription.id)
        XCTAssertEqual(fetched.map(\.content), ["Newer", "Older"])
    }

    func testPromptExecutionProvenanceRoundTrips() throws {
        let transcription = try makeTranscription()
        let promptRepo = PromptRepository(dbQueue: manager.dbQueue)
        let prompt = Prompt(
            name: "Provenance \(UUID().uuidString)",
            content: "Summarize this.",
            modelOverride: "requested-model"
        )
        try promptRepo.save(prompt)
        let storedPrompt = try XCTUnwrap(promptRepo.fetch(id: prompt.id))
        let versionID = try XCTUnwrap(storedPrompt.activeVersionId)
        let result = PromptResult(
            transcriptionId: transcription.id,
            promptId: storedPrompt.id,
            promptVersionId: versionID,
            promptName: storedPrompt.name,
            promptContent: storedPrompt.content,
            content: "Summary",
            providerSnapshot: "openai",
            modelSnapshot: "gpt-test"
        )

        try repo.save(result)

        let fetched = try XCTUnwrap(repo.fetchAll(transcriptionId: transcription.id).first)
        XCTAssertEqual(fetched.promptId, storedPrompt.id)
        XCTAssertEqual(fetched.promptVersionId, versionID)
        XCTAssertEqual(fetched.providerSnapshot, "openai")
        XCTAssertEqual(fetched.modelSnapshot, "gpt-test")
    }

    func testInferenceSettingsSnapshotRoundTripAndDefaultNormalization() throws {
        let transcription = try makeTranscription()
        var result = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Configured Summary",
            promptContent: "Summarize this.",
            content: "Summary",
            inferenceSettingsSnapshot: PromptInferenceSettings(
                temperature: 0.2,
                topP: 0.9,
                topK: 20,
                maxTokens: 4096,
                thinkingMode: .enabled,
                reasoningEffort: .medium
            )
        )
        try repo.save(result)
        XCTAssertEqual(
            try repo.fetchAll(transcriptionId: transcription.id).first?.inferenceSettingsSnapshot,
            result.inferenceSettingsSnapshot
        )

        result.inferenceSettingsSnapshot = PromptInferenceSettings()
        try repo.save(result)
        XCTAssertNil(
            try repo.fetchAll(transcriptionId: transcription.id).first?.inferenceSettingsSnapshot
        )
        let storedJSON = try manager.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT inferenceSettingsSnapshot FROM summaries WHERE id = ?",
                arguments: [result.id]
            )
        }
        XCTAssertNil(storedJSON)
    }

    func testMalformedInferenceSettingsSnapshotIsAVisibleFetchError() throws {
        let transcription = try makeTranscription()
        let result = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Malformed Settings",
            promptContent: "Summarize this.",
            content: "Summary"
        )
        try repo.save(result)

        try manager.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE summaries SET inferenceSettingsSnapshot = ? WHERE id = ?",
                arguments: ["{not-json", result.id]
            )
        }

        XCTAssertThrowsError(try repo.fetchAll(transcriptionId: transcription.id))
    }

    func testMultiplePromptResultsPerTranscription() throws {
        let transcription = try makeTranscription()
        try repo.save(
            PromptResult(
                transcriptionId: transcription.id,
                promptName: "General Summary",
                promptContent: Prompt.defaultPrompt.content,
                content: "One"
            )
        )
        try repo.save(
            PromptResult(
                transcriptionId: transcription.id,
                promptName: "Action Items",
                promptContent: "Action items only.",
                content: "Two"
            )
        )

        XCTAssertEqual(try repo.fetchAll(transcriptionId: transcription.id).count, 2)
        XCTAssertEqual(try repo.count(transcriptionId: transcription.id), 2)
        XCTAssertEqual(try repo.counts(transcriptionIds: [transcription.id])[transcription.id], 2)
        XCTAssertTrue(try repo.hasPromptResults(transcriptionId: transcription.id))
    }

    func testDeleteSinglePromptResult() throws {
        let transcription = try makeTranscription()
        let promptResult = PromptResult(
            transcriptionId: transcription.id,
            promptName: "General Summary",
            promptContent: Prompt.defaultPrompt.content,
            content: "Delete me"
        )
        try repo.save(promptResult)

        XCTAssertTrue(try repo.delete(id: promptResult.id))
        XCTAssertTrue(try repo.fetchAll(transcriptionId: transcription.id).isEmpty)
    }

    func testDeleteAllForTranscription() throws {
        let transcription = try makeTranscription()
        try repo.save(
            PromptResult(
                transcriptionId: transcription.id,
                promptName: "General Summary",
                promptContent: Prompt.defaultPrompt.content,
                content: "One"
            )
        )
        try repo.save(
            PromptResult(
                transcriptionId: transcription.id,
                promptName: "Action Items",
                promptContent: "Action items only.",
                content: "Two"
            )
        )

        try repo.deleteAll(transcriptionId: transcription.id)

        XCTAssertFalse(try repo.hasPromptResults(transcriptionId: transcription.id))
    }

    func testCascadeDeleteOnTranscriptionRemoval() throws {
        let transcription = try makeTranscription()
        try repo.save(
            PromptResult(
                transcriptionId: transcription.id,
                promptName: "General Summary",
                promptContent: Prompt.defaultPrompt.content,
                content: "One"
            )
        )

        _ = try transcriptionRepo.delete(id: transcription.id)

        XCTAssertFalse(try repo.hasPromptResults(transcriptionId: transcription.id))
        XCTAssertEqual(try repo.count(transcriptionId: transcription.id), 0)
        XCTAssertEqual(try repo.counts(transcriptionIds: [transcription.id])[transcription.id] ?? 0, 0)
    }
}
