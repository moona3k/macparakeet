import XCTest
@testable import MacParakeetCore

final class SummaryRepositoryTests: XCTestCase {
    var repo: SummaryRepository!
    var transcriptionRepo: TranscriptionRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = SummaryRepository(dbQueue: manager.dbQueue)
        transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
    }

    private func makeTranscription() throws -> Transcription {
        let transcription = Transcription(fileName: "test.mp3", status: .completed)
        try transcriptionRepo.save(transcription)
        return transcription
    }

    func testSaveAndFetchAllOrdersNewestFirst() throws {
        let transcription = try makeTranscription()
        let older = Summary(
            transcriptionId: transcription.id,
            promptName: "Concise Summary",
            promptContent: Prompt.defaultSummaryPrompt.content,
            content: "Older",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = Summary(
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

    func testMultipleSummariesPerTranscription() throws {
        let transcription = try makeTranscription()
        try repo.save(
            Summary(
                transcriptionId: transcription.id,
                promptName: "Concise Summary",
                promptContent: Prompt.defaultSummaryPrompt.content,
                content: "One"
            )
        )
        try repo.save(
            Summary(
                transcriptionId: transcription.id,
                promptName: "Action Items",
                promptContent: "Action items only.",
                content: "Two"
            )
        )

        XCTAssertEqual(try repo.fetchAll(transcriptionId: transcription.id).count, 2)
        XCTAssertTrue(try repo.hasSummaries(transcriptionId: transcription.id))
    }

    func testDeleteSingleSummary() throws {
        let transcription = try makeTranscription()
        let summary = Summary(
            transcriptionId: transcription.id,
            promptName: "Concise Summary",
            promptContent: Prompt.defaultSummaryPrompt.content,
            content: "Delete me"
        )
        try repo.save(summary)

        XCTAssertTrue(try repo.delete(id: summary.id))
        XCTAssertTrue(try repo.fetchAll(transcriptionId: transcription.id).isEmpty)
    }

    func testDeleteAllForTranscription() throws {
        let transcription = try makeTranscription()
        try repo.save(
            Summary(
                transcriptionId: transcription.id,
                promptName: "Concise Summary",
                promptContent: Prompt.defaultSummaryPrompt.content,
                content: "One"
            )
        )
        try repo.save(
            Summary(
                transcriptionId: transcription.id,
                promptName: "Action Items",
                promptContent: "Action items only.",
                content: "Two"
            )
        )

        try repo.deleteAll(transcriptionId: transcription.id)

        XCTAssertFalse(try repo.hasSummaries(transcriptionId: transcription.id))
    }

    func testCascadeDeleteOnTranscriptionRemoval() throws {
        let transcription = try makeTranscription()
        try repo.save(
            Summary(
                transcriptionId: transcription.id,
                promptName: "Concise Summary",
                promptContent: Prompt.defaultSummaryPrompt.content,
                content: "One"
            )
        )

        _ = try transcriptionRepo.delete(id: transcription.id)

        XCTAssertFalse(try repo.hasSummaries(transcriptionId: transcription.id))
    }
}
