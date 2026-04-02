import Foundation

public enum TextRefinementPath: String, Sendable {
    case raw
    case deterministic
}

public struct TextRefinementResult: Sendable {
    public let text: String?
    public let expandedSnippetIDs: Set<UUID>
    public let path: TextRefinementPath
    public let postPasteAction: KeyAction?

    public init(
        text: String?,
        expandedSnippetIDs: Set<UUID>,
        path: TextRefinementPath,
        postPasteAction: KeyAction? = nil
    ) {
        self.text = text
        self.expandedSnippetIDs = expandedSnippetIDs
        self.path = path
        self.postPasteAction = postPasteAction
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
            // Raw mode: skip full pipeline but still extract trailing action (Voice Return)
            let actionSnippets = snippets.filter { $0.action != nil && $0.isEnabled }
            if !actionSnippets.isEmpty {
                let pipeline = TextProcessingPipeline()
                let (cleaned, matched) = pipeline.extractTrailingAction(
                    from: rawText, actionSnippets: actionSnippets
                )
                if let matched {
                    return TextRefinementResult(
                        text: cleaned,
                        expandedSnippetIDs: [matched.id],
                        path: .raw,
                        postPasteAction: matched.action
                    )
                }
            }
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
            path: .deterministic,
            postPasteAction: deterministic.postPasteAction
        )
    }
}
