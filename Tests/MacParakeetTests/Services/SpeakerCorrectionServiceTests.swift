import GRDB
import XCTest
@testable import MacParakeetCore

final class SpeakerCorrectionServiceTests: XCTestCase {
    func testRenameCommitsHistorySegmentsAndCardInvalidationAtomically() async throws {
        let fixture = try Fixture()

        let result = try await fixture.service.apply(
            transcriptionId: fixture.transcription.id,
            command: .rename(speakerID: "S1", label: "Alice"),
            expectedFingerprint: fixture.fingerprint,
            expectedRevision: 0
        )

        XCTAssertEqual(result.revision, 1)
        XCTAssertTrue(result.canUndo)
        XCTAssertFalse(result.canRedo)
        XCTAssertEqual(result.attribution.speakers.first?.label, "Alice")
        XCTAssertEqual(try fixture.corrections.fetchHistory(transcriptionId: fixture.transcription.id).count, 1)
        XCTAssertEqual(try fixture.segments.fetch(transcriptionId: fixture.transcription.id).first?.speaker, "Alice")
        XCTAssertNil(try fixture.cards.fetch(transcriptionId: fixture.transcription.id))
        XCTAssertEqual(
            try fixture.transcriptions.fetch(id: fixture.transcription.id)?.speakers?.first?.label,
            "Speaker 1",
            "automatic attribution remains immutable"
        )
    }

    func testUndoAndRedoMovePersistentCursorAndRepublishSegments() async throws {
        let fixture = try Fixture()
        let applied = try await fixture.service.apply(
            transcriptionId: fixture.transcription.id,
            command: .rename(speakerID: "S1", label: "Alice"),
            expectedFingerprint: fixture.fingerprint,
            expectedRevision: 0
        )
        let reader = SpeakerAttributionReadService(dbQueue: fixture.manager.dbQueue)
        let persistedApplied = try XCTUnwrap(reader.resolve(transcriptionId: fixture.transcription.id))
        XCTAssertTrue(persistedApplied.canUndo)
        XCTAssertFalse(persistedApplied.canRedo)

        let undone = try await fixture.service.undo(
            transcriptionId: fixture.transcription.id,
            expectedFingerprint: fixture.fingerprint,
            expectedRevision: applied.revision
        )
        XCTAssertEqual(undone.revision, 2)
        XCTAssertFalse(undone.canUndo)
        XCTAssertTrue(undone.canRedo)
        let persistedUndone = try XCTUnwrap(reader.resolve(transcriptionId: fixture.transcription.id))
        XCTAssertFalse(persistedUndone.canUndo)
        XCTAssertTrue(persistedUndone.canRedo)
        XCTAssertEqual(
            try fixture.segments.fetch(transcriptionId: fixture.transcription.id).first?.speaker, "Speaker 1")

        let redone = try await fixture.service.redo(
            transcriptionId: fixture.transcription.id,
            expectedFingerprint: fixture.fingerprint,
            expectedRevision: undone.revision
        )
        XCTAssertEqual(redone.revision, 3)
        XCTAssertTrue(redone.canUndo)
        XCTAssertFalse(redone.canRedo)
        let persistedRedone = try XCTUnwrap(reader.resolve(transcriptionId: fixture.transcription.id))
        XCTAssertTrue(persistedRedone.canUndo)
        XCTAssertFalse(persistedRedone.canRedo)
        XCTAssertEqual(try fixture.segments.fetch(transcriptionId: fixture.transcription.id).first?.speaker, "Alice")
    }

    func testNewCommandAfterUndoAbandonsRedoBranch() async throws {
        let fixture = try Fixture()
        let applied = try await fixture.service.apply(
            transcriptionId: fixture.transcription.id,
            command: .rename(speakerID: "S1", label: "Alice"),
            expectedFingerprint: fixture.fingerprint,
            expectedRevision: 0
        )
        let undone = try await fixture.service.undo(
            transcriptionId: fixture.transcription.id,
            expectedFingerprint: fixture.fingerprint,
            expectedRevision: applied.revision
        )

        let branched = try await fixture.service.apply(
            transcriptionId: fixture.transcription.id,
            command: .rename(speakerID: "S1", label: "Alicia"),
            expectedFingerprint: fixture.fingerprint,
            expectedRevision: undone.revision
        )

        XCTAssertFalse(branched.canRedo)
        let history = try fixture.corrections.fetchHistory(transcriptionId: fixture.transcription.id)
        XCTAssertEqual(history.map(\.branchState), [.abandoned, .current])
        XCTAssertNil(history[1].parentId)
    }

