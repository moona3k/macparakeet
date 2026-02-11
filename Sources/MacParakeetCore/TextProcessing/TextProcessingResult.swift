import Foundation

public struct TextProcessingResult: Sendable {
    public let text: String
    public let expandedSnippetIDs: Set<UUID>

    public init(text: String, expandedSnippetIDs: Set<UUID> = []) {
        self.text = text
        self.expandedSnippetIDs = expandedSnippetIDs
    }
}
