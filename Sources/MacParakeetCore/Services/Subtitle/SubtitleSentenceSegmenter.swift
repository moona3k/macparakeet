import Foundation
import NaturalLanguage

/// Splits a `[WordTimestamp]` array into `SentenceUnit`s using Apple's
/// `NLTokenizer(unit: .sentence)` on a joined view of the word stream.
///
/// Why this exists: Parakeet (and ASR engines in general that return only
/// per-word timing) leave the subtitle pipeline with no native sentence
/// signal. Before this type, `ExportService.buildSubtitleCues` derived cue
/// boundaries from inter-word silence alone — which both creates 1-word
/// orphan cues at every natural pause AND prevents the orphan-merge pass
/// from re-absorbing them. Running NLTokenizer here gives downstream cue
/// building a natural-language structure to respect.
///
/// Honorifics like `Mr.`, `Dr.`, `etc.` would confuse NLTokenizer into
/// declaring premature sentence boundaries; a post-filter merges any unit
/// ending in one of those into the next.
public enum SubtitleSentenceSegmenter {

    /// Common abbreviations that end in `.` and should NOT be treated as
    /// sentence terminators. Lowercased, no trailing dot.
    private static let honorifics: Set<String> = [
        "mr", "mrs", "ms", "dr", "sr", "jr",
        "st", "ave", "blvd", "rd", "pl",
        "vs", "etc", "ie", "eg",
        "approx", "inc", "ltd", "co",
    ]

    /// - Parameters:
    ///   - words: source word timestamps (already sanitized by `ExportService`).
    ///   - cleanedText: reserved for future use — when a higher-quality
    ///     cleaned transcript is available it could replace the raw word join
    ///     as the NLTokenizer input. Currently ignored: tokenizing the raw
    ///     joined words avoids the cleaned-vs-raw alignment problem entirely
    ///     because Parakeet attaches its own punctuation to each word.
    ///   - longPauseMs: gap above which we force a unit break even if
    ///     NLTokenizer didn't see a sentence boundary. Catches unpunctuated
    ///     speech.
    public static func segment(
        words: [WordTimestamp],
        cleanedText: String? = nil,
        longPauseMs: Int = 1500
    ) -> [SentenceUnit] {
        _ = cleanedText  // intentionally unused for now; documented above
        guard !words.isEmpty else { return [] }

        let view = SubtitleSentenceAligner.align(words: words)

        // Step 1: run NLTokenizer on the joined text to get raw sentence
        // boundaries.
        var rawUnits: [(start: Int, end: Int)] = []  // inclusive word indices
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = view.joinedText
        let full = view.joinedText.startIndex..<view.joinedText.endIndex
        tokenizer.enumerateTokens(in: full) { sentenceRange, _ in
            let ns = NSRange(sentenceRange, in: view.joinedText)
            if let (s, e) = SubtitleSentenceAligner.wordRange(
                forCharRange: ns.location,
                length: ns.length,
                in: view
            ) {
                rawUnits.append((s, e))
            }
            return true
        }

        // Defensive fallback — if NLTokenizer found nothing (shouldn't
        // happen for non-empty text), emit one giant unit.
        if rawUnits.isEmpty {
            rawUnits = [(0, words.count - 1)]
        } else {
            // Make sure the units fully cover the word array. If the
            // tokenizer skipped a leading/trailing whitespace word, extend.
            if rawUnits.first!.start > 0 {
                rawUnits[0].start = 0
            }
            if rawUnits.last!.end < words.count - 1 {
                rawUnits[rawUnits.count - 1].end = words.count - 1
            }
            // And patch any gap between consecutive units (shouldn't occur
            // with our overlap logic, but cheap to guarantee).
            for i in 1..<rawUnits.count {
                if rawUnits[i].start > rawUnits[i - 1].end + 1 {
                    rawUnits[i - 1].end = rawUnits[i].start - 1
                }
            }
        }

        // Step 2: merge honorific-trailing units into the next.
        var merged: [(start: Int, end: Int)] = []
        var i = 0
        while i < rawUnits.count {
            var unit = rawUnits[i]
            while i + 1 < rawUnits.count && endsInHonorific(words[unit.end].word) {
                i += 1
                unit.end = rawUnits[i].end
            }
            merged.append(unit)
            i += 1
        }

        // Step 3: long-pause fallback split — for each unit, scan internal
        // gaps and split when any inter-word silence exceeds longPauseMs.
        // This catches the runaway-paragraph case where Parakeet emitted no
        // sentence-terminating punctuation at all.
        var withFallback: [(start: Int, end: Int)] = []
        for unit in merged {
            var segmentStart = unit.start
            if unit.start < unit.end {
                for j in unit.start..<unit.end {
                    let gap = words[j + 1].startMs - words[j].endMs
                    if gap >= longPauseMs {
                        withFallback.append((segmentStart, j))
                        segmentStart = j + 1
                    }
                }
            }
            withFallback.append((segmentStart, unit.end))
        }

        // Step 4: build SentenceUnits with text + strong-punctuation flag.
        return withFallback.map { unit in
            let text = words[unit.start...unit.end]
                .map(\.word)
                .joined(separator: " ")
            let lastWord = words[unit.end].word
            let strong = lastWord.last.map { ".!?".contains($0) } ?? false
            return SentenceUnit(
                startIndex: unit.start,
                endIndex: unit.end,
                text: text,
                endsWithStrongPunctuation: strong
            )
        }
    }

    /// `true` if `word` ends with `.` and the preceding token (lowercased,
    /// no dot) is in `honorifics`.
    private static func endsInHonorific(_ word: String) -> Bool {
        guard word.last == "." else { return false }
        let stem = word.dropLast().lowercased()
        return honorifics.contains(String(stem))
    }
}
