import XCTest

@testable import MacParakeet
@testable import MacParakeetCore

final class MeetingFinalizationReconcilerTests: XCTestCase {
    func testReconcileStaleProcessingRowsMarksOnlyProcessingMeetingsFailed() async throws {
        let repo = MockTranscriptionRepository()
        let staleMeeting = Transcription(
            fileName: "Stale meeting",
            status: .processing,
            sourceType: .meeting
        )
        let completedMeeting = Transcription(
            fileName: "Completed meeting",
            status: .completed,
            sourceType: .meeting
        )
        let processingFile = Transcription(
            fileName: "Processing file",
            status: .processing,
            sourceType: .file
        )
        try repo.save(staleMeeting)
        try repo.save(completedMeeting)
        try repo.save(processingFile)

        let reconciledIDs = try await MeetingFinalizationReconciler.reconcileStaleProcessingRows(
            repository: repo
        )

        XCTAssertEqual(repo.fetchMeetingsWithStatusCalls, [.processing])
        XCTAssertEqual(reconciledIDs, [staleMeeting.id])
        let reconciled = try XCTUnwrap(repo.fetch(id: staleMeeting.id))
        XCTAssertEqual(reconciled.status, .error)
        XCTAssertEqual(
            reconciled.errorMessage,
            MeetingFinalizationReconciler.staleProcessingErrorMessage
        )
        XCTAssertEqual(try repo.fetch(id: completedMeeting.id)?.status, .completed)
        XCTAssertEqual(try repo.fetch(id: processingFile.id)?.status, .processing)
    }
}
