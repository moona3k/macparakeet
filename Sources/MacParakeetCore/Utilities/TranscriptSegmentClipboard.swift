import Foundation

/// Pure formatting for copying a single transcript segment to the clipboard.
///
/// Kept here (Core) rather than in the view so the string shape is unit-testable
/// without the GUI. Segment timing is start-only (`TranscriptSegment.startMs`),
/// so the timestamped form carries the start label only.
public enum TranscriptSegmentClipboard {
    /// Clipboard string for one segment.
    ///
    /// With a timestamp it is `"[label] body"` (e.g. `"[12:03] Hello world"`);
    /// without, just the trimmed body. An empty/whitespace label falls back to
    /// the body alone so we never emit a bare `"[] …"`.
    public static func text(
        timestampLabel: String,
        body: String,
        includeTimestamp: Bool = true
    ) -> String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard includeTimestamp else { return trimmedBody }
        let label = timestampLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return trimmedBody }
        guard !trimmedBody.isEmpty else { return "[\(label)]" }
        return "[\(label)] \(trimmedBody)"
    }
}
