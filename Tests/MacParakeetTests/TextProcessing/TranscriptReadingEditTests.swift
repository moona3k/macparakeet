import XCTest
@testable import MacParakeetCore

final class TranscriptReadingEditTests: XCTestCase {
    func testUnchangedPassageProducesNoCommand() {
        let drafts = [
            TranscriptReadingDraft(
                target: target(0, 2),
                originalText: "Hello world.",
                text: "  Hello world.  "
            )
        ]
        XCTAssertNil(TranscriptReadingEdit.command(for: drafts))
    }

    func testEditedAndRemovedPassagesBecomeOneSession() {
        let kept = target(0, 2)
        let dropped = target(2, 4)
        let command = TranscriptReadingEdit.command(for: [
            TranscriptReadingDraft(target: kept, originalText: "Hello", text: "Hi there"),
            TranscriptReadingDraft(target: dropped, originalText: "Secret", text: "Secret", removed: true),
            TranscriptReadingDraft(target: target(4, 6), originalText: "Aside", text: "   "),
        ])
        XCTAssertEqual(
            command,
            .reviseText(changes: [
                .replace(target: kept, text: "Hi there"),
                .omit(target: dropped),
                .omit(target: target(4, 6)),
            ])
        )
    }

    private func target(_ start: Int, _ end: Int) -> SpeakerCorrectionTarget {
        SpeakerCorrectionTarget(
            anchorTranscriptSegmentIDs: [],
            wordRange: .init(startIndex: start, endIndexExclusive: end)
        )
    }
}
