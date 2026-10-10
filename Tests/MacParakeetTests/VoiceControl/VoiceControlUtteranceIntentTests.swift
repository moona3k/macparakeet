import XCTest
@testable import MacParakeetCore

/// Which pending response an utterance belongs to (H5/H6): an answer to the
/// open question, a correction of the open task, or a new instruction.
final class VoiceControlUtteranceIntentTests: XCTestCase {
    private typealias Intent = VoiceControlUtteranceIntent
    private let clarifying = Intent.State(awaitingClarification: true, hasOpenTask: true)
    private let confirming = Intent.State(awaitingConfirmation: true, hasOpenTask: true)
    private let running = Intent.State(hasOpenTask: true)
    private let closed = Intent.State(hasOpenTask: true, taskClosed: true)

    func testAnswersToAClarification() {
        for text in [
            "2", "two", "the second one", "number 3", "option two", "select the second one", "pick 2",
            "Rome, Italy", "the blue one", "Inbox", "London Heathrow", "no",
            // Words that also open ordinary answers are not commands.
            "New York trip", "Find a time to meet", "Show details", "Close", "down", "escape", "return",
            "search for cats",
        ] {
            XCTAssertEqual(Intent.classify(text, state: clarifying), .answer, text)
        }
        let picks = Intent.State(awaitingClarification: true, hasOpenTask: true, offeredLabels: ["Open", "Close"])
        XCTAssertEqual(Intent.classify("Open", state: picks), .answer, "an offered label is an answer, not a verb")
        XCTAssertEqual(Intent.classify("close.", state: picks), .answer)
        XCTAssertEqual(Intent.classify("open Safari", state: picks), .newInstruction)
    }

    func testCommandsDuringAClarificationStartANewTask() {
        for text in [
            "open Safari", "click Save", "press return", "tap Done", "type hello", "scroll down", "go to Gmail",
            "show commands", "new message", "new tab", "help", "undo", "Undo that", "switch to Mail",
            "Please open Notes", "What can I say?", "select the Inbox row",
        ] {
            XCTAssertEqual(Intent.classify(text, state: clarifying), .newInstruction, text)
        }
    }

    func testCorrectionsOnlyReviseAnOpenTask() {
        for text in [
            "actually London", "no, the other one", "No Paris", "instead use Rome", "the other one", "other one",
            "make it shorter", "change the title to Draft", "not that one", "change that", "Use Rome instead",
            "actually open Safari", "No, click Cancel",
        ] {
            XCTAssertEqual(Intent.classify(text, state: running), .correction, text)
            XCTAssertEqual(Intent.classify(text, state: clarifying), .correction, text)
            XCTAssertEqual(Intent.classify(text, state: closed), .newInstruction, "closed: \(text)")
            XCTAssertEqual(Intent.classify(text, state: .init()), .newInstruction, "no task: \(text)")
        }
    }

    func testUndoIsACommandNeverACorrection() {
        for state in [running, clarifying, closed, confirming, Intent.State()] {
            XCTAssertEqual(Intent.classify("undo", state: state), .newInstruction)
            XCTAssertEqual(Intent.classify("undo last edit", state: state), .newInstruction)
        }
    }

    func testWithoutAPendingQuestionEverythingElseIsANewInstruction() {
        for text in ["2", "Rome", "find flights to Paris", "open Safari", "Save"] {
            XCTAssertEqual(Intent.classify(text, state: running), .newInstruction, text)
            XCTAssertEqual(Intent.classify(text, state: closed), .newInstruction, text)
            XCTAssertEqual(Intent.classify(text, state: .init()), .newInstruction, text)
        }
        // A closed task cannot be awaiting anything.
        let stale = Intent.State(awaitingClarification: true, hasOpenTask: true, taskClosed: true)
        XCTAssertEqual(Intent.classify("2", state: stale), .newInstruction)
    }

    func testConfirmationWordsAnswerAPendingConfirmation() {
        for text in ["yes", "Confirm", "confirm this action", "no", "cancel", "cancel task"] {
            XCTAssertEqual(Intent.classify(text, state: confirming), .answer, text)
        }
        XCTAssertEqual(Intent.classify("okay", state: confirming), .newInstruction, "okay never authorizes")
        XCTAssertEqual(Intent.classify("open Safari", state: confirming), .newInstruction)
        XCTAssertEqual(Intent.classify("actually the other one", state: confirming), .correction)
    }

