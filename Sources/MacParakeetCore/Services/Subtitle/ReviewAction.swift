import Foundation

/// A single review decision the LLM can make about an adjacent cue pair.
///
/// The reviewer operates per pair (cue A, cue B) and returns one of:
/// - `.keep` — both cues read fine, no change.
/// - `.merge` — combine A and B into one cue.
/// - `.shiftToA(n)` — move `n` words from the start of B to the end of A.
/// - `.shiftToB(n)` — move `n` words from the end of A to the start of B.
///
/// The LLM never controls cue text directly — these actions only adjust
/// where the cue boundary falls. `n` is bounded to `1...3` so a single
/// review can't reshape a cue dramatically; the deterministic validator
/// will reject larger jumps regardless.
///
/// `split_a` / `split_b` are intentionally NOT in v1: the existing
/// `autoSplitOversizedRanges` pass already breaks oversized cues at
/// the best linguistic point, and splitting needs accurate word-level
/// timestamps that LLM-laid-out cues don't carry. Add later if real
/// failure data shows a need.
public enum ReviewAction: Equatable, Sendable {
    case keep
    case merge
    case shiftToA(n: Int)
    case shiftToB(n: Int)
}

/// Result of parsing a single LLM review response.
public enum ReviewActionParseResult: Equatable {
    case success(ReviewAction)
    case failure(ReviewActionParseFailure)
}

public enum ReviewActionParseFailure: Error, Equatable, CustomStringConvertible {
    case malformedJSON
    case missingActionKey
    case unknownAction(String)
    case missingNForShift(String)
    case nOutOfRange(action: String, n: Int)
    case missingDecisionsKey
    case missingPairIndex

    public var description: String {
        switch self {
        case .malformedJSON:                  return "malformedJSON"
        case .missingActionKey:               return "missingActionKey"
        case .unknownAction(let s):           return "unknownAction(\(s))"
        case .missingNForShift(let s):        return "missingNForShift(\(s))"
        case .nOutOfRange(let s, let n):      return "nOutOfRange(\(s),n=\(n))"
        case .missingDecisionsKey:            return "missingDecisionsKey"
        case .missingPairIndex:               return "missingPairIndex"
        }
    }
}

/// One decoded decision out of a batched reviewer response. `pairIndex`
/// is BATCH-LOCAL (0-based within the batch the LLM was given); the
/// caller maps it back to absolute cue-list indices.
public struct ReviewBatchDecision: Equatable {
    public let pairIndex: Int
    public let action: ReviewAction
}

public enum ReviewBatchParseResult: Equatable {
    case success([ReviewBatchDecision])
    case failure(ReviewActionParseFailure)
}

/// Parses + validates a single LLM review response.
///
/// Tolerant of the same JSON quirks `LayoutPlanParser` handles (code
/// fences, line/block comments), since the same models produce both
/// responses and drift into the same shapes.
public enum ReviewActionParser {

    /// Parse one cue pair's LLM response into a `ReviewAction`.
    public static func parse(_ response: String) -> ReviewActionParseResult {
        let defenced = stripCodeFences(response)
        let decommented = LayoutPlanParser.stripJSONComments(defenced)
        guard let data = decommented.data(using: .utf8) else {
            return .failure(.malformedJSON)
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
        } catch {
            return .failure(.malformedJSON)
        }
        guard let dict = raw as? [String: Any] else {
            return .failure(.malformedJSON)
        }
        guard let actionRaw = dict["action"] as? String else {
            return .failure(.missingActionKey)
        }
        let action = actionRaw.lowercased()
        switch action {
        case "keep":
            return .success(.keep)
        case "merge":
            return .success(.merge)
        case "shift_to_a":
            guard let n = (dict["n"] as? NSNumber)?.intValue else {
                return .failure(.missingNForShift("shift_to_a"))
            }
            guard (1...3).contains(n) else {
                return .failure(.nOutOfRange(action: "shift_to_a", n: n))
            }
            return .success(.shiftToA(n: n))
        case "shift_to_b":
            guard let n = (dict["n"] as? NSNumber)?.intValue else {
                return .failure(.missingNForShift("shift_to_b"))
            }
            guard (1...3).contains(n) else {
                return .failure(.nOutOfRange(action: "shift_to_b", n: n))
            }
            return .success(.shiftToB(n: n))
        default:
            return .failure(.unknownAction(actionRaw))
        }
    }

    /// Parse a BATCHED LLM response shaped like
    /// `{"decisions": [{"pair": 0, "action": "keep"}, {"pair": 1,
    /// "action": "shift_to_a", "n": 2}, ...]}`.
    ///
    /// `pair` is the batch-local index (0 .. batchPairCount - 1). The
    /// caller is responsible for mapping that back to absolute cue
    /// indices and for filling in `.keep` for any pair the LLM omitted.
    ///
    /// Returns ONLY successfully-parsed decisions — a malformed
    /// individual decision is silently dropped rather than failing the
    /// whole batch. This matches the philosophy of `applyReviewSuggestions`
    /// (which already re-validates every suggestion against deterministic
    /// guards and skips invalid ones).
    public static func parseBatch(_ response: String) -> ReviewBatchParseResult {
        let defenced = stripCodeFences(response)
        let decommented = LayoutPlanParser.stripJSONComments(defenced)
        guard let data = decommented.data(using: .utf8) else {
            return .failure(.malformedJSON)
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
        } catch {
            return .failure(.malformedJSON)
        }
        guard let dict = raw as? [String: Any] else {
            return .failure(.malformedJSON)
        }
        guard let arr = dict["decisions"] as? [[String: Any]] else {
            return .failure(.missingDecisionsKey)
        }
        var out: [ReviewBatchDecision] = []
        out.reserveCapacity(arr.count)
        for item in arr {
            // Accept `pair` or `index` (model drift tolerance).
            let pairRaw = (item["pair"] as? NSNumber) ?? (item["index"] as? NSNumber)
            guard let pair = pairRaw?.intValue, pair >= 0 else { continue }
            guard let actionRaw = item["action"] as? String else { continue }
            switch actionRaw.lowercased() {
            case "keep":
                out.append(ReviewBatchDecision(pairIndex: pair, action: .keep))
            case "merge":
                out.append(ReviewBatchDecision(pairIndex: pair, action: .merge))
            case "shift_to_a":
                guard let n = (item["n"] as? NSNumber)?.intValue, (1...3).contains(n) else { continue }
                out.append(ReviewBatchDecision(pairIndex: pair, action: .shiftToA(n: n)))
            case "shift_to_b":
                guard let n = (item["n"] as? NSNumber)?.intValue, (1...3).contains(n) else { continue }
                out.append(ReviewBatchDecision(pairIndex: pair, action: .shiftToB(n: n)))
            default:
                continue
            }
        }
        return .success(out)
    }

    /// Strip ```...``` code fences if the model wrapped its response.
    /// Mirrors `LayoutPlanParser.stripCodeFences` (which is private to
    /// that file); kept here to avoid coupling the two parsers.
    private static func stripCodeFences(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
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
