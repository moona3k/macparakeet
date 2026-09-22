import Foundation

/// Result of processing a dictation: the persisted row plus ephemeral paste context.
public struct DictationResult: Sendable {
    public let dictation: Dictation
    public let insertionStyle: DictationInsertionStyle
    public let postPasteAction: KeyAction?
    /// Stop request → WAV ready. Present on successful capture finalization.
    public let captureMs: Int?
    /// WAV ready → pasteable text, including formatter. Excludes overlay pause.
    public let transcribeMs: Int?
    public let operationID: String?

    public init(
        dictation: Dictation,
        insertionStyle: DictationInsertionStyle = .sentence,
        postPasteAction: KeyAction? = nil,
        captureMs: Int? = nil,
        transcribeMs: Int? = nil,
        operationID: String? = nil
    ) {
        self.dictation = dictation
        self.insertionStyle = insertionStyle
        self.postPasteAction = postPasteAction
        self.captureMs = captureMs
        self.transcribeMs = transcribeMs
        self.operationID = operationID
    }
}
