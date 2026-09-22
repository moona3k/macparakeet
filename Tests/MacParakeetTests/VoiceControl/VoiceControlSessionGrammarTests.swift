import XCTest
@testable import MacParakeetCore

final class VoiceControlSessionGrammarTests: XCTestCase {
    func testAccessibilityAliasesEnterAndLeaveLiteralMode() {
        for phrase in ["typing mode", "start typing", "activate type", "type mode", "literal mode", "dictation mode"] {
            XCTAssertEqual(
                VoiceControlSessionGrammar.phrase(phrase, literalMode: false), .enterLiteral, phrase)
        }
        for phrase in ["command mode", "stop typing", "command-mode"] {
            XCTAssertEqual(
                VoiceControlSessionGrammar.phrase(phrase, literalMode: true), .exitLiteral, phrase)
        }
        XCTAssertEqual(VoiceControlSessionGrammar.phrase("  typing   mode  ", literalMode: false), .enterLiteral)
        XCTAssertEqual(VoiceControlSessionGrammar.phrase("typing-mode", literalMode: false), .enterLiteral)
        XCTAssertEqual(VoiceControlSessionGrammar.phrase("command stop", literalMode: true), .stopFromLiteral)
    }

    func testLiteralPayloadIsNotASessionCommand() {
        XCTAssertNil(VoiceControlSessionGrammar.phrase("stop", literalMode: true))
        XCTAssertNil(VoiceControlSessionGrammar.phrase("click send", literalMode: true))
        XCTAssertNil(VoiceControlSessionGrammar.phrase("please mode reset the form", literalMode: true))
        XCTAssertNil(VoiceControlSessionGrammar.phrase("activate type mode later", literalMode: false))
        XCTAssertNil(VoiceControlSessionGrammar.phrase("Find flights to London", literalMode: false))
    }

    func testCommandModeIsIgnoredUntilLiteralModeIsOn() {
        XCTAssertNil(VoiceControlSessionGrammar.phrase("command mode", literalMode: false))
        XCTAssertNil(VoiceControlSessionGrammar.phrase("stop typing", literalMode: false))
    }

    func testFillerWordsDoNotAuthorizeConfirmation() {
        for phrase in ["yes", "yes.", "Confirm", "confirm this action"] {
            XCTAssertTrue(VoiceControlSessionGrammar.acceptsConfirmation(phrase), phrase)
        }
        for phrase in ["ok", "okay", "alright", "yep", "sure", "go ahead"] {
            XCTAssertFalse(VoiceControlSessionGrammar.acceptsConfirmation(phrase), phrase)
        }
        for phrase in ["no", "cancel", "cancel task"] {
            XCTAssertTrue(VoiceControlSessionGrammar.declinesConfirmation(phrase), phrase)
        }
        XCTAssertFalse(VoiceControlSessionGrammar.declinesConfirmation("not that one"))
    }

    func testConfirmationNamesTheEffectAndTheDecline() {
        let action = VoiceControlAction(operation: .press, targetID: "pay", consequence: .payment)
        let target = VoiceControlTarget(
            id: "pay", label: "Pay now", role: "AXButton", operations: [.press], consequence: .payment)
        let prompt = VoiceControlConfirmationCopy.prompt(action: action, target: target, consequence: .payment)
        XCTAssertTrue(prompt.contains("Pay now"))
        XCTAssertTrue(prompt.localizedStandardContains("payment"))
        XCTAssertTrue(prompt.localizedStandardContains("Nothing is paid"))
        XCTAssertTrue(prompt.localizedStandardContains("Cancel task"))
        XCTAssertFalse(prompt.localizedStandardContains("unchanged"))
        XCTAssertFalse(prompt.localizedStandardContains("always"))

        let unknown = VoiceControlConfirmationCopy.prompt(
            action: .init(operation: .press, targetID: "pay"),
            target: target,
            consequence: .unknown)
        XCTAssertTrue(unknown.contains("Pay now"))
        XCTAssertTrue(unknown.localizedStandardContains("can’t tell") || unknown.localizedStandardContains("can't tell"))
        XCTAssertFalse(unknown.localizedStandardContains("always"))

        let send = VoiceControlConfirmationCopy.prompt(
            action: .init(operation: .press, targetID: "send", consequence: .externalCommitment),
            target: .init(id: "send", label: "Send", role: "AXButton", operations: [.press]),
            consequence: .externalCommitment)
        XCTAssertTrue(send.localizedStandardContains("Nothing is sent"))
        XCTAssertFalse(send.localizedStandardContains("always"))
    }

    func testSpokenPickIsAnIsolatedIndex() {
        XCTAssertEqual(VoiceControlSpokenPick.index(in: "2", count: 3), 1)
        XCTAssertEqual(VoiceControlSpokenPick.index(in: "two", count: 3), 1)
        XCTAssertEqual(VoiceControlSpokenPick.index(in: "the second one", count: 3), 1)
        XCTAssertEqual(VoiceControlSpokenPick.index(in: "option 1", count: 3), 0)
        XCTAssertEqual(VoiceControlSpokenPick.index(in: "number one", count: 3), 0)
        XCTAssertEqual(VoiceControlSpokenPick.index(in: "one please", count: 3), 0)
        XCTAssertNil(VoiceControlSpokenPick.index(in: "the other one", count: 3))
        XCTAssertNil(VoiceControlSpokenPick.index(in: "12", count: 3))
        XCTAssertTrue(VoiceControlSpokenPick.prompt(labels: ["Alpha", "Beta"]).contains("1. Alpha"))
    }
}
