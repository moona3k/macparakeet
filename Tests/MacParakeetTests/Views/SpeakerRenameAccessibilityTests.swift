import XCTest
@testable import MacParakeet

final class SpeakerRenameAccessibilityTests: XCTestCase {
    func testOverviewToggleLabelsDescribeDisclosureAction() {
        XCTAssertEqual(
            SpeakerRenameAccessibility.overviewToggleLabel(isExpanded: true),
            "Collapse speaker overview"
        )
        XCTAssertEqual(
            SpeakerRenameAccessibility.overviewToggleLabel(isExpanded: false),
            "Expand speaker overview"
        )
        XCTAssertEqual(
            SpeakerRenameAccessibility.overviewToggleIdentifier,
            "transcript.speakerOverview.toggle"
        )
        XCTAssertEqual(
            SpeakerRenameAccessibility.overviewToggleHint,
            "Shows speaker labels and rename controls."
        )
    }

    func testRenameButtonLabelsAreSpeakerSpecificAndIdentifiersAreContextSpecific() {
        XCTAssertEqual(
            SpeakerRenameAccessibility.renameButtonLabel(for: "Others"),
            "Rename Others"
        )
        XCTAssertEqual(
            SpeakerRenameAccessibility.renameButtonIdentifier(contextID: "overview:speaker_1"),
            "transcript.speaker.rename.overview:speaker_1"
        )
        XCTAssertEqual(
            SpeakerRenameAccessibility.renameButtonHint,
            "Edits this speaker label for this meeting only."
        )
    }

    func testSpeakerRenameFieldAccessibilityMetadataIsStable() {
        XCTAssertEqual(SpeakerRenameAccessibility.speakerNameFieldLabel, "Speaker name")
        XCTAssertEqual(
            SpeakerRenameAccessibility.speakerNameFieldHint,
            "Press Return or move focus away to save. Press Escape to cancel."
        )
        XCTAssertEqual(
            SpeakerRenameAccessibility.speakerNameFieldIdentifier(contextID: "turn:speaker_1:1200:0"),
            "transcript.speaker.name.turn:speaker_1:1200:0"
        )
    }

    func testRenameButtonHoverRevealUsesOpacityValues() {
        XCTAssertEqual(
            SpeakerRenameAccessibility.renameButtonOpacity(isVisuallyRevealed: false),
            0
        )
        XCTAssertEqual(
            SpeakerRenameAccessibility.renameButtonOpacity(isVisuallyRevealed: true),
            1
        )
    }

    func testRenameContextIdentifiersSeparateOverviewAndRepeatedTimedTurns() {
        let overview = SpeakerRenameAccessibility.overviewRenameContextIdentifier(for: "speaker_1")
        let firstTurn = SpeakerRenameAccessibility.turnRenameContextIdentifier(
            speakerID: "speaker_1",
            firstStartMs: 1200,
            duplicateOrdinal: 0
        )
        let secondTurn = SpeakerRenameAccessibility.turnRenameContextIdentifier(
            speakerID: "speaker_1",
            firstStartMs: 1200,
            duplicateOrdinal: 1
        )

        XCTAssertEqual(overview, "overview:speaker_1")
        XCTAssertEqual(firstTurn, "turn:speaker_1:1200:0")
        XCTAssertEqual(secondTurn, "turn:speaker_1:1200:1")

        let renameButtonIdentifiers = [
            SpeakerRenameAccessibility.renameButtonIdentifier(contextID: overview),
            SpeakerRenameAccessibility.renameButtonIdentifier(contextID: firstTurn),
            SpeakerRenameAccessibility.renameButtonIdentifier(contextID: secondTurn),
        ]
        let speakerNameFieldIdentifiers = [
            SpeakerRenameAccessibility.speakerNameFieldIdentifier(contextID: overview),
            SpeakerRenameAccessibility.speakerNameFieldIdentifier(contextID: firstTurn),
            SpeakerRenameAccessibility.speakerNameFieldIdentifier(contextID: secondTurn),
        ]

        XCTAssertEqual(Set(renameButtonIdentifiers).count, 3)
        XCTAssertEqual(Set(speakerNameFieldIdentifiers).count, 3)
    }
}
