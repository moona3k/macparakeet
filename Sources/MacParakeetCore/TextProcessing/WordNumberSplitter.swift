import Foundation

/// Splits Parakeet-style fused letter+digit tokens back into separate words.
///
/// Parakeet (and occasionally Whisper) emits tokens like `next30`, `the980`,
/// `high90s,` as a single word with no space between the alphabetic prefix
/// and the numeric portion. This helper re-introduces the missing space.
///
/// Conservative on purpose — only splits when:
///   - prefix is **all lowercase** (`next`, `the`, `arms`) or **title case**
///     (`Next`, `The`, `Hello`) and at least 2 letters long, AND
///   - digit run is at least 2 characters long.
///
/// This intentionally leaves legitimate alphanumerics alone:
///   - `MP3`, `MP4` — digit run too short
///   - `iPhone15` — prefix is mixed case (camelCase)
///   - `H2O`, `v3` — prefix too short and digit run too short
///   - `1080p`, `90s` — tokens starting with digits
///
/// If a real-world false-positive shows up later, prefer narrowing the
/// regex over adding a denylist.
public enum WordNumberSplitter: Sendable {

    /// Matches the *start* of a fused token: letter prefix, then 2+ digits.
    /// Used by both the token-level and text-level entry points. Anything
    /// after the digit run is preserved verbatim by both code paths.
    ///
    /// `\b` anchors at a word boundary so we don't slice into the middle of
    /// surrounding text. `(?=\D|$)` (after the digits) keeps us from
    /// matching only part of a longer digit run.
    private static let pattern = #"\b((?:[\p{Ll}]{2,})|(?:\p{Lu}\p{Ll}+))(\d{2,})(?=\D|$)"#

    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Apply the split to a free-form string. Inserts a single space between
    /// each fused letter+digit pair. Idempotent: running it on already-split
    /// text returns the same text.
    public static func splitInText(_ text: String) -> String {
        guard let regex, !text.isEmpty else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1 $2"
        )
    }

    /// Apply the split to a sequence of word tokens by rewriting each fused
    /// token's `.word` string to contain an interior space (`"next30"` →
    /// `"next 30"`). Timing, confidence, speaker id, and token *count* stay
    /// exactly the same.
    ///
    /// Keeping the original `WordTimestamp` (rather than producing two
    /// timestamps with proportional timing) deliberately avoids inflating
    /// downstream word counts. The subtitle cue builder uses word count as
    /// one of its split heuristics; splitting `arms30.` into two timestamps
    /// would push borderline cues over the cap and create awkward
    /// single-word trailing cues (`"30."` on its own line) that aren't
    /// present in the original transcript.
    ///
    /// Trailing characters after the digit run (plural `s`, punctuation,
    /// closing quotes) stay with the numeric half: `high90s,` becomes
    /// `high 90s,`, never `high 90 s,`.
    public static func splitWords(_ words: [WordTimestamp]) -> [WordTimestamp] {
        guard regex != nil else { return words }
        return words.map { w in
            guard let parts = splitToken(w.word) else { return w }
            return WordTimestamp(
                word: parts.prefix + " " + parts.suffix,
                startMs: w.startMs,
                endMs: w.endMs,
                confidence: w.confidence,
                speakerId: w.speakerId
            )
        }
    }

    /// Returns `(prefix, suffix)` if `token` matches the fused pattern, else `nil`.
    /// `prefix` is the alphabetic head; `suffix` is the digits plus anything
    /// trailing (`s`, punctuation). Splits at most once per token — fused
    /// stacks like `the30arms40` would only have the first pair separated,
    /// which we accept as good-enough given how rarely they occur.
    static func splitToken(_ token: String) -> (prefix: String, suffix: String)? {
        guard let regex else { return nil }
        let nsToken = token as NSString
        let range = NSRange(location: 0, length: nsToken.length)
        guard let match = regex.firstMatch(in: token, range: range) else { return nil }
        // Group 1 is the letter prefix; the digit run begins at group 2's start.
        let prefixRange = match.range(at: 1)
        let digitsRange = match.range(at: 2)
        guard prefixRange.location != NSNotFound, digitsRange.location != NSNotFound else { return nil }
        let prefix = nsToken.substring(with: prefixRange)
        // Suffix = everything from the start of the digit run to the end of
        // the original token, so trailing punctuation / plural-s stays put.
        let suffixStart = digitsRange.location
        let suffix = nsToken.substring(with: NSRange(location: suffixStart, length: nsToken.length - suffixStart))
        return (prefix, suffix)
    }
}
