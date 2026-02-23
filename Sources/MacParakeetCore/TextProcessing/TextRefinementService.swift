import Foundation

public enum TextRefinementPath: String, Sendable {
    case raw
    case deterministic
}

public struct TextRefinementResult: Sendable {
    public let text: String?
    public let expandedSnippetIDs: Set<UUID>
    public let path: TextRefinementPath

    public init(
        text: String?,
        expandedSnippetIDs: Set<UUID>,
        path: TextRefinementPath
    ) {
        self.text = text
        self.expandedSnippetIDs = expandedSnippetIDs
        self.path = path
    }
}

public struct TextRefinementService: Sendable {
    public init() {}

    public func refine(
        rawText: String,
        mode: Dictation.ProcessingMode,
        customWords: [CustomWord],
        snippets: [TextSnippet]
    ) async -> TextRefinementResult {
        guard mode.usesDeterministicPipeline else {
            return TextRefinementResult(
                text: nil,
                expandedSnippetIDs: [],
                path: .raw
            )
        }

        let deterministic = TextProcessingPipeline().process(
            text: rawText,
            customWords: customWords,
            snippets: snippets
        )

        return TextRefinementResult(
            text: deterministic.text,
            expandedSnippetIDs: deterministic.expandedSnippetIDs,
            path: .deterministic
        )
    }
}
