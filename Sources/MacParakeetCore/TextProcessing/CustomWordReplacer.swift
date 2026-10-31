import Foundation

/// Pre-compiled, reusable custom-word replacement.
///
/// Build once from a set of `CustomWord`s, then apply to many strings. The
/// deterministic dictation pipeline only ever corrects one string per call, so
/// it historically compiled its regexes inline. Meeting finalization corrects a
/// full transcript *plus every word token* (issue #550), so compiling per token
/// would be wasteful — this hoists compilation out of the hot loop, the same
/// optimization `TextProcessingPipeline.fillerRegexes` already makes for fillers.
///
/// Shared with `TextProcessingPipeline.applyCustomWords`;
/// `CustomWordReplacerTests` pins that parity:
/// - only enabled, nonempty words contribute a rule,
/// - literal matches exclude adjacent Unicode word characters, case-insensitively,
/// - rules apply in array order, so a later rule can act on an earlier rule's
///   output,
/// - `replacement == nil` or blank (a vocabulary anchor) substitutes the word
///   with itself,
/// - a word whose pattern fails to compile is skipped silently.
struct CustomWordReplacer: Sendable {
    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let template: String
    }

    private let rules: [Rule]

    init(words: [CustomWord]) {
        rules = words.compactMap { word in
            guard word.isEnabled, !word.word.isEmpty else { return nil }
            let replacement = word.replacement?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let template =
                if let replacement, !replacement.isEmpty {
                    replacement
                } else {
                    word.word
                }
            let pattern = LiteralTextPattern.wholeToken(word.word)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                return nil
            }
            return Rule(regex: regex, template: NSRegularExpression.escapedTemplate(for: template))
        }
    }

    /// True when no enabled word produced a usable rule — callers can skip work.
    var isEmpty: Bool { rules.isEmpty }

    /// Apply every rule, in order, to `text`.
    func apply(to text: String) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }

        var result = text
        for rule in rules {
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }
        return result
    }
}

/// Keep Unicode word characters outside a literal, including when the literal
/// itself starts or ends with punctuation (for example `.NET` or `C++`).
/// Surrounding punctuation remains a delimiter, as it is for ordinary words.
enum LiteralTextPattern {
    static func wholeToken(_ literal: String) -> String {
        "(?<!\\w)\(NSRegularExpression.escapedPattern(for: literal))(?!\\w)"
    }
}
