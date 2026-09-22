import Foundation

/// Deterministic parse of a spoken/typed flight search. Used only for local
/// form filling on an already-open Google Flights page; Jev still handles
/// unfamiliar follow-up controls.
public struct VoiceControlFlightPlan: Equatable, Sendable {
    public var origin: String?
    public var destination: String?
    public var date: String?
    public var oneWay: Bool

    public static func parse(_ goal: String) -> VoiceControlFlightPlan? {
        let lower = goal.lowercased()
        guard VoiceControlWebDestination.matchingGoal(lower)?.id == "web:google-flights" else { return nil }
        var plan = VoiceControlFlightPlan(origin: nil, destination: nil, date: nil, oneWay: isOneWay(lower))
        guard let fromRange = goal.range(of: " from ", options: .caseInsensitive),
            let toRange = goal.range(
                of: " to ", options: .caseInsensitive, range: fromRange.upperBound..<goal.endIndex)
        else { return plan.oneWay ? plan : nil }
        var destEnd = goal.endIndex
        if let onRange = goal.range(
            of: " on ", options: .caseInsensitive, range: toRange.upperBound..<goal.endIndex)
        {
            destEnd = onRange.lowerBound
            plan.date = trimmed(String(goal[onRange.upperBound...]))
        }
        plan.origin = trimmed(String(goal[fromRange.upperBound..<toRange.lowerBound]))
        plan.destination = trimmed(String(goal[toRange.upperBound..<destEnd]))
        if plan.origin?.isEmpty == true { plan.origin = nil }
        if plan.destination?.isEmpty == true { plan.destination = nil }
        return plan
    }

    /// Legal next moves. One event is executed locally; several become Jev Choices.
    public func frame(in snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) -> VoiceControlMachineFrame {
        let situation = VoiceControlSituation.classify(snapshot)
        if let competing = competingCitySuggestions(in: snapshot, history: history), competing.count > 1 {
            return VoiceControlMachineFrame(
                machine: "flights", situation: situation, state: "choose_suggestion", events: competing)
        }
        if let action = nextAction(in: snapshot, history: history) {
            return VoiceControlMachineFrame(
                machine: "flights", situation: situation, state: situation.rawValue,
                events: [
                    VoiceControlEnabledEvent(
                        id: "\(action.operation.rawValue):\(action.targetID)",
                        criteria: action.targetLabel ?? action.value ?? action.operation.rawValue,
                        action: action)
                ])
        }
        return VoiceControlMachineFrame(machine: "flights", situation: situation, state: "blocked", events: [])
    }

    public func nextAction(in snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) -> VoiceControlAction? {
        if oneWay {
            if let oneWayControl = snapshot.targets.first(where: {
                $0.operations.contains(.press) && $0.role != "url"
                    && $0.label.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare("One way") == .orderedSame
            }),
                !history.contains(where: {
                    $0.referring(to: oneWayControl)
                        && ($0.receiptStatus == .verified || $0.receiptStatus == .transitionObserved)
                })
            {
                return ordinary(.press, oneWayControl.id)
            }
        }
        if let option = bestFollowUpSuggestion(in: snapshot, history: history),
            !alreadyPressed(option.label, history: history),
            !isStaleOriginSuggestion(option, history: history)
        {
            return VoiceControlAction(
                operation: .press, targetID: option.id, targetLabel: option.label, consequence: .ordinary,
                postcondition: .selectedLabel(option.label))
        }
        if let origin, let field = field(in: snapshot, matching: ["where from"]),
            needs(field, expected: origin, history: history), field.operations.contains(.setValue)
        {
            return ordinary(.setValue, field.id, origin)
        }
        if overlayIsOpen(snapshot) { return dismissOverlay(snapshot, history: history) }
        if !originIsReady(snapshot, history: history) { return nil }
        if !destinationIsReady(snapshot, history: history),
            let destination,
            let field = field(in: snapshot, matching: ["where to", "where else"]),
            needs(field, expected: destination, history: history), field.operations.contains(.setValue)
        {
            return ordinary(.setValue, field.id, destination)
        }
        if !destinationIsReady(snapshot, history: history) { return dismissOverlay(snapshot, history: history) }
        if let date, let day = bestDateSuggestion(date, in: snapshot), !alreadyPressed(day.label, history: history) {
            return ordinary(.press, day.id, label: day.label)
        }
        if let date, !dateIsReady(snapshot, history: history) {
            if let field = field(in: snapshot, matching: ["departure", "dates"]),
                needs(field, expected: date, history: history), field.operations.contains(.setValue)
            {
                return ordinary(.setValue, field.id, date)
            }
            return dismissOverlay(snapshot, history: history)
        }
        if let overlay = dismissOverlay(snapshot, history: history) { return overlay }
        if let search = snapshot.targets.first(where: Self.isSearchControl),
            !history.contains(where: {
                $0.referring(to: search) && $0.receiptStatus == .transitionObserved
            })
        {
            return ordinary(.press, search.id)
        }
        if overlayIsOpen(snapshot) { return dismissOverlay(snapshot, history: history) }
        if VoiceControlSituation.classify(snapshot) == .plain,
            let focused = snapshot.targets.first(where: { $0.isFocused && $0.operations.contains(.key) }),
            !history.contains(where: { $0.operation == .key && $0.value == "return" })
        {
            return ordinary(.key, focused.id, "return")
        }
        return nil
    }