    func testStaleRevisionRejectsWithoutWritingAnything() async throws {
        let fixture = try Fixture()
        _ = try await fixture.service.apply(
            transcriptionId: fixture.transcription.id,
            command: .rename(speakerID: "S1", label: "Alice"),
            expectedFingerprint: fixture.fingerprint,
            expectedRevision: 0
        )

        do {
            _ = try await fixture.service.apply(
                transcriptionId: fixture.transcription.id,
                command: .rename(speakerID: "S1", label: "Stale"),
                expectedFingerprint: fixture.fingerprint,
                expectedRevision: 0
            )
            XCTFail("Expected conflict")
        } catch {
            XCTAssertEqual(error as? SpeakerCorrectionServiceError, .conflict)
        }

        XCTAssertEqual(try fixture.corrections.fetchHistory(transcriptionId: fixture.transcription.id).count, 1)
        XCTAssertEqual(try fixture.segments.fetch(transcriptionId: fixture.transcription.id).first?.speaker, "Alice")
    }

    func testSubrangeAssignmentSplitsDerivedSearchRowsWithoutChangingDurableSegment() async throws {
        let fixture = try Fixture()
        let durableID = try XCTUnwrap(fixture.transcription.transcriptSegments?.first?.id)
        let whole = SpeakerCorrectionTarget(
            anchorTranscriptSegmentIDs: [durableID],
            wordRange: .init(startIndex: 0, endIndexExclusive: 2)
        )
        let split = try await fixture.service.apply(
            transcriptionId: fixture.transcription.id,
            command: .split(target: whole, atWordIndex: 1),
            expectedFingerprint: fixture.fingerprint,
            expectedRevision: 0
        )
        let right = SpeakerCorrectionTarget(
            anchorTranscriptSegmentIDs: [durableID],
            wordRange: .init(startIndex: 1, endIndexExclusive: 2)
        )
        _ = try await fixture.service.apply(
            transcriptionId: fixture.transcription.id,
            command: .add(
                speaker: ManualSpeaker(id: "user:\(UUID().uuidString)", label: "Bob"),
                assigning: [right]
            ),
            expectedFingerprint: fixture.fingerprint,
            expectedRevision: split.revision
        )

        let rows = try fixture.segments.fetch(transcriptionId: fixture.transcription.id)
        XCTAssertEqual(rows.map(\.text), ["Hello", "world."])
        XCTAssertEqual(rows.map(\.speaker), ["Speaker 1", "Bob"])
        XCTAssertEqual(
            try fixture.transcriptions.fetch(id: fixture.transcription.id)?.transcriptSegments?.map(\.id),
            [durableID]
        )
    }

    func testInvalidCommandRollsBackInitialStateAndLeavesDerivedRowsUntouched() async throws {
        let fixture = try Fixture()

        do {
            _ = try await fixture.service.apply(
                transcriptionId: fixture.transcription.id,
                command: .rename(speakerID: "missing", label: "Nobody"),
                expectedFingerprint: fixture.fingerprint,
                expectedRevision: 0
            )
            XCTFail("Expected invalid command")
        } catch {
            XCTAssertEqual(
                error as? SpeakerCorrectionServiceError,
                .invalidCommand(.missingSpeaker)
            )
        }

        XCTAssertNil(try fixture.corrections.fetchState(transcriptionId: fixture.transcription.id))
        XCTAssertTrue(try fixture.corrections.fetchHistory(transcriptionId: fixture.transcription.id).isEmpty)
        XCTAssertEqual(
            try fixture.segments.fetch(transcriptionId: fixture.transcription.id).first?.speaker, "Speaker 1")
        XCTAssertNotNil(try fixture.cards.fetch(transcriptionId: fixture.transcription.id))
    }

