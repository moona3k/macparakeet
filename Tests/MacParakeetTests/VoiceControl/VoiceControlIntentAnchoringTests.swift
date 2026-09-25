import Foundation
import XCTest

@testable import MacParakeetCore

/// Local routes run before the page's own controls, so they must fire only on
/// an explicit request. A word that merely appears in a command is page content.
final class VoiceControlIntentAnchoringTests: XCTestCase {
    private struct Fallback: VoiceControlDecisionEngine {
        func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
            -> VoiceControlDecision
        { .clarify("fallback") }
    }

    private let router = VoiceControlCommandRouter(fallback: Fallback())

    /// A shop page in Chrome: the adapter always appends the allowlisted destinations.
    private func shopPage() -> VoiceControlSnapshot {
        VoiceControlSnapshot(
            contextID: "ax:1", applicationName: "Google Chrome",
            targets: [
                VoiceControlTarget(
                    id: "n:0", label: "Search Amazon", role: "AXTextField", value: "",
                    operations: [.setValue, .insertText, .press], isFocused: true),
                VoiceControlTarget(id: "n:1", label: "Go", role: "AXButton", operations: [.press]),
            ]
                + VoiceControlWebDestination.all.map {
                    VoiceControlTarget(
                        id: $0.id, label: $0.label, role: "url", operations: [.press], isNavigation: true)
                },
            summary: "Amazon.com")
    }

    private func openedDestination(_ decision: VoiceControlDecision) -> String? {
        guard case .action(let action) = decision, action.targetID.hasPrefix("web:") else { return nil }
        return action.targetID
    }

    func testPageCommandsThatMentionASiteStayOnThePage() async throws {
        for goal in [
            "search for headphones", "click the YouTube link", "reply to the email about my flight",
            "open the flight confirmation", "press the Gmail button",
            "reply to Sarah with directions to the office", "forward Bob the directions to the office",
            "forward the flights to Paris email", "text Mia the flights from Boston",
            "forward the video on YouTube to Sarah", "find the email about my flight",
            "reply to the email about my flight to Denver", "forward the flights to Paris email",
        ] {
            let decision = try await router.decide(goal: goal, snapshot: shopPage(), history: [])
            XCTAssertNil(openedDestination(decision), "\(goal) must not navigate away")
        }
    }

    func testExplicitDestinationRequestsStillNavigate() async throws {
        let expected = [
            "Find flights to London": "web:google-flights",
            "Find one-way flights from Zurich to London on September 20 2026.": "web:google-flights",
            "flights from Boston to Denver": "web:google-flights",
            "find cheap flights to Rome": "web:google-flights",
            "open YouTube": "web:youtube",
            "Play the Apollo 11 documentary on YouTube": "web:youtube",
            "go to Gmail": "web:gmail",
            "Look up Alan Turing on Wikipedia": "web:wikipedia",
            "Directions to the Golden Gate Bridge": "web:google-maps",
            "get directions to the office": "web:google-maps",
            "Compose a new email in Gmail": "web:gmail",
            "Search the web for weather in London": "web:google-search",
        ]
        for (goal, destination) in expected {
            let decision = try await router.decide(goal: goal, snapshot: shopPage(), history: [])
            XCTAssertEqual(openedDestination(decision), destination, goal)
        }
    }

    func testMailAboutAFlightDoesNotSwitchToTheBrowser() async throws {
        let mail = VoiceControlSnapshot(
            contextID: "ax:2", applicationName: "Mail",
            targets: [
                VoiceControlTarget(id: "n:0", label: "Reply", role: "AXButton", operations: [.press]),
                VoiceControlTarget(
                    id: "app:9", label: "Google Chrome", role: "application", operations: [.activateApp],
                    isNavigation: true),
            ])
        let decision = try await router.decide(goal: "reply to the email about my flight", snapshot: mail, history: [])
        if case .action(let action) = decision { XCTAssertNotEqual(action.operation, .activateApp) }
        let login = try await router.decide(goal: "reply that the login fails in Chrome", snapshot: mail, history: [])
        if case .action(let action) = login { XCTAssertNotEqual(action.operation, .activateApp) }
        let search = try await router.decide(goal: "find flights to Paris", snapshot: mail, history: [])
        XCTAssertEqual(search, .action(VoiceControlAction(operation: .activateApp, targetID: "app:9")))
        let named = try await router.decide(goal: "open the release notes in Chrome", snapshot: mail, history: [])
        XCTAssertEqual(named, .action(VoiceControlAction(operation: .activateApp, targetID: "app:9")))
    }

