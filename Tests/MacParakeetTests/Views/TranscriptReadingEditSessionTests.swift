import MacParakeetCore
import MacParakeetViewModels
import Observation
import XCTest

@MainActor
final class TranscriptReadingEditSessionTests: XCTestCase {
    private func draft(_ index: Int, text: String = "Original passage.") -> TranscriptReadingDraft {
        .init(
            target: .init(
                anchorTranscriptSegmentIDs: [UUID()],
                wordRange: .init(startIndex: index * 6, endIndexExclusive: index * 6 + 6)),
            originalText: text, text: text
        )
    }

    func testEditingRestoringAndRevertingTrackTheSameChangesAsSave() {
        let originals = [draft(0), draft(1), draft(2)]
        let session = TranscriptReadingEditSession(drafts: originals)
        XCTAssertFalse(session.hasChanges)
        session.passages[0].text = "  Revised  "
        session.passages[1].removed = true
        session.passages[2].text = " \n "
        XCTAssertTrue(session.hasChanges)
        XCTAssertEqual(
            session.command(),
            .reviseText(changes: [
                .replace(target: originals[0].target, text: "Revised"),
                .omit(target: originals[1].target),
                .omit(target: originals[2].target),
            ]))
        session.passages[0].text = " \nOriginal passage. "
        session.passages[1].removed = false
        XCTAssertTrue(session.hasChanges)
        session.passages[2].text = originals[2].text
        XCTAssertFalse(session.hasChanges)
        XCTAssertNil(session.command())
        XCTAssertEqual(session.passages.map(\.id), originals.map(\.id))
    }

    func testTypingInLongMeetingDoesNotInvalidateSaveStateOrAnotherPassage() {
        let session = TranscriptReadingEditSession(drafts: (0..<1_600).map { draft($0) })
        let passage = session.passages[800]
        passage.text = "First correction"
        // An observation callback is the same boundary SwiftUI uses to decide
        // whether to rerender the header or an unrelated row.
        withObservationTracking {
            _ = session.hasChanges
            _ = session.passages[0].text
        } onChange: {
            XCTFail("Typing into an already changed passage invalidated unrelated UI")
        }
        for index in 0..<100 { passage.text = "Correction \(index)" }
        XCTAssertTrue(session.hasChanges)
        XCTAssertEqual(
            session.command(),
            .reviseText(changes: [
                .replace(target: passage.draft.target, text: "Correction 99")
            ]))
    }

    func testSessionLifetimeAndReopeningDiscardUnsavedChanges() {
        let original = draft(0)
        var session: TranscriptReadingEditSession? = .init(drafts: [original])
        weak var previousSession = session
        let previousPassage = session!.passages[0]
        previousPassage.text = "Unsaved"
        session = nil
        XCTAssertNil(previousSession, "Passage callbacks must not retain a cancelled session")
        let reopened = TranscriptReadingEditSession(drafts: [original])
        previousPassage.removed = true
        XCTAssertFalse(reopened.hasChanges)
        XCTAssertEqual(reopened.passages[0].text, original.text)
    }

    func testInitiallyChangedDraftsAndEmptySession() {
        var edited = draft(0)
        edited.removed = true
        let session = TranscriptReadingEditSession(drafts: [edited])
        XCTAssertTrue(session.hasChanges)
        session.passages[0].removed = false
        XCTAssertFalse(session.hasChanges)
        let empty = TranscriptReadingEditSession(drafts: [])
        XCTAssertFalse(empty.hasChanges)
        XCTAssertNil(empty.command())
    }
}