    func testDerivedSegmentWriteFailureRollsBackCorrectionCursorSegmentsAndCard() async throws {
        let fixture = try Fixture()
        try await fixture.manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_corrected_segment_insert
                    BEFORE INSERT ON segments
                    BEGIN
                        SELECT RAISE(ABORT, 'forced segment failure');
                    END
                    """)
        }

        do {
            _ = try await fixture.service.apply(
                transcriptionId: fixture.transcription.id,
                command: .rename(speakerID: "S1", label: "Alice"),
                expectedFingerprint: fixture.fingerprint,
                expectedRevision: 0
            )
            XCTFail("Expected forced segment failure")
        } catch {
            XCTAssertTrue(error is DatabaseError)
        }

        XCTAssertNil(try fixture.corrections.fetchState(transcriptionId: fixture.transcription.id))
        XCTAssertTrue(try fixture.corrections.fetchHistory(transcriptionId: fixture.transcription.id).isEmpty)
        XCTAssertEqual(
            try fixture.segments.fetch(transcriptionId: fixture.transcription.id).first?.speaker, "Speaker 1")
        XCTAssertNotNil(try fixture.cards.fetch(transcriptionId: fixture.transcription.id))
    }

    func testRetranscribedVersionReadsAsBaselineAndAcceptsNewCorrectionAtRevisionZero() async throws {
        let fixture = try Fixture()
        _ = try await fixture.service.apply(
            transcriptionId: fixture.transcription.id,
            command: .rename(speakerID: "S1", label: "Alice"),
            expectedFingerprint: fixture.fingerprint,
            expectedRevision: 0
        )

        var retranscribed = fixture.transcription
        retranscribed.rawTranscript = "A new transcript."
        retranscribed.wordTimestamps = [
            WordTimestamp(
                word: "A new transcript.",
                startMs: 0,
                endMs: 600,
                confidence: 1,
                speakerId: "S1"
            )
        ]
        retranscribed.transcriptSegments = [
            TranscriptSegmentRecord(
                startMs: 0,
                endMs: 600,
                speakerId: "S1",
                speakerLabel: "Speaker 1",
                text: "A new transcript.",
                wordRange: .init(startIndex: 0, endIndexExclusive: 1)
            )
        ]
        try fixture.transcriptions.save(retranscribed)
        let newFingerprint = SpeakerAttributionResolver.fingerprint(for: retranscribed)
        let reader = SpeakerAttributionReadService(dbQueue: fixture.manager.dbQueue)

        let baseline = try XCTUnwrap(reader.resolve(transcriptionId: retranscribed.id))
        XCTAssertFalse(baseline.correctionsApplied)
        XCTAssertEqual(baseline.correctionRevision, 0)
        XCTAssertFalse(baseline.canUndo)
        XCTAssertFalse(baseline.canRedo)
        XCTAssertEqual(baseline.effectiveTranscription.speakers?.first?.label, "Speaker 1")

        do {
            _ = try await fixture.service.undo(
                transcriptionId: retranscribed.id,
                expectedFingerprint: newFingerprint,
                expectedRevision: 0
            )
            XCTFail("A previous transcript version must not be undoable")
        } catch {
            XCTAssertEqual(error as? SpeakerCorrectionServiceError, .nothingToUndo)
        }
        do {
            _ = try await fixture.service.redo(
                transcriptionId: retranscribed.id,
                expectedFingerprint: newFingerprint,
                expectedRevision: 0
            )
            XCTFail("A previous transcript version must not be redoable")
        } catch {
            XCTAssertEqual(error as? SpeakerCorrectionServiceError, .nothingToRedo)
        }

        let corrected = try await fixture.service.apply(
            transcriptionId: retranscribed.id,
            command: .rename(speakerID: "S1", label: "Alicia"),
            expectedFingerprint: newFingerprint,
            expectedRevision: 0
        )

        XCTAssertEqual(corrected.revision, 1)
        XCTAssertEqual(corrected.attribution.speakers.first?.label, "Alicia")
        XCTAssertEqual(
            try fixture.corrections.fetchHistory(transcriptionId: retranscribed.id).count,
            2,
            "the old transcript-version log remains available for audit"
        )
        let state = try XCTUnwrap(fixture.corrections.fetchState(transcriptionId: retranscribed.id))
        XCTAssertEqual(state.transcriptFingerprint, newFingerprint.rawValue)
        XCTAssertEqual(state.revision, 1)
    }
}

private final class Fixture {
    let manager: DatabaseManager
    let transcriptions: TranscriptionRepository
    let corrections: SpeakerCorrectionRepository
    let segments: SegmentRepository
    let cards: CardRepository
    let service: SpeakerCorrectionService
    let transcription: Transcription
    let fingerprint: TranscriptFingerprint

    init() throws {
        manager = try DatabaseManager()
        transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        corrections = SpeakerCorrectionRepository(dbQueue: manager.dbQueue)
        segments = SegmentRepository(dbQueue: manager.dbQueue)
        cards = CardRepository(dbQueue: manager.dbQueue)
        service = SpeakerCorrectionService(dbQueue: manager.dbQueue)

        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 200, confidence: 1, speakerId: "S1"),
            WordTimestamp(word: "world.", startMs: 220, endMs: 500, confidence: 1, speakerId: "S1"),
        ]
        let durable = TranscriptSegmentRecord(
            startMs: 0,
            endMs: 500,
            speakerId: "S1",
            speakerLabel: "Speaker 1",
            text: "Hello world.",
            wordRange: .init(startIndex: 0, endIndexExclusive: 2)
        )
        transcription = Transcription(
            fileName: "Interview",
            rawTranscript: "Hello world.",
            wordTimestamps: words,
            speakerCount: 1,
            speakers: [SpeakerInfo(id: "S1", label: "Speaker 1")],
            transcriptSegments: [durable],
            status: .completed,
            sourceType: .file
        )
        fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        try transcriptions.save(transcription)
        try segments.replaceSegments(for: transcription)
        try cards.save(
            Card(
                transcriptionId: transcription.id,
                cardSchemaVersion: Card.currentSchemaVersion,
                transcriptHash: CardContentFingerprint.transcriptHash(for: transcription),
                segmenterVersion: KnowledgeSegmenter.currentVersion,
                promptVersion: Card.currentPromptVersion,
                model: "test",
                generatedAt: Date(),
                synopsis: "Existing card",
                topics: [],
                decisions: [],
                actions: []
            ))
    }
}
