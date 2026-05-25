import Foundation

/// Parses + validates the JSON response the LLM returns from
/// `SubtitleLLMLayoutPlanner`.
///
/// The LLM only chooses split points. Each parsed `CueRange` is an
/// inclusive `[start, end]` interval into the chunk's word array. Caller
/// builds the actual cue text + timing from its own `[WordTimestamp]` —
/// the parser never trusts LLM-emitted text content.
enum LayoutPlanParser {

    /// A single cue's word-index range as decoded from the LLM response.
    struct CueRange: Equatable {
        let start: Int  // inclusive
        let end: Int    // inclusive
    }

    /// Why a parse attempt was rejected. Used for telemetry + tests; the
    /// caller falls back to the deterministic builder on any failure.
    enum LayoutFailure: Error, Equatable, CustomStringConvertible {
        case malformedJSON
        case missingCuesKey
        case emptyCues
        case rangeOutOfBounds(start: Int, end: Int, wordCount: Int)
        case rangeInverted(start: Int, end: Int)
        case gapBetweenCues(prevEnd: Int, nextStart: Int)
        case overlapBetweenCues(prevEnd: Int, nextStart: Int)
        case doesNotStartAtZero(firstStart: Int)
        case doesNotEndAtLast(lastEnd: Int, wordCount: Int)
        case cueExceedsBudget(cueIndex: Int, length: Int, cap: Int)

        var description: String {
            switch self {
            case .malformedJSON:                          return "malformedJSON"
            case .missingCuesKey:                         return "missingCuesKey"
            case .emptyCues:                              return "emptyCues"
            case .rangeOutOfBounds(let s, let e, let w):  return "rangeOutOfBounds(start=\(s),end=\(e),wordCount=\(w))"
            case .rangeInverted(let s, let e):            return "rangeInverted(start=\(s),end=\(e))"
            case .gapBetweenCues(let p, let n):           return "gapBetweenCues(prevEnd=\(p),nextStart=\(n))"
            case .overlapBetweenCues(let p, let n):       return "overlapBetweenCues(prevEnd=\(p),nextStart=\(n))"
            case .doesNotStartAtZero(let s):              return "doesNotStartAtZero(firstStart=\(s))"
            case .doesNotEndAtLast(let e, let w):         return "doesNotEndAtLast(lastEnd=\(e),wordCount=\(w))"
            case .cueExceedsBudget(let i, let l, let c):  return "cueExceedsBudget(cueIndex=\(i),length=\(l),cap=\(c))"
            }
        }
    }

    /// Parse and validate.
    ///
    /// - Parameters:
    ///   - response: raw text body returned by the LLM.
    ///   - words: the original word array the LLM was asked to lay out.
    ///   - perCueBudget: total cue character budget (e.g.
    ///     `maxCharsPerLine * maxLinesPerCue`). The parser allows up to
    ///     1.15× this before rejecting.
    ///   - maxGapToRepair: max number of consecutive missing word indices
    ///     the parser will silently roll into the previous cue. Defaults to
    ///     3; a `ModelProfile` with `parserLeniency = .lenient` raises this
    ///     to 5 (Gemma 4-class models that occasionally drop 4 indices),
    ///     `.strict` lowers it to 1.
    /// - Returns: validated cue ranges, or a failure reason.
    static func parse(
        _ response: String,
        words: [WordTimestamp],
        perCueBudget: Int,
        maxGapToRepair: Int = 3
    ) -> Result<[CueRange], LayoutFailure> {
        // Two pre-parse passes:
        //   - strip ```json fences some models add
        //   - strip JSONC comments (`// ...` line tails and `/* */`
        //     blocks). Real failure case: SRT 30 chunk 1303-1388 came
        //     back as `{"cues":[{"start":0,"end":8}, // We'll slow it
        //     down ...]}`. The LLM was mimicking arrow-annotations
        //     from the prompt's few-shot examples. JSONSerialization
        //     can't parse comments → whole transcript fell back.
        let defenced = stripCodeFences(response)
        let decommented = stripJSONComments(defenced)
        guard let cleaned = decommented.data(using: .utf8) else {
            return .failure(.malformedJSON)
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: cleaned, options: [.allowFragments])
        } catch {
            return .failure(.malformedJSON)
        }
        guard let dict = raw as? [String: Any] else {
            return .failure(.malformedJSON)
        }
        guard let cueArray = dict["cues"] as? [[String: Any]] else {
            return .failure(.missingCuesKey)
        }
        guard !cueArray.isEmpty else {
            return .failure(.emptyCues)
        }

