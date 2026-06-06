import Foundation

/// Deterministic 5-step text processing pipeline.
/// Pure function: same input always produces same output.
///
/// Steps: Filler Removal → Custom Words → Trailing Action Extraction → Snippet Expansion → Whitespace Cleanup
public struct TextProcessingPipeline: Sendable {

    public init() {}

    /// Process raw STT text through the full pipeline.
    public func process(
        text: String,
        customWords: [CustomWord],
        snippets: [TextSnippet],
        insertionStyle: DictationInsertionStyle = .sentence
    ) -> TextProcessingResult {
        guard !text.isEmpty else {
            return TextProcessingResult(text: "")
        }

        let textSnippets = snippets.filter { $0.action == nil }
        let actionSnippets = snippets.filter { $0.action != nil }

        var result = text

        // Step 1: Filler removal
        result = removeFillers(from: result)

        // Step 2: Custom word replacements
        result = applyCustomWords(to: result, words: customWords)

        // Step 3: Extract trailing action snippet (before expansion, so trigger isn't mangled)
        var actionIDs = Set<UUID>()
        var postPasteAction: KeyAction?
        let (actionCleanedText, matchedSnippet) = extractTrailingAction(
            from: result, actionSnippets: actionSnippets
        )
        if let matchedSnippet {
            result = actionCleanedText
            postPasteAction = matchedSnippet.action
            actionIDs.insert(matchedSnippet.id)
        }

        // Step 4: Text snippet expansion (text-type only)
        let (expandedText, expandedIDs) = expandSnippets(in: result, snippets: textSnippets)
        result = expandedText

        // Step 5: Whitespace cleanup
        let protectedLeadingTerms = protectedLeadingTerms(
            customWords: customWords,
            textSnippets: textSnippets,
            expandedSnippetIDs: expandedIDs
        )
        result = cleanWhitespace(
            in: result,
            insertionStyle: insertionStyle,
            protectedLeadingTerms: protectedLeadingTerms
        )

        return TextProcessingResult(
            text: result,
            expandedSnippetIDs: expandedIDs.union(actionIDs),
            postPasteAction: postPasteAction
        )
    }

    // MARK: - Step 1: Filler Removal

    /// Always-safe fillers (always removed)
    /// Only pure hesitation sounds — words that never carry meaning.
    private static let alwaysSafeFillers = [
        "um", "uh", "umm", "uhh"
    ]

    /// Pre-compiled filler regexes — avoids recompilation on every dictation.
    private static let fillerRegexes: [NSRegularExpression] = alwaysSafeFillers.compactMap { filler in
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b"
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    func removeFillers(from text: String) -> String {
        var result = text

        for regex in Self.fillerRegexes {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
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

    // MARK: - Step 3: Trailing Action Extraction

    func extractTrailingAction(
        from text: String,
        actionSnippets: [TextSnippet]
    ) -> (String, TextSnippet?) {
        guard !actionSnippets.isEmpty else { return (text, nil) }

        // Sort longest-trigger-first (same as expandSnippets)
        let sorted = actionSnippets
            .filter { $0.isEnabled }
            .sorted { $0.trigger.count > $1.trigger.count }

        for snippet in sorted {
            // Punctuation-tolerant: match trigger at end with optional trailing punctuation.
            // Normalize literal spaces to \s+ so filler removal gaps (double spaces) still match.
            let escaped = NSRegularExpression.escapedPattern(for: snippet.trigger)
            let spaceNormalized = escaped.replacingOccurrences(of: " ", with: "\\s+")
            let pattern = "\\b\(spaceNormalized)[.!?,;:]*\\s*$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range) {
                let cleaned = (text as NSString).replacingCharacters(in: match.range, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (cleaned, snippet)
            }
        }

        return (text, nil)
    }

    // MARK: - Step 4: Snippet Expansion

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

    // MARK: - Step 5: Whitespace Cleanup

    func cleanWhitespace(
        in text: String,
        insertionStyle: DictationInsertionStyle = .sentence,
        protectedLeadingTerms: [String] = []
    ) -> String {
        var result = text

        // 5a: Collapse multiple spaces
        if let regex = try? NSRegularExpression(pattern: " {2,}") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }

        // 5a2: Clean spaces around newlines, preserving newline count
        // "Hello, \n world" → "Hello,\nworld"
        // "Hello, \n\n world" → "Hello,\n\nworld" (paragraph break preserved)
        if let regex = try? NSRegularExpression(pattern: " *(\n+) *") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        // 5b: Remove space before punctuation (only horizontal space, preserve newlines)
        if let regex = try? NSRegularExpression(pattern: " +([.!?,;:])") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        // 5c: Trim
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return applyInsertionStyle(
            to: result,
            insertionStyle: insertionStyle,
            protectedLeadingTerms: protectedLeadingTerms
        )
    }

    func applyInsertionStyle(
        to text: String,
        insertionStyle: DictationInsertionStyle,
        protectedLeadingTerms: [String] = []
    ) -> String {
        switch insertionStyle {
        case .sentence:
            return capitalizeFirstLetter(in: text)
        case .inline:
            let withoutTerminalPunctuation = removeTerminalSentencePunctuation(from: text)
            return lowercaseLeadingSentenceCase(
                in: withoutTerminalPunctuation,
                protectedLeadingTerms: protectedLeadingTerms
            )
        }
    }

    func protectedLeadingTerms(
        customWords: [CustomWord],
        textSnippets: [TextSnippet],
        expandedSnippetIDs: Set<UUID>
    ) -> [String] {
        let customTerms = customWords
            .filter(\.isEnabled)
            .map { $0.replacement ?? $0.word }
        let snippetTerms = textSnippets
            .filter { $0.isEnabled && expandedSnippetIDs.contains($0.id) }
            .map(\.expansion)
        return customTerms + snippetTerms
    }

    private func capitalizeFirstLetter(in text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func removeTerminalSentencePunctuation(from text: String) -> String {
        var result = text
        while let last = result.last, Self.inlineTerminalPunctuation.contains(last) {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private func lowercaseLeadingSentenceCase(
        in text: String,
        protectedLeadingTerms: [String]
    ) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        guard !hasProtectedLeadingTerm(text, protectedLeadingTerms: protectedLeadingTerms) else {
            return text
        }
        guard !firstTokenHasIntentionalUppercase(in: text) else { return text }
        return first.lowercased() + text.dropFirst()
    }

    private func firstTokenHasIntentionalUppercase(in text: String) -> Bool {
        let token = text.prefix { !$0.isWhitespace }
        return token.dropFirst().contains { $0.isUppercase }
    }

    private func hasProtectedLeadingTerm(
        _ text: String,
        protectedLeadingTerms: [String]
    ) -> Bool {
        for rawTerm in protectedLeadingTerms {
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, text.hasPrefix(term) else { continue }
            let end = text.index(text.startIndex, offsetBy: term.count)
            if end == text.endIndex || Self.leadingTermBoundaryCharacters.contains(text[end]) {
                return true
            }
        }
        return false
    }

    private static let inlineTerminalPunctuation: Set<Character> = [".", "!", "?"]
    private static let leadingTermBoundaryCharacters: Set<Character> = [
        " ", "\n", "\t", ".", ",", "!", "?", ";", ":", ")", "]", "}"
    ]
}
