import Foundation

/// Built-in spoken punctuation commands for Clean-mode dictation.
///
/// "question mark" / "exclamation mark" become `?` / `!`, including common
/// multilingual aliases. Prefixing a phrase with a literal marker
/// (`literal question mark`) keeps the words. User text snippets of the same
/// trigger still win because snippet expansion runs first. Snippet expansions
/// that themselves contain a command phrase are also converted.
public enum SpokenPunctuation: Sendable {
    public static let commands: [(phrase: String, mark: String)] = {
        let pairs: [(String, String)] = [
            ("punto de interrogación", "?"),
            ("ponto de interrogação", "?"),
            ("signo de interrogación", "?"),
            ("signo de interrogacion", "?"),
            ("ponto de interrogacao", "?"),
            ("point d'interrogation", "?"),
            ("point d’interrogation", "?"),
            ("point d interrogation", "?"),
            ("exclamation point", "!"),
            ("exclamation mark", "!"),
            ("punto de exclamación", "!"),
            ("ponto de exclamação", "!"),
            ("signo de exclamación", "!"),
            ("signo de exclamacion", "!"),
            ("ponto de exclamacao", "!"),
            ("point d'exclamation", "!"),
            ("point d’exclamation", "!"),
            ("point d exclamation", "!"),
            ("question mark", "?"),
            ("znak zapytania", "?"),
            ("ausrufezeichen", "!"),
            ("fragezeichen", "?"),
            ("wykrzyknik", "!"),
            ("疑問符", "？"),
            ("感嘆符", "！"),
            ("感叹号", "！"),
            ("问号", "？"),
            ("問號", "？"),
            ("感嘆號", "！"),
        ]
        return pairs.sorted { $0.0.count > $1.0.count }
    }()

    public static let literalPrefixes: [String] = [
        "dosłownie", "doslownie", "wörtlich", "wortlich", "littéral", "litteral",
        "literal",
    ].sorted { $0.count > $1.count }

    /// Precompiled so Clean-mode dictation stays in the sub-millisecond budget.
    /// Group 1 is the spoken phrase so restore keeps the user's casing.
    private static let literalRegexes: [NSRegularExpression] = {
        var rules: [NSRegularExpression] = []
        for (phrase, _) in commands {
            let capturedPhrase = capturedPhrasePattern(for: phrase)
            for prefix in literalPrefixes {
                let prefixPattern = NSRegularExpression.escapedPattern(for: prefix)
                    .replacingOccurrences(of: " ", with: "\\s+")
                let pattern = "(?i)(?<![\\p{L}\\p{N}])\(prefixPattern)\\s+\(capturedPhrase)"
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                rules.append(regex)
            }
        }
        return rules
    }()

    private static let replaceRules: [(regex: NSRegularExpression, mark: String)] = {
        commands.compactMap { phrase, mark in
            let pattern =
                "(?i)(?:[ \\t]*,)?[ \\t]*\(boundedPhrasePattern(for: phrase))(?:[ \\t]*[.,!?。？！]+)?"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, mark)
        }
    }()

    public static func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        var protected: [String: String] = [:]

        if containsLiteralPrefix(text) {
            for regex in literalRegexes {
                let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
                for match in matches.reversed() {
                    guard let range = Range(match.range, in: result) else { continue }
                    let phraseText: String
                    if match.numberOfRanges > 1, let phraseRange = Range(match.range(at: 1), in: result) {
                        phraseText = String(result[phraseRange])
                    } else {
                        continue
                    }
                    let token = "\u{E000}\(protected.count)\u{E001}"
                    protected[token] = phraseText
                    result.replaceSubrange(range, with: token)
                }
            }
        }

        for (regex, mark) in replaceRules {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: mark)
            )
        }

        for (token, original) in protected {
            result = result.replacingOccurrences(of: token, with: original)
        }
        return result
    }

    private static func containsLiteralPrefix(_ text: String) -> Bool {
        literalPrefixes.contains { prefix in
            text.range(of: prefix, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func escapedPhrase(_ phrase: String) -> String {
        NSRegularExpression.escapedPattern(for: phrase)
            .replacingOccurrences(of: " ", with: "\\s+")
    }

    private static func capturedPhrasePattern(for phrase: String) -> String {
        "(\(escapedPhrase(phrase)))(?![\\p{L}\\p{N}])"
    }

    private static func boundedPhrasePattern(for phrase: String) -> String {
        let escaped = escapedPhrase(phrase)
        guard phrase.contains(where: \.isASCII) else {
            return "\(escaped)(?![\\p{L}\\p{N}])"
        }
        return "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
    }
}
