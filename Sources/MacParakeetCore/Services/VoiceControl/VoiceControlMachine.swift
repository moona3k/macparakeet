import Foundation

/// Observed interaction protocol, recomputed every snapshot. Not a persisted graph.
public enum VoiceControlSituation: String, Sendable, Equatable {
    case plain
    case suggestionPicker
    case datePicker

    public static func classify(_ snapshot: VoiceControlSnapshot) -> VoiceControlSituation {
        // Screen-text targets are pixels, not AX rows; they never open a picker.
        let targets = snapshot.targets.filter { $0.role != "text" }
        if targets.contains(where: VoiceControlLegality.isCalendarDay) { return .datePicker }
        // A picker is an overlay, and an overlay announces itself through its
        // chrome ("Where else?" is the field only the open overlay shows; the
        // form's own "Where from?" / "Where to?" are not chrome). A focused row
        // whose label merely contains a comma is not evidence: a Gmail subject
        // line or a Finder path row does that too. Without chrome the surface is plain.
        let overlayChrome = targets.contains { $0.label.localizedStandardContains("Where else") }
        guard overlayChrome else { return .plain }
        let cities = targets.filter(VoiceControlLegality.isCitySuggestion)
        if !cities.isEmpty { return .suggestionPicker }
        let focusedChoice = targets.contains {
            $0.isFocused && $0.operations.contains(.press) && $0.role == "AXStaticText"
        }
        return focusedChoice ? .suggestionPicker : .plain
    }
}

/// One legal transition the host is willing to execute. Jev may only pick among these.
public struct VoiceControlEnabledEvent: Equatable, Sendable, Identifiable {
    public let id: String
    public let criteria: String
    public let action: VoiceControlAction
    public let postcondition: VoiceControlPostcondition
    public init(
        id: String, criteria: String, action: VoiceControlAction,
        postcondition: VoiceControlPostcondition = .unknown
    ) {
        self.id = id; self.criteria = criteria; self.action = action; self.postcondition = postcondition
    }
}

/// What must be true on the next snapshot if this landing succeeded.
public enum VoiceControlPostcondition: Equatable, Sendable, Codable {
    case selectedLabel(String)
    case unknown

    public func holds(in snapshot: VoiceControlSnapshot) -> Bool {
        switch self {
        case .unknown:
            return false
        case .selectedLabel(let label):
            if snapshot.targets.contains(where: {
                $0.isFocused && $0.label.localizedStandardCompare(label) == .orderedSame
            }) {
                return true
            }
            let short = label.split(separator: ",").first.map(String.init) ?? label
            return snapshot.targets.contains {
                ($0.value ?? "").localizedStandardContains(short)
                    || $0.label.localizedStandardContains(short) && $0.isFocused
            }
        }
    }
}

public struct VoiceControlMachineFrame: Equatable, Sendable {
    public let machine: String
    public let situation: VoiceControlSituation
    public let state: String
    public let events: [VoiceControlEnabledEvent]
    public init(machine: String, situation: VoiceControlSituation, state: String, events: [VoiceControlEnabledEvent]) {
        self.machine = machine; self.situation = situation; self.state = state; self.events = events
    }
}

/// Code-owned legality for both domain machines and unconstrained Jev fallback.
public enum VoiceControlLegality {
    public static func isCitySuggestion(_ target: VoiceControlTarget) -> Bool {
        target.operations.contains(.press) && target.role != "url" && target.role != "application"
            && (target.label.contains(",") || target.label.localizedStandardContains("Airport"))
            && !target.label.localizedStandardContains("Toggle")
    }

    public static func isCalendarDay(_ target: VoiceControlTarget) -> Bool {
        target.operations.contains(.press) && target.label.localizedStandardContains("departure date")
    }

    public static func offeredTargets(in snapshot: VoiceControlSnapshot) -> [VoiceControlTarget] {
        let page = snapshot.targets.filter { !$0.operations.contains(.activateApp) && $0.role != "url" && !$0.isOffscreen }
        switch VoiceControlSituation.classify(snapshot) {
        case .plain:
            return page
        case .suggestionPicker:
            return page.filter {
                $0.role != "text"
                    && (isCitySuggestion($0) || isOverlayChrome($0)
                        || ($0.isFocused && $0.operations.contains(.key)))
            }
        case .datePicker:
            return page.filter {
                $0.role != "text"
                    && (isCalendarDay($0) || isOverlayChrome($0)
                        || ($0.isFocused && $0.operations.contains(.key)))
            }
        }
    }

    public static func offeredKeys(in snapshot: VoiceControlSnapshot) -> [String] {
        switch VoiceControlSituation.classify(snapshot) {
        case .suggestionPicker, .datePicker: return ["escape"]
        case .plain: return ["return", "escape", "tab"]
        }
    }

    private static func isOverlayChrome(_ target: VoiceControlTarget) -> Bool {
        let label = target.label.lowercased()
        return label.contains("where else") || label.contains("where to") || label.contains("where from")
            || label.contains("departure") || label.contains("dates")
    }
}

/// Landings Jev may choose among. A landing is an observed outcome the host can
/// compile to one AX action and check on the next snapshot.
public enum VoiceControlOutcomes {
    public static func criteria(landing label: String) -> String {
        "After the host acts, \(label) is the selected result."
    }

    /// Ambiguous picker rows. Generic unlabeled links are not landings: their
    /// post-state is unknown, so they stay unconstrained or domain-local.
    public static func competingLandings(in snapshot: VoiceControlSnapshot, goal: String)
        -> [VoiceControlEnabledEvent]?
    {
        let situation = VoiceControlSituation.classify(snapshot)
        let rows: [VoiceControlTarget]
        switch situation {
        case .plain:
            return nil
        case .suggestionPicker:
            rows = snapshot.targets.filter(VoiceControlLegality.isCitySuggestion)
        case .datePicker:
            rows = snapshot.targets.filter(VoiceControlLegality.isCalendarDay)
        }
        let unused = rows.filter { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard Set(unused.map(\.id)).count == unused.count else { return nil }
        let tokens = goal.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 5 }
        let preferred = unused.filter { row in
            tokens.contains { token in row.label.localizedStandardContains(token) }
        }
        let pool = preferred.count > 1 ? preferred : unused
        guard pool.count > 1 else { return nil }
        return pool.map {
            VoiceControlEnabledEvent(
                id: $0.id, criteria: criteria(landing: $0.label),
                action: VoiceControlAction(
                    operation: .press, targetID: $0.id, targetLabel: $0.label, consequence: .ordinary),
                postcondition: .selectedLabel($0.label))
        }
    }
}

public extension VoiceControlDecisionEngine {
    func decide(
        goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction],
        events: [VoiceControlEnabledEvent]
    ) async throws -> VoiceControlDecision {
        try await decide(goal: goal, snapshot: snapshot, history: history)
    }
}
