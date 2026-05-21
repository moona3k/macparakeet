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
    /// - Returns: validated cue ranges, or a failure reason.
    static func parse(
        _ response: String,
        words: [WordTimestamp],
        perCueBudget: Int
    ) -> Result<[CueRange], LayoutFailure> {
        guard let cleaned = stripCodeFences(response).data(using: .utf8) else {
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
        let cap = max(perCueBudget, perCueBudget * 115 / 100)
        for (i, item) in cueArray.enumerated() {
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
            // Per-cue text-length cap. Joined-by-space length, not literal
            // string content — the LLM didn't choose words, we did.
            let joined = words[start...end].map(\.word).joined(separator: " ")
            if joined.count > cap {
                return .failure(.cueExceedsBudget(cueIndex: i, length: joined.count, cap: cap))
            }
            ranges.append(CueRange(start: start, end: end))
        }

        // Contiguity / coverage checks.
        guard ranges.first!.start == 0 else {
            return .failure(.doesNotStartAtZero(firstStart: ranges.first!.start))
        }
        guard ranges.last!.end == words.count - 1 else {
            return .failure(.doesNotEndAtLast(lastEnd: ranges.last!.end, wordCount: words.count))
        }
        for i in 1..<ranges.count {
            let prev = ranges[i - 1]
            let curr = ranges[i]
            if curr.start > prev.end + 1 {
                return .failure(.gapBetweenCues(prevEnd: prev.end, nextStart: curr.start))
            }
            if curr.start <= prev.end {
                return .failure(.overlapBetweenCues(prevEnd: prev.end, nextStart: curr.start))
            }
        }
        return .success(ranges)
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