    /// Only the current request of an amended goal routes: the newest
    /// correction, else the original. A correction that names no site abandons
    /// the earlier one; a clarification answers a question and keeps it.
    func testAmendedGoalRoutesOnlyItsCurrentRequest() async throws {
        let abandoned =
            VoiceControlGoalText.header + "find flights to London\n" + VoiceControlGoalText.correction
            + "actually reply to the email about my flight instead"
        XCTAssertNil(VoiceControlWebDestination.matchingGoal(abandoned.lowercased()))
        let decision = try await router.decide(goal: abandoned, snapshot: shopPage(), history: [])
        XCTAssertNil(openedDestination(decision), "the cancelled destination must not open")
        let restated =
            VoiceControlGoalText.header + "Find one-way flights to London\n" + VoiceControlGoalText.correction
            + "actually find flights to Paris"
        XCTAssertEqual(VoiceControlWebDestination.matchingGoal(restated.lowercased())?.id, "web:google-flights")
        XCTAssertNil(VoiceControlFlightPlan.parse(restated), "a correction belongs to the model, not the form plan")
        let answered =
            VoiceControlGoalText.header + "Find flights to London\n" + VoiceControlGoalText.clarification + "2"
        XCTAssertEqual(VoiceControlWebDestination.matchingGoal(answered.lowercased())?.id, "web:google-flights")
        let query =
            VoiceControlGoalText.header + "play jazz on YouTube\n" + VoiceControlGoalText.correction
            + "actually play blues on YouTube"
        XCTAssertEqual(VoiceControlWebQuery.parse(query)?.query, "blues", "the scaffold never becomes the query")
        let picked =
            VoiceControlGoalText.header + "Find flights from Boston to Rome\n" + VoiceControlGoalText.clarification
            + "2"
        let plan = VoiceControlFlightPlan.parse(picked)
        XCTAssertEqual(plan?.origin, "Boston")
        XCTAssertEqual(plan?.destination, "Rome", "an answer to a pick is not typed into the form")
        let handEdited =
            VoiceControlGoalText.header + "Find flights from Boston to Rome\n" + VoiceControlGoalText.manualHeader
            + "\nWhere to?: Milan"
        XCTAssertNil(VoiceControlFlightPlan.parse(handEdited), "the plan must not overwrite a hand-edited field")
        let pressed = VoiceControlGoalText.header + "open YouTube\n" + VoiceControlGoalText.correction + "click Go"
        XCTAssertNil(VoiceControlWebDestination.matchingGoal(pressed.lowercased()))
    }

    func testSiteQueriesNeedAQueryVerb() {
        XCTAssertNil(VoiceControlWebQuery.parse("like this video on YouTube"))
        XCTAssertNil(VoiceControlWebQuery.parse("click the Wikipedia logo"))
        XCTAssertEqual(
            VoiceControlWebQuery.parse("Play the Apollo 11 documentary on YouTube")?.query,
            "the Apollo 11 documentary")
        XCTAssertEqual(VoiceControlWebQuery.parse("Look up Alan Turing on Wikipedia")?.query, "Alan Turing")
        XCTAssertEqual(
            VoiceControlWebQuery.parse("Search the web for weather in London")?.query, "weather in London")
        XCTAssertEqual(VoiceControlWebQuery.parse("navigate to the station on Google Maps")?.query, "the station")
    }

    /// A closed form's date button names no date. It must not turn an ordinary
    /// page into a date picker that hides every other control from the decision.
    func testDateButtonWithoutADateLeavesThePagePlain() {
        let snapshot = VoiceControlSnapshot(
            contextID: "ax:3", applicationName: "Safari",
            targets: [
                VoiceControlTarget(id: "n:0", label: "Choose departure date", role: "AXButton", operations: [.press]),
                VoiceControlTarget(id: "n:1", label: "Add to cart", role: "AXButton", operations: [.press]),
            ])
        XCTAssertEqual(VoiceControlSituation.classify(snapshot), .plain)
        XCTAssertEqual(VoiceControlLegality.offeredTargets(in: snapshot).map(\.id), ["n:0", "n:1"])
        let open = VoiceControlSnapshot(
            contextID: "ax:3", applicationName: "Safari",
            targets: [
                VoiceControlTarget(
                    id: "n:2", label: "Sunday, September 20, 2026, departure date. , 276 US dollars",
                    role: "AXButton", operations: [.press]),
                VoiceControlTarget(id: "n:1", label: "Add to cart", role: "AXButton", operations: [.press]),
            ])
        XCTAssertEqual(VoiceControlSituation.classify(open), .datePicker)
        let selected = VoiceControlTarget(
            id: "n:3", label: "Departure date: September 20, 2026", role: "AXButton", operations: [.press])
        XCTAssertFalse(VoiceControlLegality.isCalendarDay(selected), "a field button showing its date is not a day")
    }

    /// `Submit search` stays ordinary by design; a final submit is left to the
    /// model's consequence head. These words have no ordinary short reading.
    func testDiscardUninstallAndDonateConfirmEvenWhenTheModelSaysOrdinary() {
        for (label, expected) in [
            ("Discard draft", VoiceControlConsequence.destructive), ("Uninstall", .destructive),
            ("Donate now", .payment),
        ] {
            let target = VoiceControlTarget(id: "n:0", label: label, role: "AXButton", operations: [.press])
            let action = VoiceControlAction(operation: .press, targetID: "n:0", consequence: .ordinary)
            XCTAssertEqual(VoiceControlConsequencePolicy.consequence(of: action, target: target), expected, label)
        }
    }

    /// A one-shot press that moved the interface is finished. The next screen
    /// must not become an open-ended model request the person never made.
    func testNamedPressThatChangedTheScreenFinishesWithoutTheModel() async throws {
        let dialogClosed = VoiceControlSnapshot(
            contextID: "ax:4", applicationName: "TextEdit",
            targets: [VoiceControlTarget(id: "n:0", label: "Cancel", role: "AXButton", operations: [.press])])
        for (goal, pressed) in [("click Save", "Save"), ("Save", "Save"), ("click Search", "Search flights")] {
            let history = [
                VoiceControlAction(
                    operation: .press, targetID: "n:7", targetLabel: pressed, receiptStatus: .transitionObserved)
            ]
            let decision = try await router.decide(goal: goal, snapshot: dialogClosed, history: history)
            XCTAssertEqual(decision, .finished, goal)
        }
    }
}
