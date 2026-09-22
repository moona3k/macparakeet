import XCTest
import MacParakeetCore
@testable import MacParakeet

final class SpeakerRenameStateTests: XCTestCase {
    func testRefusedHandoffRetainsDraftUntilAcceptedRetry() throws {
        var state = SpeakerRenameState()
        state.begin(SpeakerInfo(id: "B", label: "Speaker B"), contextID: "overview:B")
        state.updateLabel("QA Bob", contextID: "overview:B")
        let nextSpeaker = SpeakerInfo(id: "A", label: "Speaker A")
        var acceptsSave = false
        var saveAttempts = 0
        var acceptedDrafts: [SpeakerRenameState.Draft] = []
        func savePrevious(_ draft: SpeakerRenameState.Draft) -> Bool {
            saveAttempts += 1
            guard acceptsSave else { return false }
            acceptedDrafts.append(draft)
            return true
        }

        XCTAssertNil(state.begin(nextSpeaker, contextID: "overview:A", savePrevious: savePrevious))
        XCTAssertEqual(state.draft?.contextID, "overview:B")
        XCTAssertEqual(state.draft?.speakerID, "B")
        XCTAssertEqual(state.draft?.label, "QA Bob")
        XCTAssertTrue(acceptedDrafts.isEmpty)

        acceptsSave = true
        let previous = try XCTUnwrap(state.begin(nextSpeaker, contextID: "overview:A", savePrevious: savePrevious))
        XCTAssertEqual(previous.label, "QA Bob")
        XCTAssertEqual(state.draft?.contextID, "overview:A")
        XCTAssertEqual(state.draft?.label, "Speaker A")
        XCTAssertNil(state.finish(contextID: "overview:B"), "A delayed old-field event must not finish the new draft")
        XCTAssertNil(state.begin(nextSpeaker, contextID: "overview:A", savePrevious: savePrevious))
        XCTAssertEqual(saveAttempts, 2)
        XCTAssertEqual(acceptedDrafts.count, 1)
        XCTAssertEqual(acceptedDrafts.first?.speakerID, "B")
        XCTAssertEqual(acceptedDrafts.first?.label, "QA Bob")
    }

    func testSwitchingSpeakersCommitsOldDraftOnceAndIgnoresItsDelayedEvents() throws {
        var state = SpeakerRenameState()
        XCTAssertNil(state.begin(SpeakerInfo(id: "B", label: "Speaker B"), contextID: "overview:B"))
        state.updateLabel("QA Bob", contextID: "overview:B")

        let previous = try XCTUnwrap(
            state.begin(
                SpeakerInfo(id: "A", label: "QA Alice"), contextID: "overview:A"
            ))
        XCTAssertEqual(previous.speakerID, "B")
        XCTAssertEqual(previous.label, "QA Bob")

        XCTAssertNil(state.finish(contextID: "overview:B"), "B's delayed blur must not finish A")
        state.updateLabel("Stale B text", contextID: "overview:B")
        XCTAssertFalse(state.cancel(contextID: "overview:B"), "B's delayed Escape must not cancel A")
        XCTAssertEqual(state.draft?.contextID, "overview:A")
        XCTAssertEqual(state.draft?.label, "QA Alice")

        state.updateLabel("QA Alicia", contextID: "overview:A")
        let renamed = try XCTUnwrap(state.finish(contextID: "overview:A"))
        XCTAssertEqual(renamed.speakerID, "A")
        XCTAssertEqual(renamed.label, "QA Alicia")
        XCTAssertNil(state.finish(contextID: "overview:A"), "A draft can only be submitted once")
        XCTAssertNil(state.draft)
    }

    func testSameSpeakerInAnotherTurnOwnsANewEditingContext() throws {
        var state = SpeakerRenameState()
        let speaker = SpeakerInfo(id: "A", label: "Speaker A")
        state.begin(speaker, contextID: "turn:1:A")
        state.updateLabel("QA Alice", contextID: "turn:1:A")

        let previous = try XCTUnwrap(state.begin(speaker, contextID: "turn:2:A"))
        XCTAssertEqual(previous.label, "QA Alice")
        XCTAssertEqual(previous.contextID, "turn:1:A")
        XCTAssertFalse(state.cancel(contextID: "turn:1:A"))
        XCTAssertEqual(state.draft?.contextID, "turn:2:A")
        XCTAssertEqual(state.draft?.label, "QA Alice")
        XCTAssertEqual(state.finish(contextID: "turn:2:A")?.label, "QA Alice")
    }

    func testSameSpeakerHandoffUsesTheTrimmedPendingName() throws {
        var state = SpeakerRenameState()
        let speaker = SpeakerInfo(id: "A", label: "Speaker A")
        state.begin(speaker, contextID: "overview:A")
        state.updateLabel(" \n QA Alice \t ", contextID: "overview:A")

        let previous = try XCTUnwrap(state.begin(speaker, contextID: "turn:1:A"))
        XCTAssertEqual(previous.label, " \n QA Alice \t ")
        XCTAssertEqual(state.draft?.label, "QA Alice")
        XCTAssertEqual(state.finish(contextID: "turn:1:A")?.label, "QA Alice")
    }

    func testSameSpeakerHandoffKeepsExistingNameWhenDraftIsBlank() throws {
        var state = SpeakerRenameState()
        let speaker = SpeakerInfo(id: "A", label: "Speaker A")
        state.begin(speaker, contextID: "overview:A")
        state.updateLabel(" \n\t ", contextID: "overview:A")

        let previous = try XCTUnwrap(state.begin(speaker, contextID: "turn:1:A"))
        XCTAssertEqual(previous.label, " \n\t ")
        XCTAssertEqual(state.draft?.label, "Speaker A")
        XCTAssertEqual(state.finish(contextID: "turn:1:A")?.label, "Speaker A")
    }

    func testReopeningTheActiveEditorPreservesDraftAndEscapeDiscardsIt() {
        var state = SpeakerRenameState()
        let speaker = SpeakerInfo(id: "A", label: "Speaker A")
        state.begin(speaker, contextID: "overview:A")
        state.updateLabel("QA Alice", contextID: "overview:A")

        XCTAssertNil(state.begin(speaker, contextID: "overview:A"))
        XCTAssertEqual(state.draft?.label, "QA Alice")
        XCTAssertTrue(state.cancel(contextID: "overview:A"))
        XCTAssertNil(state.finish(contextID: "overview:A"), "The blur after Escape must not submit the draft")
        XCTAssertNil(state.draft)
    }
}
