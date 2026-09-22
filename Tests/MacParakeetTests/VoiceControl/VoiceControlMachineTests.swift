import XCTest
@testable import MacParakeetCore

final class VoiceControlMachineTests: XCTestCase {
    func testCityOverlayClassifiesAsSuggestionPickerAndDoesNotEnableReturn() {
        let snapshot = overlaySnapshot(
            cities: ["London, United Kingdom", "London, Ontario, Canada"], focused: "London, United Kingdom")
        XCTAssertEqual(VoiceControlSituation.classify(snapshot), .suggestionPicker)
        XCTAssertFalse(VoiceControlLegality.offeredKeys(in: snapshot).contains("return"))
        let pressIDs = VoiceControlLegality.offeredTargets(in: snapshot).map(\.id)
        XCTAssertTrue(pressIDs.contains("c0"))
        XCTAssertFalse(pressIDs.contains("search"))
    }

    func testFocusedRowWithACommaOutsideAnOverlayIsPlain() {
        // Gmail: a focused message row whose subject contains a comma is not a city picker.
        let snapshot = VoiceControlSnapshot(
            contextID: "test", applicationName: "Google Chrome",
            targets: [
                VoiceControlTarget(id: "search", label: "Search mail", role: "AXTextField", value: "", operations: [.setValue, .key]),
                VoiceControlTarget(
                    id: "row", label: "Alice, Bob — Lunch Friday?, Inbox", role: "AXStaticText", operations: [.press],
                    isFocused: true),
                VoiceControlTarget(id: "compose", label: "Compose", role: "AXButton", operations: [.press]),
            ])
        XCTAssertEqual(VoiceControlSituation.classify(snapshot), .plain)
        XCTAssertTrue(VoiceControlLegality.offeredTargets(in: snapshot).map(\.id).contains("compose"))
        XCTAssertTrue(VoiceControlLegality.offeredKeys(in: snapshot).contains("return"))
        XCTAssertNil(VoiceControlOutcomes.competingLandings(in: snapshot, goal: "click Compose"))
    }

    func testFlightResultsWithAirportNamesAreNotASuggestionPicker() {
        let snapshot = VoiceControlSnapshot(
            contextID: "test", applicationName: "Google Chrome",
            targets: [
                VoiceControlTarget(
                    id: "from", label: "Where from?", role: "AXComboBox", value: "Zurich",
                    operations: [.setValue, .press, .key]),
                VoiceControlTarget(
                    id: "to", label: "Where to?", role: "AXComboBox", value: "London",
                    operations: [.setValue, .press]),
                VoiceControlTarget(
                    id: "search", label: "Search flights", role: "AXButton", operations: [.press]),
                VoiceControlTarget(
                    id: "r0", label: "Zurich Airport (ZRH)", role: "AXStaticText", operations: [.press]),
                VoiceControlTarget(
                    id: "r1", label: "London, United Kingdom", role: "AXStaticText", operations: [.press]),
            ])
        XCTAssertEqual(VoiceControlSituation.classify(snapshot), .plain)
        XCTAssertTrue(VoiceControlLegality.offeredKeys(in: snapshot).contains("return"))
        XCTAssertTrue(VoiceControlLegality.offeredTargets(in: snapshot).contains(where: { $0.id == "search" }))
        XCTAssertNil(VoiceControlOutcomes.competingLandings(in: snapshot, goal: "Find flights to London"))
    }

    func testDatePickerDoesNotEnableReturn() {
        let snapshot = VoiceControlSnapshot(
            contextID: "test", applicationName: "Google Chrome",
            targets: [
                VoiceControlTarget(
                    id: "day20",
                    label: "Sunday, September 20, 2026, departure date. , 276 US dollars",
                    role: "AXButton", operations: [.press]),
                VoiceControlTarget(
                    id: "from", label: "Where from?", role: "AXComboBox", value: "Zurich",
                    operations: [.setValue, .press, .key], isFocused: true),
                VoiceControlTarget(
                    id: "search", label: "Search flights", role: "AXButton", operations: [.press]),
            ])
        XCTAssertEqual(VoiceControlSituation.classify(snapshot), .datePicker)
        XCTAssertFalse(VoiceControlLegality.offeredKeys(in: snapshot).contains("return"))
        XCTAssertFalse(VoiceControlLegality.offeredTargets(in: snapshot).contains(where: { $0.id == "search" }))
    }

