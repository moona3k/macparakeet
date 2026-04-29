import XCTest
@testable import MacParakeetCore

final class DerivedFieldsBackfillServiceTests: XCTestCase {
    private func makeRepo() throws -> (DatabaseManager, TranscriptionRepository) {
        let manager = try DatabaseManager()
        return (manager, TranscriptionRepository(dbQueue: manager.dbQueue))
    }

    func testEmptyTranscriptRowDoesNotLoopForever() throws {
        let (manager, repo) = try makeRepo()
        try repo.save(Transcription(
            fileName: "empty.m4a",
            cleanTranscript: "   ",
            status: .completed
        ))

        let service = DerivedFieldsBackfillService(dbQueue: manager.dbQueue, batchSize: 10)
        let processed = try service.runOnce()
        XCTAssertEqual(processed, 1)

        // Second run is a no-op — the empty-row sentinel keeps it out of the
        // eligible set. Without the sentinel, this would loop forever.
        let again = try service.runOnce()
        XCTAssertEqual(again, 0)
    }

    func testRunOnceReportsActualCountOnPartialFinalBatch() throws {
        let (manager, repo) = try makeRepo()
        for i in 0..<7 {
            try repo.save(Transcription(
                fileName: "row\(i).m4a",
                cleanTranscript: "The team reviewed progress on item \(i) and aligned on next steps.",
                status: .completed
            ))
        }

        let service = DerivedFieldsBackfillService(dbQueue: manager.dbQueue, batchSize: 5)
        let processed = try service.runOnce()
        XCTAssertEqual(processed, 7)
    }

    func testBackfillPopulatesDerivedFields() throws {
        let (manager, repo) = try makeRepo()
        try repo.save(Transcription(
            fileName: "good.m4a",
            cleanTranscript: "We need to ship the new product release before the end of the quarter.",
            status: .completed
        ))

        let service = DerivedFieldsBackfillService(dbQueue: manager.dbQueue, batchSize: 10)
        try service.runOnce()

        let row = try repo.fetchAll(limit: nil).first
        XCTAssertNotNil(row?.derivedTitle)
        XCTAssertFalse(row?.derivedTitle?.isEmpty ?? true)
    }

    func testProcessingRowsAreNotBackfilled() throws {
        let (manager, repo) = try makeRepo()
        try repo.save(Transcription(
            fileName: "in-flight.m4a",
            cleanTranscript: "Content here.",
            status: .processing
        ))

        let service = DerivedFieldsBackfillService(dbQueue: manager.dbQueue, batchSize: 10)
        let processed = try service.runOnce()
        XCTAssertEqual(processed, 0)
    }

    func testReRunIsIdempotent() throws {
        let (manager, repo) = try makeRepo()
        try repo.save(Transcription(
            fileName: "row.m4a",
            cleanTranscript: "Some real content here for the deriver to pick up.",
            status: .completed
        ))

        let service = DerivedFieldsBackfillService(dbQueue: manager.dbQueue, batchSize: 10)
        XCTAssertEqual(try service.runOnce(), 1)
        XCTAssertEqual(try service.runOnce(), 0)
        XCTAssertEqual(try service.runOnce(), 0)
    }
}
