import Foundation

/// Pure, testable matcher backing the in-transcript find bar
/// (Transcript Detail Refresh / U2).
///
/// The model is deliberately ignorant of SwiftUI and of how the transcript is
/// rendered. It searches an ordered list of text *blocks* — segment text in
/// Timed mode, or the full transcript in Text mode; the view decides which —
/// and produces a single globally ordered match list. The view owns the mapping
/// from a match's `blockIndex` back to a scroll anchor and the highlight
/// rendering.
/// Keeping the matcher here makes it unit-testable and keeps the find logic
/// out of the ~3k-line `TranscriptResultView`.
///
/// Match positions are stored as `NSRange` (UTF-16 offsets) relative to the
/// owning block's text. UTF-16 offsets bridge cleanly to `AttributedString`
/// highlighting in the view and are trivial to assert in tests.
@MainActor
@Observable
public final class TranscriptFindModel {
    public struct Match: Equatable, Sendable {
        /// Index into the blocks last passed to `setBlocks`.
        public let blockIndex: Int
        /// UTF-16 range of the match within that block's text.
        public let range: NSRange

        public init(blockIndex: Int, range: NSRange) {
            self.blockIndex = blockIndex
            self.range = range
        }
    }

    /// Current search query. Mutate through `setQuery` so matches recompute.
    public private(set) var query: String = ""

    /// All matches across all blocks, in reading order (block order, then
    /// position within each block).
    public private(set) var matches: [Match] = []

    /// Index into `matches` of the emphasized ("current") match, or `nil`
    /// when there are no matches.
    public private(set) var currentMatchIndex: Int?

    private var blocks: [String] = []

    public init() {}

    // MARK: - Mutation

    /// Update the query and recompute matches. Resets the cursor to the first
    /// match. A trimmed-empty query clears all matches.
    public func setQuery(_ newValue: String) {
        guard newValue != query else { return }
        query = newValue
        recompute()
    }

    /// Replace the searched content and re-run the current query against it.
    /// Used when the reading surface changes (Text↔Timed mode, a new
    /// transcript loads) so the live find session stays in sync. Keeps the
    /// current match when the same block/range still exists, otherwise keeps
    /// the same ordinal where possible instead of jumping back to the start.
    public func setBlocks(_ blocks: [String]) {
        let previousCurrent = current
        let previousIndex = currentMatchIndex
        self.blocks = blocks
        recompute(preserving: previousCurrent, preferredIndex: previousIndex)
    }

    /// Clear the query and all matches.
    public func clear() {
        setQuery("")
    }

    /// Advance the cursor to the next match, wrapping at the end.
    public func next() {
        guard !matches.isEmpty else { return }
        let i = currentMatchIndex ?? -1
        currentMatchIndex = (i + 1) % matches.count
    }

    /// Move the cursor to the previous match, wrapping at the start.
    public func prev() {
        guard !matches.isEmpty else { return }
        let i = currentMatchIndex ?? 0
        currentMatchIndex = (i - 1 + matches.count) % matches.count
    }

    // MARK: - Derived state

    public var matchCount: Int { matches.count }
    public var hasMatches: Bool { !matches.isEmpty }

    /// The emphasized match, or `nil` when there are none.
    public var current: Match? {
        guard let i = currentMatchIndex, matches.indices.contains(i) else { return nil }
        return matches[i]
    }

    /// 1-based "current of total" position for the counter, or `nil` when
    /// there are no matches.
    public var displayPosition: (current: Int, total: Int)? {
        guard let i = currentMatchIndex, !matches.isEmpty else { return nil }
        return (i + 1, matches.count)
    }

    // MARK: - Matching

    private func recompute(preserving previousCurrent: Match? = nil, preferredIndex: Int? = nil) {
        // Guard against empty / whitespace-only queries, but search with the
        // untrimmed query so a user can match leading/trailing spaces — e.g.
        // " the " finds the word, not the "the" inside "there" or "other".
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            matches = []
            currentMatchIndex = nil
            return
        }
        let needle = query

        var result: [Match] = []
        // Case- and diacritic-insensitive so "cafe" finds "Café" and "naive"
        // finds "naïve". Matching runs against each block's original text, so
        // the returned ranges map straight back onto what the view renders.
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        for (blockIndex, text) in blocks.enumerated() where !text.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: needle, options: options, range: searchStart..<text.endIndex) {
                result.append(Match(blockIndex: blockIndex, range: NSRange(found, in: text)))
                // Advance past this match; never less than one character so a
                // degenerate zero-width match can't spin forever.
                searchStart = found.upperBound > found.lowerBound
                    ? found.upperBound
                    : text.index(after: found.lowerBound)
            }
        }

        matches = result
        guard !result.isEmpty else {
            currentMatchIndex = nil
            return
        }
        if let previousCurrent,
           let retainedIndex = result.firstIndex(of: previousCurrent) {
            currentMatchIndex = retainedIndex
        } else if let preferredIndex {
            currentMatchIndex = min(max(preferredIndex, 0), result.count - 1)
        } else {
            currentMatchIndex = 0
        }
    }
}
