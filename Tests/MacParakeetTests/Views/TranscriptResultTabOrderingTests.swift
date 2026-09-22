import MacParakeetCore
import MacParakeetViewModels
import XCTest
@testable import MacParakeet

final class TranscriptResultTabOrderingTests: XCTestCase {
    func testMeetingStartsWithTranscriptThenNotes() {
        XCTAssertEqual(
            TranscriptResultTabOrdering.leadingTabs(for: .meeting),
            [.transcript, .notes]
        )
    }

    func testNonMeetingDoesNotExposeNotesTab() {
        XCTAssertEqual(
            TranscriptResultTabOrdering.leadingTabs(for: .file),
            [.transcript]
        )
    }
}
