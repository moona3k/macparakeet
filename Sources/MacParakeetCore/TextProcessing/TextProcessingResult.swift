import Foundation

public struct TextProcessingResult: Sendable {
    public let text: String
    public let expandedSnippetIDs: Set<UUID>
    public let postPasteAction: KeyAction?

    public init(
        text: String,
        expandedSnippetIDs: Set<UUID> = [],
        postPasteAction: KeyAction? = nil
    ) {
        self.text = text
        self.expandedSnippetIDs = expandedSnippetIDs
        self.postPasteAction = postPasteAction
    }
}
