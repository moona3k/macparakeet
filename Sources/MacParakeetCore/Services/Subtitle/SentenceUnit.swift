import Foundation

/// A contiguous run of `WordTimestamp`s that the segmenter has decided belong
/// to one natural-language unit (typically a sentence, but may be a clause
/// when punctuation is missing and only a long pause separates utterances).
///
/// Cue building inside `ExportService.buildSubtitleCues` runs *within* a
/// `SentenceUnit` — Phase 2/3/4 logic still chops long sentences into multiple
/// cues — but never *across* one. This is the structural fix for the 1-word
/// orphan fragmentation that gap-based flushing alone could not avoid.
public struct SentenceUnit: Sendable, Equatable {
    /// Inclusive first index into the source `[WordTimestamp]` array.
    public let startIndex: Int

    /// Inclusive last index into the source `[WordTimestamp]` array.
    public let endIndex: Int

    /// Concatenated text of the unit, joined from the source words with a
    /// single space. Used for diagnostics + tests.
    public let text: String

    /// `true` when the last word ends with `.`, `!`, or `?` — a confident
    /// sentence terminator. `false` for units that were forced open by a long
    /// pause when punctuation was missing.
    public let endsWithStrongPunctuation: Bool

    public init(
        startIndex: Int,
        endIndex: Int,
        text: String,
        endsWithStrongPunctuation: Bool
    ) {
        precondition(startIndex >= 0, "startIndex must be non-negative")
        precondition(endIndex >= startIndex, "endIndex must be ≥ startIndex")
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.text = text
        self.endsWithStrongPunctuation = endsWithStrongPunctuation
    }

    /// Convenience — number of source words contained in this unit.
    public var wordCount: Int { endIndex - startIndex + 1 }
}
