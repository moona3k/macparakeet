import Foundation
import MacParakeetCore
import XCTest
@testable import MacParakeet

/// A voice prompt is anchored to a turn card by the same string that card hands
/// to its rename control. If two cards ever shared one, the prompt would appear
/// twice; if none matched, it would vanish. Both are silent failures on screen,
/// so the identifiers are pinned here.
final class SpeakerTurnBannerAnchorTests: XCTestCase {
    private func segments(startMs: Int, count: Int, speakerId: String) -> [TranscriptSegment] {
        (0..<count).map { index in
            TranscriptSegment(
                startMs: startMs + index * 1_000,
                text: "line \(index)",
                speakerId: speakerId
            )
        }
    }

    private func cards(_ segments: [TranscriptSegment]) -> [IdentifiedSpeakerTurn] {
        identifiedSpeakerTurnCards(
            TranscriptSegmenter.groupIntoSpeakerTurns(
                segments: segments,
                speakerLabelProvider: { $0.map { "Speaker \($0)" } ?? "Unknown" }
            )
        )
    }

    func testEachTurnCardOfOneSpeakerHasItsOwnRenameContext() {
        let transcript =
            segments(startMs: 0, count: 2, speakerId: "S1")
            + segments(startMs: 10_000, count: 2, speakerId: "S2")
            + segments(startMs: 20_000, count: 2, speakerId: "S1")
        let contexts = cards(transcript).map(speakerTurnRenameContextIdentifier)

        XCTAssertEqual(contexts.count, 3)
        XCTAssertEqual(Set(contexts).count, 3)
        XCTAssertEqual(contexts[0], "turn:S1:0:0")
        XCTAssertEqual(contexts[2], "turn:S1:20000:0")
    }

    /// A single long turn is split across several cards. Anchoring has to pick
    /// one of them, so the split cards must not collide.
    func testSplittingALongTurnKeepsOneRenameContextPerCard() {
        let transcript = segments(
            startMs: 0,
            count: maximumSpeakerTurnSegmentsPerCard * 2 + 1,
            speakerId: "S1"
        )
        let contexts = cards(transcript).map(speakerTurnRenameContextIdentifier)

        XCTAssertEqual(contexts.count, 3)
        XCTAssertEqual(Set(contexts).count, 3)
    }

    func testTheRenameContextMatchesTheControlTheCardRenders() {
        let card = cards(segments(startMs: 4_500, count: 1, speakerId: "S3"))[0]

        XCTAssertEqual(
            SpeakerRenameAccessibility.renameButtonIdentifier(
                contextID: speakerTurnRenameContextIdentifier(card)
            ),
            "transcript.speaker.rename.turn:S3:4500:0"
        )
    }

    func testAnUnassignedEffectiveTurnHasNoRenameContext() {
        XCTAssertNil(
            effectiveSpeakerTurnRenameContextIdentifier(effectiveTurn(assignment: .unassigned))
        )
        XCTAssertEqual(
            effectiveSpeakerTurnRenameContextIdentifier(
                effectiveTurn(assignment: .speaker(id: "S1"))
            ),
            "turn:S1:7000:0"
        )
    }

    private func effectiveTurn(assignment: SpeakerAssignment) -> IdentifiedEffectiveSpeakerTurn {
        let id = SpeakerEditableSegmentID(
            transcriptionId: UUID(),
            transcriptFingerprint: TranscriptFingerprint(rawValue: "fp"),
            wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 3)
        )
        let segment = SpeakerEditableSegment(
            id: id,
            anchorTranscriptSegmentIDs: [],
            startMs: 7_000,
            endMs: 9_000,
            text: "hello",
            assignment: assignment,
            automaticSpeakerIDs: [],
            sourceProvenance: [],
            isManuallySplit: false
        )
        return IdentifiedEffectiveSpeakerTurn(
            id: id,
            assignment: assignment,
            speakerLabel: "Speaker",
            segments: [segment],
            logicalTurnSegments: [segment]
        )
    }
}
