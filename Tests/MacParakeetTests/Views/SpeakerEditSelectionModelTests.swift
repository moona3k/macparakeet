import XCTest
import MacParakeetCore
@testable import MacParakeet

final class SpeakerEditSelectionModelTests: XCTestCase {
    func testReplacingAndTogglingSelection() {
        let ids = makeIDs(3)
        var model = SpeakerEditSelectionModel()

        model.select(ids[0], intent: .replacing, orderedIDs: ids)
        XCTAssertEqual(model.selectedIDs, [ids[0]])
        XCTAssertEqual(model.anchorID, ids[0])

        model.select(ids[2], intent: .toggling, orderedIDs: ids)
        XCTAssertEqual(model.selectedIDs, [ids[0], ids[2]])
        XCTAssertEqual(model.anchorID, ids[2])

        model.select(ids[2], intent: .toggling, orderedIDs: ids)
        XCTAssertEqual(model.selectedIDs, [ids[0]])
        XCTAssertEqual(model.anchorID, ids[2])
    }

    func testRangeSelectionIsInclusiveInEitherDirection() {
        let ids = makeIDs(5)
        var model = SpeakerEditSelectionModel()

        model.select(ids[4], intent: .replacing, orderedIDs: ids)
        model.select(ids[1], intent: .extendingRange, orderedIDs: ids)

        XCTAssertEqual(model.selectedIDs, Set(ids[1...4]))
        XCTAssertEqual(model.anchorID, ids[4])
    }

    func testRangeSelectionPreservesExistingIndependentSelections() {
        let ids = makeIDs(6)
        var model = SpeakerEditSelectionModel()

        model.select(ids[0], intent: .toggling, orderedIDs: ids)
        model.select(ids[4], intent: .toggling, orderedIDs: ids)
        model.select(ids[2], intent: .extendingRange, orderedIDs: ids)

        XCTAssertEqual(model.selectedIDs, Set([ids[0], ids[2], ids[3], ids[4]]))
        XCTAssertEqual(model.anchorID, ids[4])
    }

    func testTurnToggleSelectsAndDeselectsWholeTurnWithoutDroppingOthers() {
        let ids = makeIDs(6)
        var model = SpeakerEditSelectionModel()
        model.select(ids[0], intent: .toggling, orderedIDs: ids)

        model.toggleTurn(Array(ids[2...4]), orderedIDs: ids)
        XCTAssertEqual(model.selectedIDs, Set([ids[0], ids[2], ids[3], ids[4]]))
        XCTAssertEqual(model.anchorID, ids[4])

        model.toggleTurn(Array(ids[2...4]), orderedIDs: ids)
        XCTAssertEqual(model.selectedIDs, [ids[0]])
        XCTAssertEqual(model.anchorID, ids[0])
    }

    func testTurnToggleCompletesPartialTurnSelectionBeforeDeselectingIt() {
        let ids = makeIDs(4)
        var model = SpeakerEditSelectionModel()
        model.select(ids[1], intent: .toggling, orderedIDs: ids)

        model.toggleTurn(Array(ids[1...3]), orderedIDs: ids)
        XCTAssertEqual(model.selectedIDs, Set(ids[1...3]))

        model.toggleTurn(Array(ids[1...3]), orderedIDs: ids)
        XCTAssertTrue(model.isEmpty)
        XCTAssertNil(model.anchorID)
    }

    func testRangeWithoutValidAnchorFallsBackToSingleSelection() {
        let ids = makeIDs(2)
        var model = SpeakerEditSelectionModel()

        model.select(ids[1], intent: .extendingRange, orderedIDs: ids)

        XCTAssertEqual(model.selectedIDs, [ids[1]])
        XCTAssertEqual(model.anchorID, ids[1])
    }

    func testUnknownIdentityIsIgnored() {
        let ids = makeIDs(2)
        let unknown = makeID(range: 10..<11)
        var model = SpeakerEditSelectionModel()
        model.select(ids[0], intent: .replacing, orderedIDs: ids)

        model.select(unknown, intent: .replacing, orderedIDs: ids)

        XCTAssertEqual(model.selectedIDs, [ids[0]])
        XCTAssertEqual(model.anchorID, ids[0])
    }

    func testReconcileDropsRemovedSegmentsAndRepairsAnchor() {
        let ids = makeIDs(4)
        var model = SpeakerEditSelectionModel()
        model.select(ids[1], intent: .replacing, orderedIDs: ids)
        model.select(ids[3], intent: .toggling, orderedIDs: ids)

        model.reconcile(with: [ids[0], ids[1], ids[2]])

        XCTAssertEqual(model.selectedIDs, [ids[1]])
        XCTAssertEqual(model.anchorID, ids[1])
    }

    func testSelectedSegmentsPreserveTranscriptOrder() {
        let segments = makeSegments(3)
        var model = SpeakerEditSelectionModel()
        let ids = segments.map(\.id)
        model.select(ids[2], intent: .replacing, orderedIDs: ids)
        model.select(ids[0], intent: .toggling, orderedIDs: ids)

        XCTAssertEqual(model.selectedSegments(from: segments).map(\.id), [ids[0], ids[2]])
    }

    private func makeIDs(_ count: Int) -> [SpeakerEditableSegmentID] {
        (0..<count).map { makeID(range: $0..<($0 + 1)) }
    }

    private func makeID(range: Range<Int>) -> SpeakerEditableSegmentID {
        SpeakerEditableSegmentID(
            transcriptionId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            transcriptFingerprint: TranscriptFingerprint(rawValue: "fixture"),
            wordRange: .init(
                startIndex: range.lowerBound,
                endIndexExclusive: range.upperBound
            )
        )
    }

    private func makeSegments(_ count: Int) -> [SpeakerEditableSegment] {
        let words = (0..<count).map { index in
            WordTimestamp(
                word: "Word\(index).",
                startMs: index * 3_000,
                endMs: index * 3_000 + 500,
                confidence: 1,
                speakerId: "S1"
            )
        }
        let transcription = Transcription(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            fileName: "fixture.wav",
            wordTimestamps: words,
            speakers: [SpeakerInfo(id: "S1", label: "Speaker 1")],
            transcriptSegments: TranscriptSegmenter.materializeSegments(words: words),
            status: .completed
        )
        return SpeakerAttributionResolver.resolve(transcription: transcription).editableSegments
    }
}