    func testCommandShapeIgnoresNounsThatShareAVerbsSpelling() {
        XCTAssertTrue(Intent.isCommandShaped("open the first email"))
        XCTAssertTrue(Intent.isCommandShaped("Go to search results"))
        XCTAssertFalse(Intent.isCommandShaped("opened files"))
        XCTAssertFalse(Intent.isCommandShaped("goto"))
        XCTAssertFalse(Intent.isCommandShaped("the second one"))
        XCTAssertFalse(Intent.isCommandShaped("select 2"), "a spoken pick answers; it does not command")
        XCTAssertFalse(Intent.isCommandShaped(""))
    }

    /// An amended goal keeps its local routes: the newest user segment routes
    /// when it is itself a command. Answers (`2`) and text entry stay with the model.
    func testAmendedGoalRoutesItsNewestCommandSegmentLocally() async throws {
        let router = VoiceControlCommandRouter(fallback: MustNotDecide())
        let notes = VoiceControlSnapshot(
            contextID: "test", applicationName: "Notes",
            targets: [
                VoiceControlTarget(
                    id: "field", label: "Body", role: "text", value: "hello",
                    operations: [.insertText, .setValue, .key], isFocused: true),
                VoiceControlTarget(id: "undo", label: "Undo", role: "undo", operations: [.press]),
                VoiceControlTarget(id: "save", label: "Save", role: "AXButton", operations: [.press]),
                VoiceControlTarget(id: "revert", label: "Revert", role: "AXButton", operations: [.press]),
                VoiceControlTarget(id: "app:s", label: "Safari", role: "application", operations: [.activateApp]),
            ])
        let typed = VoiceControlAction(
            operation: .insertText, targetID: "field", value: "hello", receiptStatus: .verified)
        let undo = VoiceControlGoalText.header + "type hello\n" + VoiceControlGoalText.correction + "undo"
        let first = try await router.decide(goal: undo, snapshot: notes, history: [typed])
        XCTAssertEqual(first, .action(VoiceControlAction(operation: .press, targetID: "undo")))
        let undone = VoiceControlAction(
            operation: .press, targetID: "undo", targetLabel: "Undo", receiptStatus: .verified)
        let second = try await router.decide(goal: undo, snapshot: notes, history: [typed, undone])
        XCTAssertEqual(second, .directCompleted("Done. The requested change was verified."))
        let clarified =
            VoiceControlGoalText.header + "scroll down\n" + VoiceControlGoalText.clarification + "open Safari"
        let opened = try await router.decide(goal: clarified, snapshot: notes, history: [])
        XCTAssertEqual(opened, .action(VoiceControlAction(operation: .activateApp, targetID: "app:s")))
        let saved = VoiceControlAction(
            operation: .press, targetID: "save", targetLabel: "Save", receiptStatus: .verified)
        let corrected =
            VoiceControlGoalText.header + "click Save\n" + VoiceControlGoalText.correction + "actually click Revert"
        let revert = try await router.decide(goal: corrected, snapshot: notes, history: [saved])
        XCTAssertEqual(revert, .action(VoiceControlAction(operation: .press, targetID: "revert")))

        let fallback = RecordingFallback()
        let model = VoiceControlCommandRouter(fallback: fallback)
        let numbered = VoiceControlSnapshot(
            contextID: "test", applicationName: "Calendar",
            targets: [VoiceControlTarget(id: "day2", label: "2", role: "AXButton", operations: [.press])])
        let answered = VoiceControlGoalText.header + "book a room\n" + VoiceControlGoalText.clarification + "2"
        _ = try await model.decide(goal: answered, snapshot: numbered, history: [])
        let retyped = VoiceControlGoalText.header + "type Paris\n" + VoiceControlGoalText.correction + "no, type Rome"
        _ = try await model.decide(goal: retyped, snapshot: notes, history: [typed])
        let seen = await fallback.goals
        XCTAssertEqual(seen, [answered, retyped], "an answer and a text correction belong to the model")
    }
}

private struct MustNotDecide: VoiceControlDecisionEngine {
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        XCTFail("Unexpected semantic request for a local command: \(goal)")
        return .clarify("Unexpected request")
    }
}

private actor RecordingFallback: VoiceControlDecisionEngine {
    var goals: [String] = []
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        goals.append(goal)
        return .clarify("fallback")
    }
}
