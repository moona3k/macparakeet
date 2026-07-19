import XCTest
import MacParakeetCore
@testable import MacParakeet

/// Guards the `ForEach` identity used for speaker-turn cards in the transcript
/// detail view. The identity must stay stable while a live turn grows, and
/// distinct turns must never collide — otherwise SwiftUI tears down growing
/// cards or hits duplicate-id undefined behavior.
final class SpeakerTurnIdentityTests: XCTestCase {

    private func segment(_ startMs: Int, speaker: String = "spk_0") -> TranscriptSegment {
        TranscriptSegment(startMs: startMs, text: "word", speakerId: speaker)
    }

    private func turn(speaker: String = "spk_0", segments: [TranscriptSegment]) -> SpeakerTurn {
        SpeakerTurn(speakerId: speaker, speakerLabel: speaker, segments: segments)
    }

    /// The first card keeps its identity when a growing turn crosses the card
    /// boundary, so SwiftUI adds a continuation card without replacing the
    /// content already on screen.
    func testIdentityStaysStableWhenTurnOutgrowsFirstCard() {
        let small = turn(
            segments: (0..<maximumSpeakerTurnSegmentsPerCard).map {
                segment($0 * 1000)
            })
        let grown = turn(
            segments: (0...maximumSpeakerTurnSegmentsPerCard).map {
                segment($0 * 1000)
            })

        let smallCards = identifiedSpeakerTurnCards([small])
        let grownCards = identifiedSpeakerTurnCards([grown])

        XCTAssertEqual(smallCards[0].id, grownCards[0].id)
        XCTAssertEqual(grownCards.count, 2)
    }

    /// Two turns that share `(speakerId, firstStartMs)` still receive distinct
    /// ids via the duplicate ordinal, so `ForEach` never sees a collision.
    func testTurnsSharingBaseKeyGetUniqueIDs() {
        let a = turn(segments: [segment(1000)])
        let b = turn(segments: [segment(1000), segment(2000)])

        let ids = identifiedSpeakerTurnCards([a, b]).map(\.id)

        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
    }

    func testLongTurnIsSplitIntoBoundedCardsWithoutChangingContent() {
        // Issue #845 contained 11,563 words, or about 964 typical segments.
        let reporterScaleSegmentCount = 964
        let segments = (0..<reporterScaleSegmentCount).map {
            segment($0 * 1000)
        }

        let cards = identifiedSpeakerTurnCards([turn(segments: segments)])

        XCTAssertEqual(
            cards.count,
            (reporterScaleSegmentCount + maximumSpeakerTurnSegmentsPerCard - 1)
                / maximumSpeakerTurnSegmentsPerCard
        )
        XCTAssertTrue(
            cards.allSatisfy {
                $0.turn.segments.count <= maximumSpeakerTurnSegmentsPerCard
            })
        XCTAssertEqual(
            cards.flatMap { $0.turn.segments.map(\.startMs) },
            segments.map(\.startMs)
        )
        XCTAssertEqual(Set(cards.map(\.id)).count, cards.count)
    }

    func testAutoScrollTargetAdvancesAcrossContinuationCards() {
        let segments = (0..<(maximumSpeakerTurnSegmentsPerCard * 2 + 1)).map {
            segment($0 * 1000)
        }
        let cards = identifiedSpeakerTurnCards([turn(segments: segments)])

        XCTAssertNil(speakerTurnCardScrollTarget(for: -1, in: cards))
        XCTAssertEqual(speakerTurnCardScrollTarget(for: 1000, in: cards), 0)
        XCTAssertEqual(
            speakerTurnCardScrollTarget(
                for: maximumSpeakerTurnSegmentsPerCard * 1000 + 1000,
                in: cards
            ),
            maximumSpeakerTurnSegmentsPerCard * 1000
        )
    }
}
