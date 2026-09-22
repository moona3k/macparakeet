import Foundation

/// Host-owned Accessibility tools. Jev is not consulted when a unique observed
/// control or reserved key compiles. Pay / delete / send still confirm later.
enum VoiceControlLocalTools {
    static let reservedKeys: Set<String> = [
        "tab", "escape", "enter", "return", "left", "right", "up", "down", "backspace", "delete",
    ]

    /// `press return` and bare `escape` are keys. `click Return` is a control.
    static func reservedKey(in command: String) -> String? {
        let n = VoiceControlSessionGrammar.normalize(command)
        guard !n.isEmpty else { return nil }
        if reservedKeys.contains(n) { return n }
        if n.hasPrefix("press ") {
            let rest = String(n.dropFirst(6))
            if reservedKeys.contains(rest) { return rest }
            if rest.hasPrefix("the "), rest.hasSuffix(" key") {
                let mid = String(rest.dropFirst(4).dropLast(4)).trimmingCharacters(in: .whitespaces)
                if reservedKeys.contains(mid) { return mid }
            }
        }
        return nil
    }

    static func namedPress(command: String, snapshot: VoiceControlSnapshot) -> VoiceControlDecision? {
        // Bare names are tools on a plain window. Overlay rows stay landings for Jev.
        if !hasClickPrefix(command), VoiceControlSituation.classify(snapshot) != .plain {
            return nil
        }
        guard let phrase = spokenControlName(command) else { return nil }
        let matches = matchingControls(phrase: phrase, in: snapshot, prefixMatch: hasClickPrefix(command))
        if matches.count == 1 {
            let target = matches[0]
            if target.operations.contains(.activateApp) {
                let current = snapshot.applicationName.lowercased()
                let label = target.label.lowercased()
                if current == label || current.contains(label) || label.contains(current) {
                    return .information("\(snapshot.applicationName) is already in front.")
                }
                return .action(VoiceControlAction(operation: .activateApp, targetID: target.id))
            }
            return .action(VoiceControlAction(operation: .press, targetID: target.id))
        }
        if matches.count > 1, matches.count <= 6 {
            let labels = VoiceControlSpokenPick.displayLabels(matches)
            return .pick(
                prompt: VoiceControlSpokenPick.prompt(labels: labels), labels: labels,
                targetIDs: matches.map(\.id))
        }
        if matches.count > 1 {
            return .clarify("More than one control is named \(matches[0].label). Describe which one.")
        }
        return nil
    }

    static func fieldAlreadyHolds(_ value: String, target: VoiceControlTarget) -> Bool {
        guard target.valueIsComplete, let existing = target.value else { return false }
        return existing.localizedStandardCompare(value) == .orderedSame
    }

    static func alreadyVerifiedNamedPress(command: String, history: [VoiceControlAction]) -> Bool {
        guard let phrase = spokenControlName(command),
            let last = history.last, last.receiptStatus == .verified,
            [.press, .activateApp].contains(last.operation),
            VoiceControlSessionGrammar.normalize(last.targetLabel ?? "") == phrase
                || last.targetLabel?.localizedStandardCompare(phrase) == .orderedSame
        else { return false }
        return true
    }

    private static func spokenControlName(_ command: String) -> String? {
        var n = VoiceControlSessionGrammar.normalize(command)
        guard !n.isEmpty else { return nil }
        if reservedKey(in: command) != nil { return nil }
        for prefix in ["click ", "press ", "open "] where n.hasPrefix(prefix) {
            n = String(n.dropFirst(prefix.count))
            break
        }
        if n.hasPrefix("the ") { n = String(n.dropFirst(4)) }
        for suffix in [" please", " button", " link", " tab", " menu"] where n.hasSuffix(suffix) {
            n = String(n.dropLast(suffix.count))
        }
        guard !n.isEmpty, n.split(separator: " ").count <= 8 else { return nil }
        if blockedBarePhrases.contains(n) { return nil }
        return n
    }

    private static func hasClickPrefix(_ command: String) -> Bool {
        let n = VoiceControlSessionGrammar.normalize(command)
        return ["click ", "press ", "open "].contains { n.hasPrefix($0) }
    }

    private static func matchingControls(phrase: String, in snapshot: VoiceControlSnapshot, prefixMatch: Bool)
        -> [VoiceControlTarget]
    {
        let candidates = snapshot.targets.filter {
            !$0.label.isEmpty && $0.role != "url"
                && ($0.operations.contains(.press) || $0.operations.contains(.activateApp))
        }
        let exact = candidates.filter {
            VoiceControlSessionGrammar.normalize($0.label) == phrase
                || $0.label.localizedStandardCompare(phrase) == .orderedSame
        }
        if !exact.isEmpty { return exact }
        guard prefixMatch else { return [] }
        return candidates.filter { labelHasPhrasePrefix($0.label, phrase: phrase) }
    }

    /// `click Search` can bind the unique `Search flights`. `research` does not match `search`.
    private static func labelHasPhrasePrefix(_ label: String, phrase: String) -> Bool {
        let n = VoiceControlSessionGrammar.normalize(label)
        if n == phrase { return true }
        return n.hasPrefix(phrase + " ")
    }

    private static let blockedBarePhrases: Set<String> = [
        "help", "show commands", "what can i say", "what can i say here",
        "undo", "undo that", "undo last edit", "scroll down", "scroll up",
        "yes", "no", "cancel", "cancel task", "confirm", "confirm this action",
        "stop", "continue",
    ]
}
