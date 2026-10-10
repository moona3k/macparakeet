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
        guard let phrases = spokenControlNames(command) else { return nil }
        let matches = matchingControls(phrases: phrases, in: snapshot, prefixMatch: hasClickPrefix(command))
        if matches.count == 1 {
            let target = matches[0]
            if target.operations.contains(.activateApp) {
                // Whole names: `Xcode` is not already in front because `Code` is.
                if VoiceControlCommandRouter.application(named: snapshot.applicationName, matches: target.label)
                    || VoiceControlCommandRouter.application(named: target.label, matches: snapshot.applicationName)
                {
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
        alreadyPressedByName(command: command, history: history, statuses: [.verified])
    }

    /// `click Save` pressed Save and the interface moved. The single command is
    /// done; the next screen is not a reason to ask the model for another step.
    static func alreadyPressedByName(
        command: String, history: [VoiceControlAction],
        statuses: Set<VoiceControlReceipt.Status> = [.verified, .transitionObserved]
    ) -> Bool {
        guard let phrases = spokenControlNames(command),
            let last = history.last, let status = last.receiptStatus, statuses.contains(status),
            [.press, .activateApp].contains(last.operation)
        else { return false }
        let label = last.targetLabel ?? ""
        return phrases.contains { phrase in
            VoiceControlSessionGrammar.normalize(label) == phrase
                || label.localizedStandardCompare(phrase) == .orderedSame
                || (hasClickPrefix(command) && labelHasPhrasePrefix(label, phrase: phrase))
        }
    }

    /// The spoken name as said, then without a trailing role word: `click new
    /// tab` names `New Tab` before it names `New`.
    private static func spokenControlNames(_ command: String) -> [String]? {
        var n = VoiceControlSessionGrammar.normalize(command)
        guard !n.isEmpty else { return nil }
        if reservedKey(in: command) != nil { return nil }
        for prefix in ["click ", "press ", "open "] where n.hasPrefix(prefix) {
            n = String(n.dropFirst(prefix.count))
            break
        }
        if n.hasPrefix("the ") { n = String(n.dropFirst(4)) }
        if n.hasSuffix(" please") { n = String(n.dropLast(7)) }
        let whole = n
        for suffix in [" button", " link", " tab", " menu"] where n.hasSuffix(suffix) {
            n = String(n.dropLast(suffix.count))
        }
        guard !n.isEmpty, n.split(separator: " ").count <= 8 else { return nil }
        if blockedBarePhrases.contains(n) || blockedBarePhrases.contains(whole) { return nil }
        return whole == n ? [n] : [whole, n]
    }

    private static func hasClickPrefix(_ command: String) -> Bool {
        let n = VoiceControlSessionGrammar.normalize(command)
        return ["click ", "press ", "open "].contains { n.hasPrefix($0) }
    }

    /// Exact names in phrase order, then label prefixes in phrase order.
    private static func matchingControls(phrases: [String], in snapshot: VoiceControlSnapshot, prefixMatch: Bool)
        -> [VoiceControlTarget]
    {
        let candidates = snapshot.targets.filter {
            !$0.label.isEmpty && $0.role != "url"
                && ($0.operations.contains(.press) || $0.operations.contains(.activateApp))
        }
        for phrase in phrases {
            let exact = candidates.filter {
                VoiceControlSessionGrammar.normalize($0.label) == phrase
                    || $0.label.localizedStandardCompare(phrase) == .orderedSame
            }
            if !exact.isEmpty { return exact }
        }
        guard prefixMatch else { return [] }
        for phrase in phrases {
            let prefixed = candidates.filter { labelHasPhrasePrefix($0.label, phrase: phrase) }
            if !prefixed.isEmpty { return prefixed }
        }
        return []
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
