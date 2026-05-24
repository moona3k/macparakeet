import Foundation

/// Rule-based conversion of unambiguous spelled-out English cardinal
/// numbers to their digit form (e.g., `twenty-five` -> `25`).
///
/// Scope (Phase 1, refined after real-transcript review):
///   - teens (`ten`..`nineteen`),
///   - tens (`twenty`..`ninety`),
///   - hyphenated and space-separated tens+ones compounds
///     (`twenty-five`, `forty three`),
///   - hundred-cardinals (`one hundred`..`nine hundred` -> `100`..`900`),
///   - the "X oh Y" form fitness instructors use for 101–109, 201–209,
///     etc. (`one oh five` -> `105`).
///
/// **1-9 cardinals are intentionally left spelled out**, per
/// standard editorial convention (AP / Chicago style: spell out
/// one through nine, use digits for 10+). An earlier version had a
/// measurement-context pass that converted `four minutes` to `4
/// minutes`, but the digit-only form read awkwardly in subtitles
/// (SRT 35 feedback: "some of the numbers were converted to digits
/// which is a bit strange"). The other passes already cover every
/// number ≥10 correctly via standalone / compound / hundred / oh
/// patterns, so we just stop touching 1-9.
public enum NumberNormalizer: Sendable {

    /// Words that map to a tens (or teen) value on their own.
    private static let tensMap: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    /// Single-digit ones used only as the trailing half of a compound
    /// (`twenty-FIVE`). Never converted on their own.
    private static let onesMap: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9
    ]

    private static let tensAlternation = tensMap.keys.sorted().joined(separator: "|")
    private static let onesAlternation = onesMap.keys.sorted().joined(separator: "|")

    /// Matches "twenty-five" / "twenty five". Case-insensitive, word-bounded.
    /// Runs first so the leading "twenty" isn't rewritten to "20" before the
    /// compound is recognised.
    private static let compoundRegex: NSRegularExpression? = {
        let pattern = "\\b(\(tensAlternation))[\\s-](\(onesAlternation))\\b"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Matches standalone tens/teens.
    private static let standaloneRegex: NSRegularExpression? = {
        let pattern = "\\b(\(tensAlternation))\\b"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// "X hundred" → 100..900 ("one hundred", "five hundred").
    private static let hundredRegex: NSRegularExpression? = {
        let pattern = "\\b(\(onesAlternation))\\s+hundred\\b"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// "X oh Y" → 101..909 in the "X0Y" interpretation fitness
    /// instructors use ("one oh five" → 105, "two oh seven" → 207).
    private static let ohRegex: NSRegularExpression? = {
        let pattern = "\\b(\(onesAlternation))\\s+oh\\s+(\(onesAlternation))\\b"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Returns `text` with normalised cardinals. Idempotent — running on
    /// already-normalised text returns the same string.
    ///
    /// Pass order matters: the longer, more specific patterns ("one oh five",
    /// "one hundred", "twenty-five") run before the single-tens pass, so the
    /// shared "twenty" / "one" component words aren't consumed early.
    public static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        result = applyOhPass(result)
        result = applyHundredPass(result)
        result = applyCompoundPass(result)
        result = applyStandalonePass(result)
        return result
    }

    private static func applyCompoundPass(_ text: String) -> String {
        guard let regex = compoundRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // Replace from the end so earlier match ranges stay valid.
        var out = text
        for match in matches.reversed() {
            let tensWord = (out as NSString).substring(with: match.range(at: 1)).lowercased()
            let onesWord = (out as NSString).substring(with: match.range(at: 2)).lowercased()
            guard let t = tensMap[tensWord], let o = onesMap[onesWord] else { continue }
            out = (out as NSString).replacingCharacters(in: match.range, with: String(t + o))
        }
        return out
    }

    private static func applyHundredPass(_ text: String) -> String {
        guard let regex = hundredRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let word = (out as NSString).substring(with: match.range(at: 1)).lowercased()
            guard let value = onesMap[word] else { continue }
            out = (out as NSString).replacingCharacters(in: match.range, with: String(value * 100))
        }
        return out
    }

    private static func applyOhPass(_ text: String) -> String {
        guard let regex = ohRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let tensWord = (out as NSString).substring(with: match.range(at: 1)).lowercased()
            let onesWord = (out as NSString).substring(with: match.range(at: 2)).lowercased()
            guard let t = onesMap[tensWord], let o = onesMap[onesWord] else { continue }
            // "one oh five" → 1*100 + 0*10 + 5 = 105.
            let value = t * 100 + o
            out = (out as NSString).replacingCharacters(in: match.range, with: String(value))
        }
        return out
    }

    private static func applyStandalonePass(_ text: String) -> String {
        guard let regex = standaloneRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let word = (out as NSString).substring(with: match.range(at: 1)).lowercased()
            guard let value = tensMap[word] else { continue }
            out = (out as NSString).replacingCharacters(in: match.range, with: String(value))
        }
        return out
    }
}
