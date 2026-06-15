import Foundation

/// Turns the rolling, frequently-revised output of the live dictation preview
/// into a stable, append-only readout.
///
/// The preview transcriber feeds new text several times per second. For
/// Parakeet each update is a fresh transcription of a sliding ~15s audio window
/// (the oldest words drop off the front as the window advances); for Nemotron
/// each update is a cumulative partial whose tail churns. Either way the newest
/// few words are still forming while the older words are effectively final.
///
/// Rendering the raw stream makes already-settled words jump and flicker as the
/// window slides and words are revised. This type commits the stable body of
/// each update exactly once and only ever appends, keeping the most recent
/// `hypothesisHoldback` words tentative so an incomplete trailing word is never
/// frozen into the committed body.
///
/// Display-only: the pasted text always comes from the stop-time transcription
/// path, never from here, so stabilization can never alter inserted text.
///
/// Not thread-safe by itself — it is owned by the `DictationService` actor and
/// every call happens under that actor's isolation.
struct LiveTranscriptStabilizer {
    /// Words committed so far, in order. Append-only within a session.
    private(set) var committedWords: [String] = []

    /// Trailing words held back as a volatile hypothesis. The live edge of
    /// speech is always incomplete, so these are shown but not committed until a
    /// later pass pushes them into the stable body.
    private let hypothesisHoldback: Int

    /// Longest committed suffix considered when aligning a new update. Larger is
    /// more robust against repeated phrases at the cost of a little more work.
    private let anchorLength: Int

    /// Hard cap on retained committed words so a long dictation cannot grow the
    /// buffer without bound. The view only renders the last few lines anyway.
    private let maxCommittedWords: Int

    init(hypothesisHoldback: Int = 3, anchorLength: Int = 6, maxCommittedWords: Int = 120) {
        self.hypothesisHoldback = max(0, hypothesisHoldback)
        self.anchorLength = max(1, anchorLength)
        self.maxCommittedWords = max(1, maxCommittedWords)
    }

    /// Drop all committed state. Call at the start of every dictation session.
    mutating func reset() {
        committedWords = []
    }

    /// Feed the latest raw transcript; returns the stabilized display string
    /// (`committed + hypothesis`). Idempotent for a repeated identical input.
    @discardableResult
    mutating func ingest(_ raw: String) -> String {
        let words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            // Nothing transcribed this pass — keep showing what we have rather
            // than blanking the readout.
            return committedWords.joined(separator: " ")
        }

        let newFrom = newWordOffset(for: words)
        let newWords = Array(words[newFrom...])

        // Commit everything except the volatile tail; the held-back words remain
        // hypothesis until a later pass advances past them.
        let commitCount = max(0, newWords.count - hypothesisHoldback)
        if commitCount > 0 {
            committedWords.append(contentsOf: newWords[0..<commitCount])
            capCommitted()
        }
        let hypothesis = newWords[commitCount...]

        if hypothesis.isEmpty {
            return committedWords.joined(separator: " ")
        }
        return (committedWords + hypothesis).joined(separator: " ")
    }

    // MARK: - Alignment

    /// Index in `words` from which the words have not yet been committed.
    ///
    /// Aligns the tail of `committedWords` against `words`: finds the longest
    /// committed suffix (up to `anchorLength`) that occurs contiguously in
    /// `words`, preferring the leftmost occurrence, and returns the index just
    /// past it. Falls back sensibly when there is no overlap.
    ///
    /// Leftmost is correct for the cumulative case (a short committed prefix maps
    /// to the window's first copy, so a repeated phrase is preserved rather than
    /// collapsed) and equivalent for the dominant sliding-window case, where the
    /// long anchor occurs exactly once.
    private func newWordOffset(for words: [String]) -> Int {
        guard !committedWords.isEmpty else { return 0 }

        let normalizedWords = words.map(Self.normalize)
        let normalizedCommitted = committedWords.map(Self.normalize)

        let maxAnchor = min(anchorLength, normalizedCommitted.count, normalizedWords.count)
        var anchor = maxAnchor
        while anchor >= 1 {
            let tail = Array(normalizedCommitted.suffix(anchor))
            // A multi-word anchor is a confident alignment: take the leftmost
            // match so a repeated phrase ("the cat the cat") is preserved rather
            // than collapsed. A single-word anchor is a weak, ambiguous overlap;
            // take the rightmost match so an adjacent transcriber stutter ("the
            // the") advances past both copies instead of re-appending one.
            let matchEnd = anchor >= 2
                ? firstContiguousMatchEnd(of: tail, in: normalizedWords)
                : lastContiguousMatchEnd(of: tail, in: normalizedWords)
            if let matchEnd {
                return matchEnd
            }
            anchor -= 1
        }

        // No committed suffix appears in `words`. Either this is a genuine gap
        // (the speaker paused long enough that the window moved entirely past
        // the committed tail → everything is new) or `words` is a shorter
        // re-statement of text we already committed (a retraction → nothing
        // new). Disambiguate by checking whether `words` is already contained in
        // the committed buffer.
        if containsContiguous(normalizedCommitted, normalizedWords) {
            return words.count
        }
        return 0
    }

    /// Index just past the first (leftmost) contiguous occurrence of `pattern`
    /// in `sequence`, or nil if absent.
    private func firstContiguousMatchEnd(of pattern: [String], in sequence: [String]) -> Int? {
        guard !pattern.isEmpty, pattern.count <= sequence.count else { return nil }
        var start = 0
        while start <= sequence.count - pattern.count {
            if Array(sequence[start..<start + pattern.count]) == pattern {
                return start + pattern.count
            }
            start += 1
        }
        return nil
    }

    /// Index just past the last (rightmost) contiguous occurrence of `pattern`
    /// in `sequence`, or nil if absent.
    private func lastContiguousMatchEnd(of pattern: [String], in sequence: [String]) -> Int? {
        guard !pattern.isEmpty, pattern.count <= sequence.count else { return nil }
        var start = sequence.count - pattern.count
        while start >= 0 {
            if Array(sequence[start..<start + pattern.count]) == pattern {
                return start + pattern.count
            }
            start -= 1
        }
        return nil
    }

    /// Whether `needle` appears as a contiguous run anywhere in `haystack`.
    private func containsContiguous(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard needle.count <= haystack.count else { return false }
        var start = 0
        while start <= haystack.count - needle.count {
            if Array(haystack[start..<start + needle.count]) == needle {
                return true
            }
            start += 1
        }
        return false
    }

    private mutating func capCommitted() {
        if committedWords.count > maxCommittedWords {
            committedWords.removeFirst(committedWords.count - maxCommittedWords)
        }
    }

    /// Lowercased and stripped of leading/trailing punctuation, used only for
    /// alignment comparisons. Displayed words keep their original casing and
    /// punctuation — only the matching is normalized so a comma or a capital at
    /// a sentence boundary does not defeat overlap detection.
    static func normalize(_ word: String) -> String {
        let trimmed = word.trimmingCharacters(in: Self.alignmentTrimSet)
        return trimmed.isEmpty ? word.lowercased() : trimmed.lowercased()
    }

    private static let alignmentTrimSet = CharacterSet.punctuationCharacters
        .union(.symbols)
}