    func testPlainFormStillOffersReturn() {
        let snapshot = VoiceControlSnapshot(
            contextID: "test", applicationName: "Google Chrome",
            targets: [
                VoiceControlTarget(
                    id: "from", label: "Where from?", role: "AXComboBox", value: "Zurich",
                    operations: [.setValue, .press, .key], isFocused: true)
            ])
        XCTAssertEqual(VoiceControlSituation.classify(snapshot), .plain)
        XCTAssertTrue(VoiceControlLegality.offeredKeys(in: snapshot).contains("return"))
    }

    func testCompetingCitySuggestionsAreEnabledEventsForJev() async throws {
        let fallback = RecordingEventsFallback()
        let router = VoiceControlCommandRouter(fallback: fallback)
        let snapshot = overlaySnapshot(
            cities: ["London, United Kingdom", "Greater London, United Kingdom"], focused: nil)
        let result = try await router.decide(
            goal: "Find one-way flights from Zurich to London on September 20 2026.", snapshot: snapshot,
            history: [
                VoiceControlAction(
                    operation: .press, targetID: "web:google-flights", receiptStatus: .transitionObserved),
                VoiceControlAction(
                    operation: .setValue, targetID: "to", value: "London", receiptStatus: .verified),
            ])
        let events = await fallback.events
        XCTAssertEqual(result, .clarify("fallback"))
        XCTAssertEqual(events.map(\.action.targetID).sorted(), ["c0", "c1"])
        XCTAssertTrue(events.allSatisfy { $0.action.operation == .press })
        XCTAssertFalse(events.contains { $0.action.value == "return" })
    }

    func testUniqueCityMatchStillResolvesLocally() async throws {
        let router = VoiceControlCommandRouter(fallback: LocalMustNotDecide())
        let snapshot = overlaySnapshot(cities: ["Zürich, Switzerland"], focused: "Zürich, Switzerland")
        let result = try await router.decide(
            goal: "Find one-way flights from Zurich to London on September 20 2026.", snapshot: snapshot,
            history: [
                VoiceControlAction(
                    operation: .press, targetID: "web:google-flights", receiptStatus: .transitionObserved),
                VoiceControlAction(
                    operation: .setValue, targetID: "from", value: "Zurich", receiptStatus: .verified),
            ])
        XCTAssertEqual(
            result,
            .action(
                VoiceControlAction(
                    operation: .press, targetID: "c0", targetLabel: "Zürich, Switzerland", consequence: .ordinary,
                    postcondition: .selectedLabel("Zürich, Switzerland"))))
    }

    func testSpokenDatePressesTheMatchingCalendarDay() throws {
        let plan = try XCTUnwrap(
            VoiceControlFlightPlan.parse("Find one-way flights from Zurich to London on September 20 2026"))
        let snapshot = VoiceControlSnapshot(
            contextID: "test", applicationName: "Google Chrome",
            targets: [
                VoiceControlTarget(
                    id: "day20", label: "Saturday, September 20, 2026, $412", role: "AXButton", operations: [.press]),
                VoiceControlTarget(
                    id: "day21", label: "Sunday, September 21, 2026", role: "AXButton", operations: [.press]),
            ])
        let action = plan.nextAction(
            in: snapshot,
            history: [
                VoiceControlAction(
                    operation: .press, targetID: "web:google-flights", receiptStatus: .transitionObserved),
                VoiceControlAction(
                    operation: .setValue, targetID: "from", value: "Zurich", receiptStatus: .verified),
                VoiceControlAction(
                    operation: .setValue, targetID: "to", value: "London", receiptStatus: .verified),
                VoiceControlAction(
                    operation: .setValue, targetID: "departure", value: "September 20 2026",
                    receiptStatus: .verified),
            ])
        XCTAssertEqual(action?.operation, .press)
        XCTAssertEqual(action?.targetID, "day20")
    }

