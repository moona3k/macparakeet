import GRDB
import XCTest
@testable import MacParakeetCore

final class SpeakerCorrectionRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var transcriptions: TranscriptionRepository!
    private var repository: SpeakerCorrectionRepository!
    private var transcription: Transcription!

    override func setUpWithError() throws {
        manager = try DatabaseManager()
        transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        repository = SpeakerCorrectionRepository(dbQueue: manager.dbQueue)
        transcription = Transcription(
            fileName: "Interview",
            status: .completed,
            sourceType: .file
        )
        try transcriptions.save(transcription)
    }

    func testFetchActiveCorrectionsFollowsHeadChainInReplayOrder() throws {
        let first = correction(sequence: 1, parentId: nil, label: "Alice")
        let second = correction(sequence: 2, parentId: first.id, label: "Alicia")
        let abandoned = SpeakerCorrection(
            transcriptionId: transcription.id,
            parentId: first.id,
            sequence: 3,
            transcriptFingerprint: TranscriptFingerprint(rawValue: "fp"),
            payload: .rename(speakerID: "S1", label: "Discarded"),
            branchState: .abandoned
        )
        let state = SpeakerCorrectionState(
            transcriptionId: transcription.id,
            transcriptFingerprint: "fp",
            headId: second.id,
            revision: 2
        )
        try manager.dbQueue.write { db in
            try first.insert(db)
            try second.insert(db)
            try abandoned.insert(db)
            try state.insert(db)
        }

        let active = try repository.fetchActiveCorrections(transcriptionId: transcription.id)
        XCTAssertEqual(active.map(\.id), [first.id, second.id])
        XCTAssertEqual(active.map(\.payload), [first.payload, second.payload])
        XCTAssertEqual(
            try repository.fetchHistory(transcriptionId: transcription.id).map(\.id),
            [first.id, second.id, abandoned.id]
        )
        let storedState = try XCTUnwrap(repository.fetchState(transcriptionId: transcription.id))
        XCTAssertEqual(storedState.transcriptionId, state.transcriptionId)
        XCTAssertEqual(storedState.transcriptFingerprint, state.transcriptFingerprint)
        XCTAssertEqual(storedState.headId, state.headId)
        XCTAssertEqual(storedState.revision, state.revision)
    }

    func testFetchActiveCorrectionsRejectsFingerprintMismatch() throws {
        let first = correction(sequence: 1, parentId: nil, label: "Alice")
        let state = SpeakerCorrectionState(
            transcriptionId: transcription.id,
            transcriptFingerprint: "new-fingerprint",
            headId: first.id,
            revision: 1
        )
        try manager.dbQueue.write { db in
            try first.insert(db)
            try state.insert(db)
        }

        XCTAssertThrowsError(try repository.fetchActiveCorrections(transcriptionId: transcription.id)) {
            XCTAssertEqual($0 as? SpeakerCorrectionHistoryError, .mismatchedFingerprint(first.id))
        }
    }

    func testNewBranchAbandonsRedoRowsWithoutDeletingHistory() throws {
        let first = correction(sequence: 1, parentId: nil, label: "Alice")
        var redo = correction(sequence: 2, parentId: first.id, label: "Alicia")
        redo.branchState = .redo
        try manager.dbQueue.write { db in
            try first.insert(db)
            try redo.insert(db)
            try SpeakerCorrectionRepository.abandonRedoBranch(
                transcriptionId: transcription.id,
                fingerprint: "fp",
                in: db
            )
        }

        let history = try repository.fetchHistory(transcriptionId: transcription.id)
        XCTAssertEqual(history.map(\.branchState), [.current, .abandoned])
    }

    func testStateCompareAndSwapRejectsOldRevision() throws {
        let state = SpeakerCorrectionState(
            transcriptionId: transcription.id,
            transcriptFingerprint: "fp",
            headId: nil,
            revision: 4
        )
        try manager.dbQueue.write { try state.insert($0) }

        XCTAssertThrowsError(
            try manager.dbQueue.write { db in
                _ = try SpeakerCorrectionRepository.updateState(
                    transcriptionId: transcription.id,
                    fingerprint: "fp",
                    headId: nil,
                    expectedRevision: 3,
                    updatedAt: Date(),
                    in: db
                )
            }
        ) {
            XCTAssertEqual($0 as? SpeakerCorrectionHistoryError, .concurrentModification)
        }
        XCTAssertEqual(try repository.fetchState(transcriptionId: transcription.id)?.revision, 4)
    }

    private func correction(sequence: Int, parentId: UUID?, label: String) -> SpeakerCorrection {
        SpeakerCorrection(
            transcriptionId: transcription.id,
            parentId: parentId,
            sequence: sequence,
            transcriptFingerprint: TranscriptFingerprint(rawValue: "fp"),
            payload: .rename(speakerID: "S1", label: label)
        )
    }
}