        var ranges: [CueRange] = []
        ranges.reserveCapacity(cueArray.count)
        for (_, item) in cueArray.enumerated() {
            // Accept either Int or NSNumber from JSON.
            guard let startRaw = item["start"] as? NSNumber,
                  let endRaw = item["end"] as? NSNumber else {
                return .failure(.malformedJSON)
            }
            let start = startRaw.intValue
            let end = endRaw.intValue
            guard start >= 0, end >= 0, start < words.count, end < words.count else {
                return .failure(.rangeOutOfBounds(start: start, end: end, wordCount: words.count))
            }
            guard end >= start else {
                return .failure(.rangeInverted(start: start, end: end))
            }
            // Per-cue size is intentionally NOT enforced here. The LLM
            // tends to overshoot the configured budget (real data: 75–115
            // chars at a 65-char budget, with rare 190-char outliers).
            // `SubtitleLLMLayoutPlanner` post-processes the parsed ranges
            // and auto-splits any oversized cue at the best linguistic
            // break, so the chunk doesn't fall back wholesale to the
            // deterministic builder just because of one too-long cue.
            // `perCueBudget` is kept on the function signature so callers
            // can still pass it (the planner uses it for the split pass).
            _ = perCueBudget
            ranges.append(CueRange(start: start, end: end))
        }

