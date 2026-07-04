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

    func testRenameButtonLabelsAndIdentifiersAreSpeakerSpecific() {
        XCTAssertEqual(
            SpeakerRenameAccessibility.renameButtonLabel(for: "Others"),
            "Rename Others"
        )
        XCTAssertEqual(
            SpeakerRenameAccessibility.renameButtonIdentifier(for: "speaker_1"),
            "transcript.speaker.rename.speaker_1"
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
            SpeakerRenameAccessibility.speakerNameFieldIdentifier(for: "speaker_1"),
            "transcript.speaker.name.speaker_1"
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
        XCTAssertEqual(
            SpeakerRenameAccessibility.overviewRenameContextIdentifier(for: "speaker_1"),
            "overview:speaker_1"
        )
        XCTAssertEqual(
            SpeakerRenameAccessibility.turnRenameContextIdentifier(
                speakerID: "speaker_1",
                firstStartMs: 1200,
                duplicateOrdinal: 0
            ),
            "turn:speaker_1:1200:0"
        )
        XCTAssertEqual(
            SpeakerRenameAccessibility.turnRenameContextIdentifier(
                speakerID: "speaker_1",
                firstStartMs: 1200,
                duplicateOrdinal: 1
            ),
            "turn:speaker_1:1200:1"
        )
    }
}
