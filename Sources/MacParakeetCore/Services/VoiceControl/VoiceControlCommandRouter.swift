import Foundation

/// Exact local commands remain usable without a model request. All returned actions
/// still pass the runner's policy, freshness checks and revocable execution boundary.
public struct VoiceControlCommandRouter: VoiceControlDecisionEngine {
    public typealias Rewrite = @Sendable (_ text: String, _ instruction: String) async throws -> String
    private let fallback: any VoiceControlDecisionEngine
    private let rewrite: Rewrite?
    private let selectionAtInvocation: (@Sendable () async -> VoiceControlSnapshot?)?
    public init(
        fallback: any VoiceControlDecisionEngine, rewrite: Rewrite? = nil,
        selectionAtInvocation: (@Sendable () async -> VoiceControlSnapshot?)? = nil
    ) {
        self.fallback = fallback; self.rewrite = rewrite; self.selectionAtInvocation = selectionAtInvocation
    }

    public func decide(goal: String, snapshot: VoiceControlSnapshot, history: [VoiceControlAction]) async throws
        -> VoiceControlDecision
    {
        let command = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = command.lowercased()
        // Exact routes read the newest user segment of an amended goal when it is
        // itself a command (`undo`, `open Safari`), else the whole goal. Web, form
        // and text-entry routes keep reading the whole goal (`currentRequest`).
        let segment = Self.commandSegment(of: command)
        let local = segment ?? command
        let localLower = local.lowercased()
        if ["help", "show commands", "what can i say", "what can i say here"].contains(
            localLower.trimmingCharacters(in: .punctuationCharacters))
        {
            return .information(contextualHelp(snapshot))
        }
        let focused = snapshot.targets.filter { $0.isFocused && $0.operations.contains(.insertText) }
        // Jev judged the request to be this one action; it has landed. An amended
        // goal is a different request, so it never inherits the judgment.
        if history.count == 1, let only = history.first, only.completesRequest == true,
            VoiceControlGoalText.userSegments(goal).count == 1
        {
            if only.receiptStatus == .verified { return .directCompleted("Done. The requested change was verified.") }
            if only.receiptStatus == .transitionObserved { return .finished }
        }
        if history.last?.receiptStatus == .verified, Self.isDirectCommand(lower) {
            return .directCompleted("Done. The requested change was verified.")
        }

        // A verified direct action has finished this single-command route. The goal
        // loop for open-ended requests remains delegated to the semantic engine.
        func result(_ action: VoiceControlAction) -> VoiceControlDecision {
            if history.isEmpty { return .action(action) }
            // History predates the amendment, so only this exact effect finishes it.
            if segment != nil {
                let label = action.targetLabel ?? snapshot.targets.first { $0.id == action.targetID }?.label ?? ""
                // An older walk-position id can name a different control now, so a
                // known label must match; the id decides only when a label is missing.
                let lastLabel = history.last?.targetLabel ?? ""
                let same =
                    !label.isEmpty && !lastLabel.isEmpty
                    ? lastLabel.caseInsensitiveCompare(label) == .orderedSame
                    : history.last?.targetID == action.targetID
                // A failed effect is not done: the correction repeating it is a retry.
                guard let last = history.last, last.operation == action.operation, last.value == action.value, same,
                    last.receiptStatus != .failed
                else { return .action(action) }
                return last.receiptStatus == .verified
                    ? .directCompleted("Done. The requested change was verified.") : .finished
            }
            if let last = history.last, last.receiptStatus == .verified,
                last.targetID == action.targetID
                    || (last.operation == action.operation
                        && last.targetLabel?.caseInsensitiveCompare(action.targetLabel ?? "") == .orderedSame
                        && !(action.targetLabel ?? "").isEmpty)
            {
                return .directCompleted("Done. The requested change was verified.")
            }
            return history.last?.receiptStatus == .verified ? .action(action) : .finished
        }
        if let rawPayload = Self.typePayload(in: command) {
            guard focused.count == 1 else { return .clarify("Focus one editable field before typing.") }
            var payload = Self.strippingTrailingPlease(rawPayload)
            if (focused[0].selectedText ?? "").isEmpty,
                let value = focused[0].value, let last = value.last, !last.isWhitespace,
                let first = payload.first, first.isLetter || first.isNumber
            {
                payload = " " + payload
            }
            guard !payload.isEmpty, payload.utf16.count <= 32_000 else {
                return .clarify("Say the text to enter, up to 32,000 characters.")
            }
            if VoiceControlLocalTools.fieldAlreadyHolds(
                payload.trimmingCharacters(in: .whitespaces), target: focused[0]),
                (focused[0].selectedText ?? "").isEmpty
            {
                return .information("That text is already in the field.")
            }
            return result(VoiceControlAction(operation: .insertText, targetID: focused[0].id, value: payload))
        }
        // Empty source ("replace with X") is a local clarify, never a Jev call.
        if lower.hasPrefix("replace ") {
            guard let delimiter = command.range(of: " with ", options: .caseInsensitive),
                let prefix = command.range(of: "replace ", options: .caseInsensitive),
                delimiter.lowerBound >= prefix.upperBound
            else {
                return .clarify("Which exact words should I replace?")
            }
            guard focused.count == 1, focused[0].valueIsComplete, let value = focused[0].value else {
                return .clarify("Focus a supported text field with its complete text available.")
            }
            let source = Self.unquote(String(command[prefix.upperBound..<delimiter.lowerBound]))
            let replacement = Self.unquote(String(command[delimiter.upperBound...]))
            guard !source.isEmpty else { return .clarify("Which exact words should I replace?") }
            let occurrences = value.ranges(of: source)
            guard occurrences.count == 1, let range = occurrences.first else {
                return .clarify(
                    occurrences.isEmpty
                        ? "Those words are not in the focused field."
                        : "Those words appear more than once. Select the intended text first.")
            }
            let changed = value.replacingCharacters(in: range, with: replacement)
            guard focused[0].operations.contains(.setValue) else {
                return .clarify("This field does not support a precise replacement.")
            }
            return result(VoiceControlAction(operation: .setValue, targetID: focused[0].id, value: changed))
        }
        if let key = VoiceControlLocalTools.reservedKey(in: local) {
            guard let target = snapshot.targets.first(where: { $0.isFocused && $0.operations.contains(.key) })
            else {
                return .clarify("Focus a field that can receive the \(key) key.")
            }
            return result(VoiceControlAction(operation: .key, targetID: target.id, value: key))
        }
        if VoiceControlLocalTools.alreadyVerifiedNamedPress(command: local, history: history, exact: segment != nil) {
            return .directCompleted("Done. The requested change was verified.")
        }
        if VoiceControlLocalTools.alreadyPressedByName(command: local, history: history, exact: segment != nil) {
            return .finished
        }
        if let destination = VoiceControlWebDestination.matchingGoal(lower),
            snapshot.targets.contains(where: { $0.id == destination.id }),
            !VoiceControlWebDestination.pageMatches(snapshot, destination: destination),
            !VoiceControlWebDestination.wasOpened(destination, history: history)
        {
            return .action(VoiceControlAction(operation: .press, targetID: destination.id, consequence: .ordinary))
        }
        if let plan = VoiceControlFlightPlan.parse(command),
            VoiceControlWebDestination.isCurrent(
                VoiceControlWebDestination.named("web:google-flights") ?? VoiceControlWebDestination.all[0],
                snapshot: snapshot, history: history)
        {
            let frame = plan.frame(in: snapshot, history: history)
            if frame.events.count == 1 { return .action(frame.events[0].action) }
            if frame.events.count > 1 {
                return try await fallback.decide(
                    goal: command, snapshot: snapshot, history: history, events: frame.events)
            }
        }
        if let query = VoiceControlWebQuery.parse(command),
            let destination = VoiceControlWebDestination.named(query.destinationID),
            VoiceControlWebDestination.isCurrent(destination, snapshot: snapshot, history: history),
            let action = query.nextAction(in: snapshot, history: history)
        {
            return .action(action)
        }
        if let action = VoiceControlNamedPageAction.next(command: command, snapshot: snapshot, history: history) {
            return .action(action)
        }
        if let browser = Self.browserForWebGoal(lower, snapshot: snapshot) {
            return .action(VoiceControlAction(operation: .activateApp, targetID: browser.id))
        }
        if let requested = Self.requestedApplication(localLower) {
            // Only a request that names the front app is a no-op: `open the first
            // email` in Mail names an email, not Mail.
            if Self.application(named: snapshot.applicationName, matches: requested) {
                return .information("\(snapshot.applicationName) is already in front.")
            }
            let apps = snapshot.targets.filter {
                $0.operations.contains(.activateApp) && Self.application(named: $0.label, matches: requested)
            }
            if apps.count == 1 {
                return result(VoiceControlAction(operation: .activateApp, targetID: apps[0].id))
            }
            if apps.count > 1 { return .clarify("Which \(apps[0].label) window should I open?") }
        }
        if ["undo", "undo that", "undo last edit"].contains(localLower),
            let target = snapshot.targets.first(where: { $0.role == "undo" })
        {
            return result(VoiceControlAction(operation: .press, targetID: target.id))
        }
        if ["scroll down", "scroll up"].contains(localLower) {
            let candidates = snapshot.targets.filter { $0.operations.contains(.scroll) }
            guard let area = Self.scrollArea(candidates, in: snapshot) else {
                return .clarify("Which part of the window should I scroll?")
            }
            return result(
                VoiceControlAction(
                    operation: .scroll, targetID: area.id, value: localLower == "scroll up" ? "up" : "down"))
        }
        if ["rewrite ", "make this ", "translate this ", "summarize this"].contains(where: lower.hasPrefix) {
            guard history.isEmpty else { return .finished }
            guard focused.count == 1, let selected = focused[0].selectedText, !selected.isEmpty else {
                return .clarify("Select the text to rewrite in a supported editable field first.")
            }
            if let selectionAtInvocation {
                guard let original = await selectionAtInvocation(), original.contextID == snapshot.contextID,
                    let source = original.targets.first(where: { $0.isFocused }),
                    source.label == focused[0].label, source.role == focused[0].role,
                    source.value == focused[0].value, source.selectedText == selected,
                    original.targets.filter({ $0.label == source.label && $0.role == source.role }).count == 1,
                    snapshot.targets.filter({ $0.label == source.label && $0.role == source.role }).count == 1
                else {
                    return .clarify("The original selection changed. Select the text and repeat the rewrite.")
                }
            }
            guard let rewrite else {
                return .clarify("Configure and enable a writing provider to rewrite selected text.")
            }
            let rewritten = try await rewrite(selected, command)
            try Task.checkCancellation()
            guard !rewritten.isEmpty, rewritten.utf16.count <= 32_000 else {
                return .clarify("The rewrite was empty or too long. Try a smaller selection.")
            }
            return .action(
                VoiceControlAction(
                    operation: .insertText, targetID: focused[0].id,
                    value: rewritten, targetLabel: focused[0].label, requiresConfirmation: true))
        }
        if let named = VoiceControlLocalTools.namedPress(command: local, snapshot: snapshot) {
            if case .action(let action) = named { return result(action) }
            return named
        }
        if let landings = VoiceControlOutcomes.competingLandings(in: snapshot, goal: command),
            landings.count > 1
        {
            return try await fallback.decide(
                goal: command, snapshot: snapshot, history: history, events: landings)
        }
        return try await fallback.decide(goal: command, snapshot: snapshot, history: history)
    }
    /// The newest correction (fillers removed) or clarification of an amended
    /// goal, when it is a command. Answers (`2`, `Rome`) are not, and text entry
    /// (`no, type Rome`) usually revises earlier text, so both stay with the model.
    static func commandSegment(of goal: String) -> String? {
        let segments = VoiceControlGoalText.kindedSegments(goal)
        guard segments.count > 1, let newest = segments.last, newest.kind != .original else { return nil }
        var text = (newest.kind == .correction ? VoiceControlGoalText.withoutLeadingFiller(newest.text) : newest.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The local routes match a bare command: `please open Safari` is `open Safari`.
        if text.lowercased().hasPrefix("please ") { text = String(text.dropFirst(7)) }
        let lower = text.lowercased()
        guard !text.contains("\n"), VoiceControlUtteranceIntent.isCommandShaped(text), typePayload(in: text) == nil,
            !["replace ", "rewrite ", "make this ", "translate this ", "summarize this"]
                .contains(where: lower.hasPrefix)
        else { return nil }
        return text
    }
    /// Which area `scroll down` means. One area is itself. Of several, the one
    /// holding the focused control (the list you are in), else the clearly
    /// largest one (the content, not a sidebar). Without frames, or with two
    /// areas of similar size, nil: ask.
    static func scrollArea(_ areas: [VoiceControlTarget], in snapshot: VoiceControlSnapshot) -> VoiceControlTarget? {
        if areas.count <= 1 { return areas.first }
        let framed = areas.compactMap { area in area.frame.map { (area, $0) } }
        guard framed.count == areas.count else { return nil }
        if let focus = snapshot.targets.first(where: { $0.isFocused && !$0.operations.contains(.scroll) })?.frame {
            let holding = framed.filter { $0.1.contains(CGPoint(x: focus.midX, y: focus.midY)) }
            if let innermost = holding.min(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) {
                return innermost.0
            }
        }
        let sorted = framed.sorted { $0.1.width * $0.1.height > $1.1.width * $1.1.height }
        let largest = sorted[0].1.width * sorted[0].1.height
        let next = sorted[1].1.width * sorted[1].1.height
        return largest >= next * 2 ? sorted[0].0 : nil
    }

    private static func isDirectCommand(_ lower: String) -> Bool {
        // Only routes selected locally should terminate after one verified effect.
        // Exact labels that did not match originally may have entered the semantic
        // goal loop; use operation history rather than this predicate for those.
        typePayload(in: lower) != nil
            || ["replace ", "rewrite ", "make this ", "translate this ", "summarize this"].contains(
                where: lower.hasPrefix)
            || ["undo", "undo that", "undo last edit", "scroll down", "scroll up"].contains(lower)
    }

    /// Leading `type ` and a trailing clause (`now type hello`) both insert locally.
    /// Mid-sentence `type` is a noun (`what type of file`, `click the file type
    /// menu`): a clause starts only after `,` / `.` or a joining word. The first
    /// such clause wins, so everything after it is literal text.
    static func typePayload(in command: String) -> String? {
        let lower = command.lowercased()
        let prefixes = ["type the words ", "type literally ", "type "]
        for prefix in prefixes where lower.hasPrefix(prefix) {
            return String(command.dropFirst(prefix.count))
        }
        // A trailing clause is a single spoken utterance. The runner's amended goal
        // ("Original goal: …\nUser correction: …") is multi-line and must not be
        // mistaken for "now type <everything after the first 'type '>".
        guard !command.contains("\n") else { return nil }
        let joiners: Set<String> = ["now", "then", "and", "please"]
        var from = command.startIndex
        while let match = command.range(of: " type ", options: .caseInsensitive, range: from..<command.endIndex) {
            let before = command[..<match.lowerBound]
            let word = before.split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? ""
            if let last = before.last, ",.".contains(last) || joiners.contains(word) {
                var rest = command[match.upperBound...]
                for lead in ["the words ", "literally "]
                where rest.range(of: lead, options: [.caseInsensitive, .anchored]) != nil {
                    rest = rest.dropFirst(lead.count); break
                }
                return String(rest)
            }
            from = command.index(after: match.lowerBound)
        }
        return nil
    }

    /// Spoken filler after the words to type. Keep `, please` when that is the text.
    static func strippingTrailingPlease(_ payload: String) -> String {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard let match = lower.range(of: #"[,.]?\s+please[.!?]*$"#, options: .regularExpression) else {
            return payload
        }
        let kept = String(trimmed[..<match.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? payload : kept
    }
    static func requestedApplication(_ lower: String) -> String? {
        let prefixes = ["open up ", "switch to ", "go to ", "open "]
        guard let prefix = prefixes.first(where: { lower.hasPrefix($0) }) else { return nil }
        var name = String(lower.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if name.hasSuffix(" app") { name = String(name.dropLast(4)) }
        if name.hasPrefix("the ") { name = String(name.dropFirst(4)) }
        return name.isEmpty || name.split(separator: " ").count > 4 ? nil : name
    }
    /// Whole names only, never substrings: `search results` is not Arc and
    /// `source code` is not Code. A name also answers without its vendor
    /// (`Chrome`, `Word`) or by a known alias (`VS Code`).
    static func application(named label: String, matches requested: String) -> Bool {
        let request = VoiceControlSessionGrammar.normalize(requested)
        return !request.isEmpty && applicationNames(label).contains(request)
    }
    static func applicationNames(_ label: String) -> Set<String> {
        let name = VoiceControlSessionGrammar.normalize(label)
        var names: Set<String> = [name]
        let words = name.split(separator: " ")
        if words.count > 1, ["google", "microsoft", "adobe", "apple", "mozilla"].contains(String(words[0])) {
            names.insert(words.dropFirst().joined(separator: " "))
        }
        if words.contains("chrome") { names.insert("chrome") }
        names.formUnion(applicationAliases[name] ?? [])
        return names
    }
    private static let applicationAliases: [String: Set<String>] = [
        // VS Code's process is named "Code".
        "visual studio code": ["vs code", "vscode", "code"], "code": ["vs code", "vscode", "visual studio code"],
        "iterm2": ["iterm"],
    ]
    /// Web tasks should start in a browser, not the terminal or IDE that issued the command.
    static func browserForWebGoal(_ lower: String, snapshot: VoiceControlSnapshot) -> VoiceControlTarget? {
        guard !isBrowserName(snapshot.applicationName) else { return nil }
        // The same anchored matching as the web routes: a mail about a flight,
        // or a reply saying the login fails in Chrome, is not a reason to leave
        // the mail app.
        guard VoiceControlWebDestination.matchingGoal(lower) != nil || VoiceControlWebDestination.namesBrowser(lower)
        else { return nil }
        let browsers = snapshot.targets.filter {
            $0.operations.contains(.activateApp) && isBrowserName($0.label)
        }
        // The browser named in the current request, not in a request a correction replaced.
        let request = VoiceControlGoalText.currentRequest(lower)?.lowercased() ?? lower
        if request.contains("safari") { return browsers.first { $0.label.lowercased().contains("safari") } }
        if request.contains("firefox") { return browsers.first { $0.label.lowercased().contains("firefox") } }
        if let chrome = browsers.first(where: { $0.label.lowercased().contains("chrome") }) { return chrome }
        return browsers.count == 1 ? browsers[0] : nil
    }
    /// Word match: `Archive Utility` and `Research` are not Arc.
    static func isBrowserName(_ name: String) -> Bool {
        let words = Set(VoiceControlSessionGrammar.normalize(name).split(separator: " ").map(String.init))
        return !words.isDisjoint(with: ["chrome", "safari", "firefox", "edge", "brave", "arc"])
    }
    private func contextualHelp(_ snapshot: VoiceControlSnapshot) -> String {
        var lines = ["Commands available in \(snapshot.applicationName):"]
        let uniqueLabels = Dictionary(grouping: snapshot.targets, by: { $0.label.lowercased() })
        let pressable = snapshot.targets.filter {
            $0.operations.contains(.press) && !$0.label.isEmpty && $0.label.count <= 80
                && uniqueLabels[$0.label.lowercased()]?.count == 1
        }
        for target in pressable.prefix(3) { lines.append("• Click \(target.label) — or just say \(target.label)") }
        if snapshot.targets.filter({ $0.isFocused && $0.operations.contains(.insertText) }).count == 1 {
            lines.append("• Type hello — inserts your exact words into the focused field")
            lines.append("• Typing mode — keep inserting until you say command mode or stop typing")
            if snapshot.targets.contains(where: {
                $0.isFocused && $0.operations.contains(.key)
            }) {
                lines.append("• Press return — sends the key, not a button named Return")
            }
            if snapshot.targets.contains(where: {
                $0.isFocused && $0.operations.contains(.setValue) && $0.valueIsComplete
            }) {
                lines.append("• Replace old words with new words — use an exact, unique phrase")
            }
            if rewrite != nil, snapshot.targets.contains(where: { $0.isFocused && !($0.selectedText ?? "").isEmpty }) {
                lines.append("• Make this shorter — previews a rewrite of the selected text")
            }
        }
        if Self.scrollArea(snapshot.targets.filter { $0.operations.contains(.scroll) }, in: snapshot) != nil {
            lines.append("• Scroll down or scroll up")
        }
        if let app = snapshot.targets.first(where: {
            $0.operations.contains(.activateApp) && !$0.label.isEmpty && uniqueLabels[$0.label.lowercased()]?.count == 1
        }) {
            lines.append("• Open \(app.label) — opens the app; click \(app.label) presses a control with that name")
        }
        if snapshot.targets.contains(where: { $0.role == "undo" }) { lines.append("• Undo last edit") }
        if lines.count == 1 {
            lines.append(
                "No supported direct controls are currently available. Focus an editable field or another app.")
        }
        if !snapshot.isComplete { lines.append("Only part of this interface was observed.") }
        lines.append("If several controls match, say the number.")
        lines.append(
            "Say Stop to pause, or End Voice Control to end the session. Only pay, delete, or send asks for confirmation.")
        return lines.joined(separator: "\n")
    }

    private static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for (opening, closing) in [("\"", "\""), ("“", "”"), ("'", "'")]
        where trimmed.hasPrefix(opening) && trimmed.hasSuffix(closing) && trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}

private extension String {
    func ranges(of needle: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var start = startIndex
        while start < endIndex, let match = range(of: needle, range: start..<endIndex) {
            found.append(match); start = match.upperBound
        }
        return found
    }
}
