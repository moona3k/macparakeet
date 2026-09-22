import Foundation

/// Isolated-utterance session grammar. Substring matches are illegal: a typed
/// sentence must not enter or leave literal mode.
public enum VoiceControlSessionPhrase: Equatable, Sendable {
    case enterLiteral
    case exitLiteral
    case stopFromLiteral
}

public enum VoiceControlSessionGrammar {
    public static func phrase(_ text: String, literalMode: Bool) -> VoiceControlSessionPhrase? {
        let command = normalize(text)
        guard !command.isEmpty else { return nil }
        if literalMode {
            if exitLiteral.contains(command) { return .exitLiteral }
            if stopFromLiteral.contains(command) { return .stopFromLiteral }
            return nil
        }
        if enterLiteral.contains(command) { return .enterLiteral }
        return nil
    }

    /// Spoken confirmation tokens are exact after normalize. Filler words
    /// (`ok`, `okay`) never authorize pay, delete, or send.
    public static func acceptsConfirmation(_ text: String) -> Bool {
        acceptConfirmation.contains(normalize(text))
    }

    public static func declinesConfirmation(_ text: String) -> Bool {
        declineConfirmation.contains(normalize(text))
    }

    static func normalize(_ text: String) -> String {
        text.split { !$0.isLetter && !$0.isNumber }.joined(separator: " ").lowercased()
    }

    private static let enterLiteral: Set<String> = [
        "literal mode", "dictation mode", "typing mode", "start typing", "activate type", "type mode",
    ]
    private static let exitLiteral: Set<String> = ["command mode", "stop typing"]
    private static let stopFromLiteral: Set<String> = ["command stop"]
    private static let acceptConfirmation: Set<String> = ["yes", "confirm", "confirm this action"]
    private static let declineConfirmation: Set<String> = ["no", "cancel", "cancel task"]
}

/// Isolated spoken index into a numbered clarification. Substring matches are
/// illegal: "the other one" is not option 1.
public enum VoiceControlSpokenPick {
    public static func index(in text: String, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let command = VoiceControlSessionGrammar.normalize(text)
        guard !command.isEmpty else { return nil }
        if let exact = ordinal(command), exact <= count { return exact - 1 }
        var tokens = command.split(separator: " ").map(String.init)
        while tokens.first == "the" || tokens.first == "number" || tokens.first == "option" {
            tokens.removeFirst()
        }
        while tokens.last == "please" {
            tokens.removeLast()
        }
        if tokens.count >= 2, tokens.last == "one", ordinal(tokens[tokens.count - 2]) != nil {
            tokens.removeLast()
        }
        guard tokens.count == 1, let exact = ordinal(tokens[0]), exact <= count else { return nil }
        return exact - 1
    }

    public static func prompt(labels: [String]) -> String {
        var lines = ["Which one? Say the number."]
        for (offset, label) in labels.enumerated() {
            lines.append("\(offset + 1). \(label)")
        }
        return lines.joined(separator: "\n")
    }

    public static func displayLabels(_ targets: [VoiceControlTarget]) -> [String] {
        let unique = Set(targets.map { $0.label.lowercased() }).count == targets.count
        if unique { return targets.map(\.label) }
        let rolesDiffer = Set(targets.map(\.role)).count > 1
        return targets.enumerated().map { offset, target in
            rolesDiffer ? "\(target.label) (\(target.role))" : "\(target.label) (\(offset + 1))"
        }
    }

    private static func ordinal(_ token: String) -> Int? {
        if let value = Int(token), value >= 1 { return value }
        let words = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        ]
        let ranks = [
            "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
            "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        ]
        return words[token] ?? ranks[token]
    }
}

/// Authorization copy names the compiled effect and the decline. It never
/// offers an always-allow on pay, delete, or send.
public enum VoiceControlConfirmationCopy {
    public static func prompt(
        action: VoiceControlAction, target: VoiceControlTarget, consequence: VoiceControlConsequence
    ) -> String {
        let prefix: String
        let decline: String
        switch consequence {
        case .unknown:
            var prompt = "I can’t tell what \(target.label) does. Press it anyway? Cancel task skips this press."
            if action.requiresConfirmation, let value = action.value, !value.isEmpty {
                prompt += "\n" + String(value.prefix(1_000))
            }
            return prompt
        case .ordinary:
            prefix = "Apply this replacement"
            decline = "Cancel task stops here."
        case .payment:
            prefix = "Confirm payment"
            decline = "Cancel task stops here. Nothing is paid."
        case .destructive:
            prefix = "Confirm deletion"
            decline = "Cancel task stops here. Nothing is deleted."
        case .externalCommitment:
            prefix = "Confirm send"
            decline = "Cancel task stops here. Nothing is sent."
        }
        var prompt = "\(prefix) on \(target.label)? \(decline)"
        if action.requiresConfirmation, let value = action.value, !value.isEmpty {
            prompt += "\n" + String(value.prefix(1_000))
        }
        return prompt
    }
}
