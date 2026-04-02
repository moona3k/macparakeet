import Foundation

/// Result of processing a dictation — carries the persisted Dictation
/// plus any ephemeral post-paste action from the text processing pipeline.
public struct DictationResult: Sendable {
    public let dictation: Dictation
    public let postPasteAction: KeyAction?

    public init(dictation: Dictation, postPasteAction: KeyAction? = nil) {
        self.dictation = dictation
        self.postPasteAction = postPasteAction
    }
}
