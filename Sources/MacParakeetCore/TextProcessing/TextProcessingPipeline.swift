import Foundation

/// Deterministic 4-step text processing pipeline.
/// Pure function: same input always produces same output.
///
/// Steps: Filler Removal → Custom Words → Snippet Expansion → Whitespace Cleanup
public struct TextProcessingPipeline: Sendable {

    public init() {}

    /// Process raw STT text through the full pipeline.
    public func process(
        text: String,
        customWords: [CustomWord],
        snippets: [TextSnippet]
    ) -> TextProcessingResult {
        guard !text.isEmpty else {
            return TextProcessingResult(text: "")
        }

        var result = text

        // Step 1: Filler removal
        result = removeFillers(from: result)

        // Step 2: Custom word replacements
        result = applyCustomWords(to: result, words: customWords)

        // Step 3: Snippet expansion
        let (expandedText, expandedIDs) = expandSnippets(in: result, snippets: snippets)
        result = expandedText

        // Step 4: Whitespace cleanup
        result = cleanWhitespace(in: result)

        return TextProcessingResult(text: result, expandedSnippetIDs: expandedIDs)
    }

    // MARK: - Step 1: Filler Removal

    /// Always-safe fillers (always removed)
    /// Only pure hesitation sounds — words that never carry meaning.
    private static let alwaysSafeFillers = [
        "um", "uh", "umm", "uhh"
    ]

    func removeFillers(from text: String) -> String {
        var result = text

        for filler in Self.alwaysSafeFillers {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }

        return result
    }

    // MARK: - Step 2: Custom Word Replacements

    func applyCustomWords(to text: String, words: [CustomWord]) -> String {
        var result = text

        for word in words {
            guard word.isEnabled else { continue }

            let replacement = word.replacement ?? word.word
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word.word))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
                )
            }
        }

        return result
    }

    // MARK: - Step 3: Snippet Expansion

    func expandSnippets(
        in text: String,
        snippets: [TextSnippet]
    ) -> (String, Set<UUID>) {
        guard !snippets.isEmpty else { return (text, []) }

        var result = text
        var expandedIDs = Set<UUID>()

        // Sort longest-trigger-first to prevent partial matches
        let sorted = snippets
            .filter { $0.isEnabled }
            .sorted { $0.trigger.count > $1.trigger.count }

        for snippet in sorted {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: snippet.trigger))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }

            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            if !matches.isEmpty {
                expandedIDs.insert(snippet.id)
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: snippet.expansion)
                )
            }
        }

        return (result, expandedIDs)
    }

    // MARK: - Step 4: Whitespace Cleanup

    func cleanWhitespace(in text: String) -> String {
        var result = text

        // 4a: Collapse multiple spaces
        if let regex = try? NSRegularExpression(pattern: " {2,}") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }

        // 4a2: Clean spaces around newlines, preserving newline count
        // "Hello, \n world" → "Hello,\nworld"
        // "Hello, \n\n world" → "Hello,\n\nworld" (paragraph break preserved)
        if let regex = try? NSRegularExpression(pattern: " *(\n+) *") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        // 4b: Remove space before punctuation (only horizontal space, preserve newlines)
        if let regex = try? NSRegularExpression(pattern: " +([.!?,;:])") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        // 4c: Trim
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // 4d: Capitalize first letter
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        return result
    }
}
