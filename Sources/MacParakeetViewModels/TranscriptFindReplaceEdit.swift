import Foundation
import MacParakeetCore

/// Turns find-and-replace results over timed segments into one text
/// correction: the same command the reading editor saves, so a Replace All is
/// a single entry in the correction history and undoes in one step.
public enum TranscriptFindReplaceEdit {
    /// Where to resume in the saved line after a single replacement of
    /// `match`. Saving trims the line's leading whitespace, and a blank line is
    /// omitted so its successor takes the same index; either way the offset
    /// shifts left, and not adjusting it would skip the next match.
    public static func resumeOffset(
        after match: TranscriptFindModel.Match,
        replacement: String,
        in replaced: TranscriptFindModel.Replacement
    ) -> Int {
        let content = (replaced.text as NSString).rangeOfCharacter(
            from: CharacterSet.whitespacesAndNewlines.inverted
        )
        guard content.location != NSNotFound else { return 0 }
        return max(0, match.range.location + replacement.utf16.count - content.location)
    }

    /// `segments` are the blocks the find model searched, in the same order.
    /// Returns `nil` when nothing would change, or when a replacement names a
    /// block that is not one of `segments`.
    public static func command(
        for replacements: [TranscriptFindModel.Replacement],
        in segments: [SpeakerEditableSegment]
    ) -> SpeakerCorrectionCommand? {
        var drafts: [TranscriptReadingDraft] = []
        for change in replacements {
            guard segments.indices.contains(change.blockIndex) else { return nil }
            let segment = segments[change.blockIndex]
            drafts.append(
                TranscriptReadingDraft(
                    target: SpeakerCorrectionTarget(
                        anchorTranscriptSegmentIDs: segment.anchorTranscriptSegmentIDs,
                        wordRange: segment.wordRange
                    ),
                    originalText: segment.text,
                    text: change.text
                )
            )
        }
        return TranscriptReadingEdit.command(for: drafts)
    }
}
