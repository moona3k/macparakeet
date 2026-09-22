import SwiftUI
import XCTest
import MacParakeetCore
@testable import MacParakeet

@MainActor
final class TranscriptSegmentCacheTests: XCTestCase {
    func testChangingTranscriptionHidesPreviouslyPublishedRowsBeforeRebuildStarts() throws {
        var cache = TranscriptSegmentCache()
        let firstID = UUID()
        let secondID = UUID()
        let request = cache.beginRebuild(transcriptionID: firstID)
        XCTAssertTrue(
            cache.apply(
                payload("First record", speakerLabel: "First speaker"),
                transcriptionID: firstID,
                requestID: request,
                speakerColorMap: ["speaker-1": .blue]
            ))
        let first = try XCTUnwrap(cache.snapshot(for: firstID))
        XCTAssertEqual(first.payload.segments.map(\.text), ["First record"])
        XCTAssertEqual(first.payload.speakerLabelMap["speaker-1"], "First speaker")
        XCTAssertFalse(first.identifiedTurnCards.isEmpty)
        XCTAssertFalse(first.segmentStartMs.isEmpty)

        // SwiftUI evaluates the new detail before its onChange schedules work.
        // Neither old row actions nor old speaker controls may survive that gap.
        XCTAssertNil(cache.snapshot(for: secondID))
        XCTAssertNil(cache.rowCount(for: secondID))
        XCTAssertTrue(TranscriptBodyLayout.usesLazyStack(rowCount: cache.rowCount(for: secondID), environment: [:]))
    }

    func testReplacementStaysEmptyWhilePendingAndRejectsPreviousRecordCompletion() throws {
        var cache = TranscriptSegmentCache()
        let firstID = UUID()
        let secondID = UUID()
        let firstRequest = cache.beginRebuild(transcriptionID: firstID)
        XCTAssertTrue(
            cache.apply(
                payload("First record"), transcriptionID: firstID, requestID: firstRequest, speakerColorMap: [:]
            ))
        let staleFirstRequest = cache.beginRebuild(transcriptionID: firstID)
        let secondRequest = cache.beginRebuild(transcriptionID: secondID)

        // Hold the second builder here: beginning its request must retire all
        // of the previously rendered transcript's data, not just its row count.
        XCTAssertNil(cache.snapshot(for: secondID))
        XCTAssertNil(cache.rowCount(for: secondID))
        XCTAssertTrue(TranscriptBodyLayout.usesLazyStack(rowCount: cache.rowCount(for: secondID), environment: [:]))
        XCTAssertFalse(
            cache.apply(
                payload("Late first record"), transcriptionID: firstID,
                requestID: staleFirstRequest, speakerColorMap: [:]
            ))
        XCTAssertNil(cache.snapshot(for: secondID))

        XCTAssertTrue(
            cache.apply(
                payload("Second record", speakerLabel: "Second speaker"), transcriptionID: secondID,
                requestID: secondRequest, speakerColorMap: ["speaker-1": .green]
            ))
        let second = try XCTUnwrap(cache.snapshot(for: secondID))
        XCTAssertEqual(second.payload.segments.map(\.text), ["Second record"])
        XCTAssertEqual(second.payload.speakerLabelMap["speaker-1"], "Second speaker")
        XCTAssertEqual(cache.rowCount(for: secondID), 1)
        XCTAssertNil(cache.snapshot(for: firstID))
    }

    func testSameRecordRefreshKeepsItsRowsButOnlyLatestRequestCanPublish() throws {
        var cache = TranscriptSegmentCache()
        let id = UUID()
        let initialRequest = cache.beginRebuild(transcriptionID: id)
        XCTAssertTrue(
            cache.apply(
                payload("Original", speakerLabel: "Before rename"), transcriptionID: id,
                requestID: initialRequest, speakerColorMap: [:]
            ))
        let replacedRequest = cache.beginRebuild(transcriptionID: id)
        let latestRequest = cache.beginRebuild(transcriptionID: id)

        XCTAssertEqual(cache.snapshot(for: id)?.payload.segments.map(\.text), ["Original"])
        XCTAssertNil(cache.rowCount(for: id), "Unknown updated size must keep the conservative lazy layout.")
        XCTAssertFalse(
            cache.apply(
                payload("Stale revision"), transcriptionID: id, requestID: replacedRequest, speakerColorMap: [:]
            ))
        XCTAssertTrue(
            cache.apply(
                payload("Updated", speakerLabel: "After rename"), transcriptionID: id,
                requestID: latestRequest, speakerColorMap: [:]
            ))
        let updated = try XCTUnwrap(cache.snapshot(for: id))
        XCTAssertEqual(updated.payload.segments.map(\.text), ["Updated"])
        XCTAssertEqual(updated.payload.speakerLabelMap["speaker-1"], "After rename")
        XCTAssertEqual(cache.rowCount(for: id), 1)
    }

    func testUntimedReplacementClearsRowsAndInvalidatesPendingBuilder() {
        var cache = TranscriptSegmentCache()
        let timedID = UUID()
        let untimedID = UUID()
        let request = cache.beginRebuild(transcriptionID: timedID)
        XCTAssertTrue(
            cache.apply(
                payload("Timed record"), transcriptionID: timedID, requestID: request, speakerColorMap: [:]
            ))
        let pendingRequest = cache.beginRebuild(transcriptionID: timedID)
        cache.clear(transcriptionID: untimedID)

        XCTAssertNil(cache.snapshot(for: untimedID))
        XCTAssertEqual(cache.rowCount(for: untimedID), 0)
        XCTAssertFalse(
            cache.apply(
                payload("Late timed record"), transcriptionID: timedID,
                requestID: pendingRequest, speakerColorMap: [:]
            ))
        XCTAssertNil(cache.snapshot(for: untimedID))
    }

    private func payload(_ text: String, speakerLabel: String = "Speaker") -> TranscriptSegmentCachePayload {
        TranscriptSegmentCachePayload.make(
            words: [WordTimestamp(word: text, startMs: 1000, endMs: 2000, confidence: 1, speakerId: "speaker-1")],
            speakers: [SpeakerInfo(id: "speaker-1", label: speakerLabel)],
            diarizationSegments: nil
        )
    }
}
