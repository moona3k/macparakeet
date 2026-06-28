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

    /// A live turn keeps its identity as new segments are appended. Before the
    /// fix the identity carried `lastStartMs`/`segmentCount`, so every appended
    /// word produced a "new" identity and SwiftUI rebuilt the growing card.
    func testIdentityStaysStableWhileTurnGrows() {
        let small = turn(segments: [segment(1000)])
        let grown = turn(segments: [segment(1000), segment(2000), segment(3000)])

        let smallID = identifiedSpeakerTurns([small])[0].id
        let grownID = identifiedSpeakerTurns([grown])[0].id

        XCTAssertEqual(smallID, grownID)
    }

    /// Two turns that share `(speakerId, firstStartMs)` still receive distinct
    /// ids via the duplicate ordinal, so `ForEach` never sees a collision.
    func testTurnsSharingBaseKeyGetUniqueIDs() {
        let a = turn(segments: [segment(1000)])
        let b = turn(segments: [segment(1000), segment(2000)])

        let ids = identifiedSpeakerTurns([a, b]).map(\.id)

        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
    }
}
