import SwiftUI

/// Builds the highlighted `AttributedString` for an in-transcript find match
/// (Transcript Detail Refresh / U2). Shared by the Timed-mode segment rows and
/// the Text-mode full transcript so the highlight treatment stays identical.
///
/// Ranges are UTF-16 `NSRange`s relative to `text` (as produced by
/// `TranscriptFindModel`). The "current" match gets a stronger background and a
/// bold weight; the others get a quiet accent wash. Coral comes only through
/// `DesignSystem.Colors.accent` tokens — never a hosting-root tint.
enum TranscriptFindHighlight {
    static func attributed(
        _ text: String,
        ranges: [NSRange],
        current: NSRange?,
        baseFont: Font
    ) -> AttributedString {
        var attr = AttributedString(text)
        attr.font = baseFont
        for nsRange in ranges {
            guard let range = attributedRange(nsRange, in: text, attr: attr) else { continue }
            let isCurrent = (nsRange == current)
            attr[range].backgroundColor = isCurrent
                ? DesignSystem.Colors.accent.opacity(0.55)
                : DesignSystem.Colors.accent.opacity(0.22)
            if isCurrent {
                attr[range].font = baseFont.bold()
            }
        }
        return attr
    }

    /// Converts a UTF-16 `NSRange` over `string` into the matching
    /// `AttributedString` index range. Returns `nil` if the range can't be
    /// mapped (stale/clamped input), so the caller simply skips that highlight.
    private static func attributedRange(
        _ nsRange: NSRange,
        in string: String,
        attr: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard let strRange = Range(nsRange, in: string),
              let lower = AttributedString.Index(strRange.lowerBound, within: attr),
              let upper = AttributedString.Index(strRange.upperBound, within: attr) else {
            return nil
        }
        return lower..<upper
    }
}
