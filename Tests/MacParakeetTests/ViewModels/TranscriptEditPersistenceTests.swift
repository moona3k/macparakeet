import XCTest
import GRDB
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TranscriptEditPersistenceTests: XCTestCase {
    func testEditAndRevertPreserveLatestMetadataAndRefreshSearch() throws {
        let manager = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let vm = TranscriptionViewModel()
        vm.configure(transcriptionService: MockTranscriptionService(), transcriptionRepo: repo)
        let original = Transcription(fileName: "Original", rawTranscript: "Original words", status: .completed)
        try repo.save(original)
        vm.currentTranscription = original
        for reverting in [false, true] {
            let baseline = try XCTUnwrap(vm.makeTranscriptEditSnapshot())
            try repo.updateFavorite(id: original.id, isFavorite: !reverting)
            _ = try repo.updateUserNotes(id: original.id, userNotes: reverting ? "latest notes" : "new notes")
            _ = try repo.updateFileName(id: original.id, fileName: reverting ? "Latest title" : "New title")
            let saved =
                reverting
                ? vm.revertCurrentTranscriptToOriginal()
                : vm.updateCurrentTranscriptText(to: "Corrected words", expected: baseline)
            XCTAssertTrue(saved)
            let current = try XCTUnwrap(repo.fetch(id: original.id))
            XCTAssertEqual(current.isFavorite, !reverting)
            XCTAssertEqual(current.userNotes, reverting ? "latest notes" : "new notes")
            XCTAssertEqual(current.fileName, reverting ? "Latest title" : "New title")
            XCTAssertEqual(vm.currentTranscription?.fileName, current.fileName)
            XCTAssertEqual(current.rawTranscript, "Original words")
            let segments = try SegmentRepository(dbQueue: manager.dbQueue).fetch(transcriptionId: original.id)
            XCTAssertEqual(
                segments.map(\.text).joined(separator: " "), reverting ? "Original words" : "Corrected words")
        }
    }

    func testReEditingLegacyTimedTranscriptIndexesNewTextAndRevertRestoresCanonicalSegments() throws {
        let manager = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let segments = SegmentRepository(dbQueue: manager.dbQueue)
        let words = [
            WordTimestamp(word: "Original", startMs: 0, endMs: 100, confidence: 1),
            WordTimestamp(word: "words", startMs: 120, endMs: 220, confidence: 1),
        ]
        // A legacy row that still carries word timestamps but was already
        // whole-text edited by an older app version.
        let legacy = Transcription(
            fileName: "Legacy",
            rawTranscript: "Original words",
            cleanTranscript: "Previously edited text",
            wordTimestamps: words,
            status: .completed,
            isTranscriptEdited: true
        )
        try repo.save(legacy)
        try segments.replaceSegments(for: legacy)
        XCTAssertEqual(try segments.fetch(transcriptionId: legacy.id).map(\.text), ["Previously edited text"])

        let editSnapshot = try repo.transcriptEditSnapshot(for: legacy)
        _ = try repo.updateTranscriptText("Freshly edited text", expected: editSnapshot)

        XCTAssertEqual(try segments.fetch(transcriptionId: legacy.id).map(\.text), ["Freshly edited text"])
        XCTAssertTrue(
            try segments.search(SegmentSearchQuery(query: "Freshly")).contains { $0.transcriptionId == legacy.id })
        XCTAssertTrue(try segments.search(SegmentSearchQuery(query: "Original")).isEmpty)

        let current = try XCTUnwrap(repo.fetch(id: legacy.id))
        let revertSnapshot = try repo.transcriptEditSnapshot(for: current)
        let reverted = try repo.updateTranscriptText(legacy.rawTranscript, expected: revertSnapshot)

        XCTAssertFalse(reverted.isTranscriptEdited)
        XCTAssertEqual(try segments.fetch(transcriptionId: legacy.id).map(\.text), ["Original words"])
    }

    func testOriginalDraftConflictsEvenAfterViewModelRefreshAndDeletionNeverResurrects() throws {
        let repo = TranscriptionRepository(dbQueue: try DatabaseManager().dbQueue)
        let vm = TranscriptionViewModel()
        vm.configure(transcriptionService: MockTranscriptionService(), transcriptionRepo: repo)
        var original = Transcription(fileName: "Source", rawTranscript: "Original", status: .completed)
        try repo.save(original)
        vm.currentTranscription = original
        let draft = try XCTUnwrap(vm.makeTranscriptEditSnapshot())
        original.rawTranscript = "Replacement"
        try repo.save(original)
        vm.currentTranscription = original
        XCTAssertFalse(vm.updateCurrentTranscriptText(to: "Stale draft", expected: draft))
        XCTAssertEqual(try repo.fetch(id: original.id)?.rawTranscript, "Replacement")
        XCTAssertNotNil(vm.transcriptEditFailure)
        let fresh = try XCTUnwrap(vm.makeTranscriptEditSnapshot())
        _ = try repo.delete(id: original.id)
        XCTAssertFalse(vm.updateCurrentTranscriptText(to: "Draft", expected: fresh))
        XCTAssertNil(try repo.fetch(id: original.id))
    }

    func testChangedSourceOrCorrectionStateAndProcessingRejectEdits() throws {
        let manager = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: manager.dbQueue)
        for mutation in 0..<4 {
            var row = Transcription(fileName: "Source", rawTranscript: "Original", status: .completed)
            try repo.save(row)
            let snapshot = try repo.transcriptEditSnapshot(for: row)
            switch mutation {
            case 0: row.wordTimestamps = [WordTimestamp(word: "Original", startMs: 0, endMs: 100, confidence: 1)]
            case 1: row.cleanTranscript = "Other edit"
            case 2: row.status = .processing
            default:
                try manager.dbQueue.write { db in
                    try SpeakerCorrectionState(
                        transcriptionId: row.id, transcriptFingerprint: "changed", headId: nil, revision: 1
                    ).insert(db)
                }
            }
            try repo.save(row)
            XCTAssertThrowsError(try repo.updateTranscriptText("Draft", expected: snapshot))
            XCTAssertEqual(try repo.fetch(id: row.id)?.cleanTranscript, row.cleanTranscript)
        }
    }

    func testDerivedStateFailureRollsBackCanonicalEdit() throws {
        let manager = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let row = Transcription(fileName: "Source", rawTranscript: "Original", status: .completed)
        try repo.save(row)
        let snapshot = try repo.transcriptEditSnapshot(for: row)
        try manager.dbQueue.write { db in
            try db.execute(
                sql:
                    "CREATE TEMP TRIGGER reject_segments BEFORE INSERT ON segments BEGIN SELECT RAISE(ABORT, 'injected'); END"
            )
        }
        XCTAssertThrowsError(try repo.updateTranscriptText("Edited", expected: snapshot))
        XCTAssertNil(try repo.fetch(id: row.id)?.cleanTranscript)
    }
}