    func testJevEventChoiceExecutesOnlyTheOfferedEvent() async throws {
        let events = [
            VoiceControlEnabledEvent(
                id: "pick-london",
                criteria: "London, United Kingdom — city match for destination",
                action: VoiceControlAction(
                    operation: .press, targetID: "c0", targetLabel: "London, United Kingdom",
                    consequence: .ordinary, postcondition: .selectedLabel("London, United Kingdom")),
                postcondition: .selectedLabel("London, United Kingdom")),
            VoiceControlEnabledEvent(
                id: "pick-ontario",
                criteria: "London, Ontario, Canada — city match for destination",
                action: VoiceControlAction(
                    operation: .press, targetID: "c1", targetLabel: "London, Ontario, Canada",
                    consequence: .ordinary, postcondition: .selectedLabel("London, Ontario, Canada")),
                postcondition: .selectedLabel("London, Ontario, Canada")),
        ]
        let client = JevDecisionClient(
            apiKey: "test", consent: { true },
            transport: { request in
                let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                XCTAssertEqual((json?["state"] as? [String: Any])?["kind"] as? String, "outcome")
                let questions = json?["questions"] as? [String: [String: Any]]
                XCTAssertEqual(Set((questions ?? [:]).keys), ["outcome"])
                let criteria = questions?["outcome"]?["criteria"] as? [String: String]
                XCTAssertEqual(
                    Set((criteria ?? [:]).keys),
                    ["pick-london", "pick-ontario", "insufficient_evidence", "clarify"])
                XCTAssertNil(questions?["kind"])
                XCTAssertNil(questions?["key"])
                let answers: [String: Any] = [
                    "outcome": [
                        "type": "choice", "choice": "pick-london", "confidence": 0.9,
                        "probabilities": [
                            "pick-london": 0.7, "pick-ontario": 0.2, "insufficient_evidence": 0.05, "clarify": 0.05,
                        ],
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: [
                    "model": JevDecisionClient.model, "answers": answers,
                ])
                return (
                    data,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            })
        let decision = try await client.decide(
            goal: "Find flights to London", snapshot: overlaySnapshot(cities: ["London, United Kingdom"], focused: nil),
            history: [], events: events)
        XCTAssertEqual(decision, .action(events[0].action.withDecision(modelID: JevDecisionClient.model, confidence: 0.9)))
    }

    func testUnconstrainedJevOmitsReturnAndSearchOnCityOverlay() async throws {
        let capture = RequestBodyCapture()
        let snapshot = overlaySnapshot(
            cities: ["London, United Kingdom"], focused: "London, United Kingdom")
        let client = JevDecisionClient(
            apiKey: "test", consent: { true },
            transport: { request in
                await capture.record(request.httpBody ?? Data())
                return (
                    Data(),
                    HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
                )
            })
        do { _ = try await client.decide(goal: "Find flights to London", snapshot: snapshot, history: []) } catch {}
        let json = try JSONSerialization.jsonObject(with: await capture.body) as? [String: Any]
        let questions = json?["questions"] as? [String: [String: Any]]
        XCTAssertNil(questions?["key"])
        let kinds = questions?["kind"]?["criteria"] as? [String: String]
        XCTAssertFalse((kinds ?? [:]).keys.contains("key"))
        let targetCriteria = questions?["target"]?["criteria"] as? [String: String]
        XCTAssertFalse(
            (targetCriteria ?? [:]).keys.contains("search"), "Search is illegal while the picker is open")
        let observation = (json?["state"] as? [String: Any])?["observation"] as? [String: Any]
        let targets = observation?["targets"] as? [[String: Any]]
        XCTAssertEqual((targets ?? []).compactMap { $0["id"] as? String }.sorted(), ["c0", "else"])
    }

    func testCompetingPickerRowsAreOutcomeLandingsWithoutAFlightsParse() async throws {
        let fallback = RecordingEventsFallback()
        let router = VoiceControlCommandRouter(fallback: fallback)
        let snapshot = overlaySnapshot(
            cities: ["London, United Kingdom", "London, Ontario, Canada"], focused: nil)
        let result = try await router.decide(
            goal: "Which London, United Kingdom or Ontario?", snapshot: snapshot, history: [])
        let events = await fallback.events
        XCTAssertEqual(result, .clarify("fallback"))
        XCTAssertEqual(events.map(\.id).sorted(), ["c0", "c1"])
        XCTAssertEqual(events.map(\.postcondition), [
            .selectedLabel("London, United Kingdom"), .selectedLabel("London, Ontario, Canada"),
        ])
        XCTAssertTrue(events.allSatisfy { $0.criteria.hasPrefix("After the host acts,") })
    }

    func testFormChromeIsNotALandingBoard() {
        let landings = VoiceControlOutcomes.competingLandings(
            in: VoiceControlSnapshot(
                contextID: "test", applicationName: "Google Chrome",
                targets: [
                    VoiceControlTarget(
                        id: "from", label: "Where from?", role: "AXComboBox", operations: [.setValue, .press]),
                    VoiceControlTarget(
                        id: "to", label: "Where to?", role: "AXComboBox", operations: [.setValue, .press]),
                    VoiceControlTarget(
                        id: "search", label: "Search flights", role: "AXButton", operations: [.press]),
                ]),
            goal: "Find one-way flights from Zurich to London on September 20 2026.")
        XCTAssertNil(landings)
    }

    func testSelectedLabelPostconditionHoldsWhenTheRowIsFocused() {
        let snapshot = overlaySnapshot(cities: ["Zürich, Switzerland"], focused: "Zürich, Switzerland")
        XCTAssertTrue(VoiceControlPostcondition.selectedLabel("Zürich, Switzerland").holds(in: snapshot))
        XCTAssertFalse(VoiceControlPostcondition.selectedLabel("London, United Kingdom").holds(in: snapshot))
        XCTAssertFalse(VoiceControlPostcondition.unknown.holds(in: snapshot))
    }

    private func overlaySnapshot(cities: [String], focused: String?) -> VoiceControlSnapshot {
        var targets: [VoiceControlTarget] = []
        for (index, city) in cities.enumerated() {
            targets.append(
                VoiceControlTarget(
                    id: "c\(index)", label: city, role: "AXStaticText",
                    operations: [.press, .key], isFocused: city == focused))
        }
        targets.append(
            VoiceControlTarget(
                id: "else", label: "Where else?", role: "AXComboBox", operations: [.setValue, .press, .key]))
        targets.append(
            VoiceControlTarget(
                id: "search", label: "Search flights", role: "AXButton", operations: [.press]))
        return VoiceControlSnapshot(contextID: "test", applicationName: "Google Chrome", targets: targets)
    }
}

private struct LocalMustNotDecide: VoiceControlDecisionEngine {
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        XCTFail("Unexpected semantic request for an exact local command")
        return .clarify("Unexpected request")
    }
}

private actor RequestBodyCapture {
    var body = Data()
    func record(_ data: Data) { body = data }
}

private actor RecordingEventsFallback: VoiceControlDecisionEngine {
    var events: [VoiceControlEnabledEvent] = []
    func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        XCTFail("Unconstrained Jev should not run when enabled events exist")
        return .clarify("unconstrained")
    }
    func decide(
        goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction],
        events: [VoiceControlEnabledEvent]
    ) async throws -> VoiceControlDecision {
        self.events = events
        return .clarify("fallback")
    }
}

private extension VoiceControlAction {
    func withDecision(modelID: String, confidence: Double) -> VoiceControlAction {
        VoiceControlAction(
            operation: operation, targetID: targetID, value: value, targetLabel: targetLabel,
            requiresConfirmation: requiresConfirmation, receiptStatus: receiptStatus, consequence: consequence,
            modelID: modelID, decisionConfidence: confidence, postcondition: postcondition)
    }
}
