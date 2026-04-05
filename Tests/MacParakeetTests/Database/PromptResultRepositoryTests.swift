import XCTest
@testable import MacParakeetCore

final class PromptResultRepositoryTests: XCTestCase {
    var repo: PromptResultRepository!
    var transcriptionRepo: TranscriptionRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
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
    }
}