        // Contiguity / coverage checks.
        guard ranges.first!.start == 0 else {
            return .failure(.doesNotStartAtZero(firstStart: ranges.first!.start))
        }
        guard ranges.last!.end == words.count - 1 else {
            return .failure(.doesNotEndAtLast(lastEnd: ranges.last!.end, wordCount: words.count))
        }
        // Two-pass: first auto-correct small overlaps (LLMs frequently
        // emit `prev.end == curr.start`, repeating one index), then
        // re-validate. Overlap auto-correction is safe because the
        // shared index unambiguously belongs to one cue or the other —
        // we keep it in the previous cue and bump the current cue's
        // start forward.
        ranges = autoCorrectOverlaps(ranges)
        // Auto-correct gaps the same way (LLM skipped one or two word
        // indices, e.g. `{end:9},{start:11}` — word 10 missing). We
        // extend the previous cue's end so the missing word(s) land in
        // it. This is safe content-wise (no transcript loss), and the
        // downstream `autoSplitOversizedRanges` will break the result
        // if extending pushes prev over budget. Real failure case: SRT
        // (38) had 4 chunks fall back to deterministic layout because
        // Gemma 4 occasionally drops a single index — each fallback
        // produced ~50 extra cues vs the LLM's intended layout.
        ranges = autoCorrectGaps(ranges, maxGapToRepair: maxGapToRepair)
        // After correction, drop any cue that became empty (start > end).
        ranges = ranges.filter { $0.start <= $0.end }
        // Re-validate coverage now that ranges may have shifted.
        guard let first = ranges.first, first.start == 0 else {
            return .failure(.doesNotStartAtZero(firstStart: ranges.first?.start ?? -1))
        }
        guard let last = ranges.last, last.end == words.count - 1 else {
            return .failure(.doesNotEndAtLast(lastEnd: ranges.last?.end ?? -1, wordCount: words.count))
        }
        for i in 1..<ranges.count {
            let prev = ranges[i - 1]
            let curr = ranges[i]
            if curr.start > prev.end + 1 {
                return .failure(.gapBetweenCues(prevEnd: prev.end, nextStart: curr.start))
            }
            if curr.start <= prev.end {
                // Auto-correct above should have fixed this — if not, the
                // overlap is wider than one index and we don't know how to
                // resolve it safely.
                return .failure(.overlapBetweenCues(prevEnd: prev.end, nextStart: curr.start))
            }
        }
        return .success(ranges)
    }

    /// Walk the range list once and bump `curr.start` to `prev.end + 1`
    /// whenever they would overlap. Wider overlaps (where `curr.end`
    /// also falls within the previous range) collapse to empty cues
    /// that the caller filters out. Real failure case: SRT 29 chunk
    /// 882-961 came back as
    /// `[{0,11},{12,20},{21,47},{48,50},{51,57},{58,69},{70,78},{78,79}]`
    /// — the LLM repeated index 78 across two cues. Pre-correction
    /// the whole chunk fell back to deterministic and the WHOLE
    /// 30-min transcript followed.
    private static func autoCorrectOverlaps(_ ranges: [CueRange]) -> [CueRange] {
        guard ranges.count > 1 else { return ranges }
        var out: [CueRange] = []
        out.reserveCapacity(ranges.count)
        out.append(ranges[0])
        for i in 1..<ranges.count {
            let prev = out.last!
            var curr = ranges[i]
            if curr.start <= prev.end {
                curr = CueRange(start: prev.end + 1, end: curr.end)
            }
            out.append(curr)
        }
        return out
    }

    /// Walk the range list once and extend `prev.end` to cover any
    /// missing indices between it and the next cue's start (LLM
    /// dropped one or two word indices when emitting JSON). Bounded by
    /// `maxGapToRepair` so a wildly broken response — e.g.
    /// `{end:0},{start:50}` — still falls back to the deterministic
    /// builder instead of mashing 49 words into one cue. Default 3;
    /// profile-driven `.lenient` raises this to 5 for Gemma 4-class
    /// models that occasionally drop a small run of indices.
    private static func autoCorrectGaps(_ ranges: [CueRange], maxGapToRepair: Int) -> [CueRange] {
        guard ranges.count > 1 else { return ranges }
        // Cap the repair distance so wide gaps still fall through to
        // the chunk fallback path. The default of 3 indices matches the
        // largest gap we've observed in the wild (Gemma 4 skipping a
        // single word, worst-case ~2 in a row). A profile-driven
        // `.lenient` setting raises this to 5 for models that drop more.
        var out: [CueRange] = []
        out.reserveCapacity(ranges.count)
        out.append(ranges[0])
        for i in 1..<ranges.count {
            let prev = out.removeLast()
            let curr = ranges[i]
            let gap = curr.start - (prev.end + 1)
            if gap > 0 && gap <= maxGapToRepair {
                // Roll the missing index(es) into prev.
                out.append(CueRange(start: prev.start, end: curr.start - 1))
                out.append(curr)
            } else {
                out.append(prev)
                out.append(curr)
            }
        }
        return out
    }

    /// Strip JSONC-style comments before handing to `JSONSerialization`.
    /// LLMs sometimes annotate output (especially when the prompt
    /// includes few-shot examples with arrow-comments), which makes the
    /// response syntactically invalid JSON. Drops `// ... to end-of-line`
    /// and `/* ... */` block comments. Comment characters inside string
    /// literals are preserved — we walk the input with a tiny state
    /// machine instead of regex-replacing globally.
    static func stripJSONComments(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var inString = false
        var prevWasEscape = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inString {
                out.append(c)
                if prevWasEscape {
                    prevWasEscape = false
                } else if c == "\\" {
                    prevWasEscape = true
                } else if c == "\"" {
                    inString = false
                }
                i = text.index(after: i)
                continue
            }
            if c == "\"" {
                inString = true
                out.append(c)
                i = text.index(after: i)
                continue
            }
            // Look for `//` line comment.
            let next = text.index(after: i)
            if c == "/", next < text.endIndex, text[next] == "/" {
                // Skip until newline.
                var j = next
                while j < text.endIndex && text[j] != "\n" { j = text.index(after: j) }
                i = j
                continue
            }
            // Look for `/* */` block comment.
            if c == "/", next < text.endIndex, text[next] == "*" {
                var j = text.index(after: next)
                while j < text.endIndex {
                    if text[j] == "*",
                       text.index(after: j) < text.endIndex,
                       text[text.index(after: j)] == "/" {
                        j = text.index(j, offsetBy: 2)
                        break
                    }
                    j = text.index(after: j)
                }
                i = j
                continue
            }
            out.append(c)
            i = text.index(after: i)
        }
        return out
    }

    /// Some models wrap JSON in ```json fences. Strip them if present so the
    /// JSON decoder doesn't choke.
    private static func stripCodeFences(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            // Drop the first line entirely (handles ```json, ```JSON, etc.)
            if let nl = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: nl)...])
            } else {
                t = ""
            }
        }
        if t.hasSuffix("```") {
            t = String(t.dropLast(3))
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