    private func competingCitySuggestions(in snapshot: VoiceControlSnapshot, history: [VoiceControlAction])
        -> [VoiceControlEnabledEvent]?
    {
        guard let last = history.last, last.operation == .setValue, let value = last.value, value.count >= 3,
            last.receiptStatus == .verified || last.receiptStatus == .transitionObserved
        else { return nil }
        let matches = snapshot.targets.filter {
            VoiceControlLegality.isCitySuggestion($0) && $0.label.localizedStandardContains(value)
                && !alreadyPressed($0.label, history: history) && !isStaleOriginSuggestion($0, history: history)
        }
        let cities = matches.filter {
            $0.label.contains(",") && !$0.label.localizedStandardContains("Airport")
        }
        let pool = cities.count > 1 ? cities : matches
        guard pool.count > 1, !pool.contains(where: \.isFocused) else { return nil }
        return pool.map {
            VoiceControlEnabledEvent(
                id: $0.id,
                criteria: VoiceControlOutcomes.criteria(landing: $0.label),
                action: ordinary(.press, $0.id, label: $0.label),
                postcondition: .selectedLabel($0.label))
        }
    }

    private static func isOneWay(_ lower: String) -> Bool {
        lower.contains("one-way") || lower.contains("one way") || lower.contains("oneway")
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func isSearchControl(_ target: VoiceControlTarget) -> Bool {
        let label = target.label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.operations.contains(.press), target.role != "url", target.role != "application" else {
            return false
        }
        if label == "search flights" || label.hasPrefix("search flights ") { return true }
        if label == "search" && target.role == "AXButton" { return true }
        return label == "explore" && target.role == "AXButton"
    }

    private func field(in snapshot: VoiceControlSnapshot, matching needles: [String]) -> VoiceControlTarget? {
        snapshot.targets.first { target in
            let label = target.label.lowercased()
            return needles.contains { label.contains($0) }
                && (target.operations.contains(.setValue) || target.operations.contains(.press))
                && target.role != "url" && target.role != "application"
        }
    }

    private func needs(_ target: VoiceControlTarget, expected: String, history: [VoiceControlAction]) -> Bool {
        if alreadyFilled(target, with: expected, history: history) { return false }
        let current = (target.value ?? "").lowercased()
        return current.isEmpty || !current.contains(expected.lowercased())
    }

    private func formIsHidden(_ snapshot: VoiceControlSnapshot) -> Bool {
        field(in: snapshot, matching: ["where from"]) == nil
            && field(in: snapshot, matching: ["where to"]) == nil
            && field(in: snapshot, matching: ["departure"]) == nil
    }

    private func originIsReady(_ snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) -> Bool {
        slotIsReady(origin, fieldNeedles: ["where from"], snapshot: snapshot, history: history)
    }

    private func destinationIsReady(_ snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) -> Bool {
        slotIsReady(destination, fieldNeedles: ["where to"], snapshot: snapshot, history: history)
    }

    private func dateIsReady(_ snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) -> Bool {
        slotIsReady(date, fieldNeedles: ["departure", "dates"], snapshot: snapshot, history: history)
    }

    private func slotIsReady(
        _ expected: String?, fieldNeedles: [String], snapshot: VoiceControlSnapshot, history: [VoiceControlAction]
    ) -> Bool {
        guard let expected else { return true }
        if let field = field(in: snapshot, matching: fieldNeedles) {
            return !needs(field, expected: expected, history: history)
        }
        return history.contains {
            $0.operation == .setValue && $0.value?.caseInsensitiveCompare(expected) == .orderedSame
                && ($0.receiptStatus == .verified || $0.receiptStatus == .transitionObserved)
        }
    }

    private func overlayIsOpen(_ snapshot: VoiceControlSnapshot) -> Bool {
        VoiceControlSituation.classify(snapshot) != .plain
    }

    private func dismissOverlay(_ snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) -> VoiceControlAction? {
        guard overlayIsOpen(snapshot) || formIsHidden(snapshot) else { return nil }
        let lastEscape = history.last?.operation == .key && history.last?.value == "escape"
        if lastEscape {
            if let dest = field(in: snapshot, matching: ["where to", "where else", "departure", "dates"]),
                dest.operations.contains(.press),
                !alreadyPressed(dest.label, history: history)
            {
                return ordinary(.press, dest.id, label: dest.label)
            }
            return nil
        }
        guard let focused = snapshot.targets.first(where: { $0.isFocused && $0.operations.contains(.key) }) else {
            return nil
        }
        return VoiceControlAction(
            operation: .key, targetID: focused.id, value: "escape", targetLabel: focused.label,
            consequence: .ordinary)
    }

    private func alreadyPressed(_ label: String, history: [VoiceControlAction]) -> Bool {
        history.contains {
            $0.operation == .press && $0.targetLabel?.localizedStandardCompare(label) == .orderedSame
        }
    }

    private func isStaleOriginSuggestion(_ option: VoiceControlTarget, history: [VoiceControlAction]) -> Bool {
        guard let origin, let destination else { return false }
        return option.label.localizedStandardContains(origin)
            && history.contains {
                $0.operation == .setValue && $0.value?.localizedStandardCompare(destination) == .orderedSame
                    && ($0.receiptStatus == .verified || $0.receiptStatus == .transitionObserved)
            }
    }

    private func ordinary(
        _ operation: VoiceControlOperation, _ targetID: String, _ value: String? = nil, label: String? = nil
    ) -> VoiceControlAction {
        VoiceControlAction(
            operation: operation, targetID: targetID, value: value, targetLabel: label, consequence: .ordinary)
    }

    private func alreadyFilled(_ target: VoiceControlTarget, with expected: String, history: [VoiceControlAction])
        -> Bool
    {
        history.contains {
            $0.referring(to: target) && $0.value?.caseInsensitiveCompare(expected) == .orderedSame
                && ($0.receiptStatus == .verified || $0.receiptStatus == .transitionObserved)
        }
    }

    private func bestFollowUpSuggestion(in snapshot: VoiceControlSnapshot, history: [VoiceControlAction])
        -> VoiceControlTarget?
    {
        guard let last = history.last, last.operation == .setValue, let value = last.value, value.count >= 3,
            last.receiptStatus == .verified || last.receiptStatus == .transitionObserved
        else { return nil }
        if let dateMatch = bestDateSuggestion(value, in: snapshot) { return dateMatch }
        return bestCitySuggestion(value, in: snapshot)
    }

    private func bestDateSuggestion(_ value: String, in snapshot: VoiceControlSnapshot) -> VoiceControlTarget? {
        let pressable = snapshot.targets.filter {
            $0.operations.contains(.press) && $0.role != "url" && $0.role != "application"
        }
        let matches: [VoiceControlTarget]
        if let spoken = SpokenDateParser.firstDate(in: value) {
            let calendar = Calendar.current
            matches = pressable.filter { target in
                guard let labelDate = SpokenDateParser.firstDate(in: target.label) else { return false }
                return calendar.isDate(labelDate, inSameDayAs: spoken)
            }
        } else {
            let tokens = value.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            guard tokens.count >= 2 else { return nil }
            matches = pressable.filter { target in
                tokens.allSatisfy { token in containsToken(target.label, token) }
            }
        }
        let departure = matches.filter { $0.label.localizedStandardContains("departure date") }
        if departure.count == 1 { return departure[0] }
        if let focused = departure.first(where: \.isFocused) { return focused }
        return matches.count == 1 ? matches[0] : nil
    }

    private func containsToken(_ label: String, _ token: String) -> Bool {
        label.split { !$0.isLetter && !$0.isNumber }.contains {
            $0.localizedStandardCompare(token) == .orderedSame
        }
    }

    private func bestCitySuggestion(_ value: String, in snapshot: VoiceControlSnapshot) -> VoiceControlTarget? {
        let matches = snapshot.targets.filter {
            $0.operations.contains(.press) && $0.role != "url" && $0.role != "application"
                && !$0.label.localizedStandardContains("Toggle")
                && $0.label.localizedStandardContains(value)
        }
        if matches.count == 1 { return matches[0] }
        let cities = matches.filter {
            $0.label.contains(",") && !$0.label.localizedStandardContains("Airport")
        }
        if let focused = cities.first(where: \.isFocused) ?? matches.first(where: \.isFocused) {
            return focused
        }
        return cities.count == 1 ? cities[0] : nil
    }
}
