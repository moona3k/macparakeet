import Foundation

/// Result of processing a dictation: the persisted row plus ephemeral paste context.
public struct DictationResult: Sendable {
    public let dictation: Dictation
    public let insertionStyle: DictationInsertionStyle
    public let postPasteAction: KeyAction?

    public init(
        dictation: Dictation,
        insertionStyle: DictationInsertionStyle = .sentence,
        postPasteAction: KeyAction? = nil
    ) {
        self.dictation = dictation
        self.insertionStyle = insertionStyle
        self.postPasteAction = postPasteAction
    }
}
