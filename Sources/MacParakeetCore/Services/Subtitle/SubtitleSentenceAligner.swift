import Foundation

/// Pure helper used by `SubtitleSentenceSegmenter`.
///
/// Builds a single joined-text view of a `[WordTimestamp]` array and remembers
/// each word's character span inside that text. Given a character range
/// (typically from `NLTokenizer(unit: .sentence)`), it can return the inclusive
/// word-index range that range covers — even when the boundary lands mid-word
/// or inside a punctuation run.
///
/// Lives outside the `@MainActor`-isolated `ExportService` so it is callable
/// from non-main contexts and easy to fuzz-test.
enum SubtitleSentenceAligner {

    /// One word's position inside the joined text.
    struct WordSpan: Equatable {
        let wordIndex: Int
        let textStart: Int   // inclusive UTF-16 offset into `joinedText`
        let textEnd: Int     // exclusive UTF-16 offset into `joinedText`
    }

    /// Joined view of all words plus per-word spans into that view.
    struct AlignedView {
        let joinedText: String
        let spans: [WordSpan]
    }

    /// Joins words with single spaces. Records the exact UTF-16 character
    /// offset where each word starts and ends. Uses UTF-16 because that's
    /// what `NSRange` (and therefore `NLTokenizer`'s `tokens(for: NSRange)`)
    /// operates on.
    static func align(words: [WordTimestamp]) -> AlignedView {
        var spans: [WordSpan] = []
        spans.reserveCapacity(words.count)
        var joined = ""
        var cursor = 0  // running UTF-16 offset

        for (i, w) in words.enumerated() {
            if i > 0 {
                joined.append(" ")
                cursor += 1
            }
            let start = cursor
            joined.append(w.word)
            // utf16.count is correct for NSRange interop with NLTokenizer.
            cursor += w.word.utf16.count
            spans.append(WordSpan(wordIndex: i, textStart: start, textEnd: cursor))
        }
        return AlignedView(joinedText: joined, spans: spans)
    }

    /// Translate a character range (`NSRange` location/length) inside the
    /// joined text into an inclusive `(startIndex, endIndex)` word range.
    ///
    /// - Returns: `nil` if no word overlaps the range at all (e.g. range is
    ///   entirely inside a separator space). Otherwise the smallest inclusive
    ///   span of word indices that touches the range.
    static func wordRange(
        forCharRange charLocation: Int,
        length charLength: Int,
        in view: AlignedView
    ) -> (startIndex: Int, endIndex: Int)? {
        guard charLength > 0, !view.spans.isEmpty else { return nil }
        let rangeStart = charLocation
        let rangeEnd = charLocation + charLength  // exclusive

        var startWord: Int? = nil
        var endWord: Int? = nil
        for span in view.spans {
            // A word participates if its span overlaps the requested range.
            // Overlap test: span.textStart < rangeEnd && span.textEnd > rangeStart.
            if span.textStart < rangeEnd && span.textEnd > rangeStart {
                if startWord == nil { startWord = span.wordIndex }
                endWord = span.wordIndex
            } else if endWord != nil {
                // We've left the overlap region — no more words can match.
                break
            }
        }
        guard let s = startWord, let e = endWord else { return nil }
        return (s, e)
    }
}
