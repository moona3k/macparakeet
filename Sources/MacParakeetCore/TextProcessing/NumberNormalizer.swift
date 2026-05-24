import Foundation

/// Rule-based conversion of unambiguous spelled-out English cardinal
/// numbers to their digit form (e.g., `twenty-five` -> `25`,
/// `four minutes` -> `4 minutes`, `three, two, one` -> `3, 2, 1`).
///
/// Scope:
///   - teens (`ten`..`nineteen`),
///   - tens (`twenty`..`ninety`),
///   - hyphenated and space-separated tens+ones compounds
///     (`twenty-five`, `forty three`),
///   - hundred-cardinals (`one hundred`..`nine hundred` -> `100`..`900`),
///   - the "X oh Y" form fitness instructors use for 101–109, 201–209,
///     etc. (`one oh five` -> `105`),
///   - 1-9 + measurement unit (`four minutes` -> `4 minutes`,
///     `four-minute warm-up` -> `4-minute warm-up`),
///   - spelled countdown sequences (`three, two, one` -> `3, 2, 1`,
///     `three, two, and one` -> `3, 2, and 1`).
///
/// **Direction: spelled → digit, throughout.** The whole pipeline
/// normalizes to digits because the speech engine (Whisper/Parakeet)
/// emits inconsistent forms — sometimes spelled, sometimes digit —
/// and the previous SRT had digit-form precedent that users want
/// matched (SRT 35 feedback was about INCONSISTENCY, not
/// direction). Bare 1-9 digits without a measurement unit or
/// countdown context stay untouched (level numbers, version
/// numbers, cadence increments like "adding 5" all read fine as
/// digits and shouldn't get spelled).
public enum NumberNormalizer: Sendable {

    /// Words that map to a tens (or teen) value on their own.
    private static let tensMap: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    /// Single-digit ones used as trailing half of a compound
    /// (`twenty-FIVE`) and standalone in measurement / countdown
    /// contexts.
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

    /// Measurement units that follow a cardinal in transcribed speech.
    /// Used by `applyMeasurementPass` to disambiguate when a bare
    /// `1-9` should be converted to a digit. Without a known unit
    /// immediately after, the cardinal may be a pronoun ("two of
    /// them"), a quantifier ("five fingers"), or other context where
    /// digit form would read wrong.
    private static let measurementUnits = [
        "minute", "minutes", "second", "seconds", "hour", "hours",
        "day", "days", "week", "weeks", "month", "months",
        "year", "years",
        "pound", "pounds", "ounce", "ounces", "gram", "grams",
        "foot", "feet", "inch", "inches",
        "mile", "miles", "meter", "meters", "yard", "yards",
        "step", "steps", "rep", "reps", "count", "counts",
        "set", "sets", "round", "rounds",
        "degree", "degrees"
    ]
    private static let measurementAlternation = measurementUnits.joined(separator: "|")

    /// `<ones> <unit>` or `<ones>-<unit>` → `<digit> <unit>` /
    /// `<digit>-<unit>`. Captures the cardinal in group 1, the
    /// literal separator in group 2, and the unit in group 3 so the
    /// rewrite preserves the original spacing/hyphenation.
    private static let measurementRegex: NSRegularExpression? = {
        let pattern = "\\b(\(onesAlternation))([- ])(\(measurementAlternation))\\b"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Matches a sequence of 2+ spelled-out cardinals separated by
    /// commas (with optional `and` before the last). Catches the
    /// countdown patterns like "three, two, one", "three, two, and
    /// one", "five, four". The `+` quantifier requires at least one
    /// `, <word>` after the first, so a SINGLE spelled cardinal
    /// stays alone — important for "one of them", "two ways to go",
    /// etc. where digit conversion would be wrong.
    private static let spelledCountdownRegex: NSRegularExpression? = {
        let pattern = "\\b(\(onesAlternation))\\b(\\s*,\\s*(and\\s+)?\\b(\(onesAlternation))\\b)+"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Returns `text` with normalised cardinals. Idempotent — running on
    /// already-normalised text returns the same string.
    ///
    /// Pass order matters: the longer, more specific patterns ("one oh
    /// five", "one hundred", "twenty-five") run before the single-tens
    /// pass so the shared "twenty" / "one" component words aren't
    /// consumed early. The measurement and countdown passes run last
    /// because they handle 1-9 cardinals that the upstream passes
    /// intentionally leave alone.
    public static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        result = applyOhPass(result)
        result = applyHundredPass(result)
        result = applyCompoundPass(result)
        result = applyStandalonePass(result)
        result = applyMeasurementPass(result)
        result = applySpelledCountdownPass(result)
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

    /// Spelled 1-9 + measurement unit → digit + unit.
    /// `four minutes` → `4 minutes`, `four-minute warm-up` →
    /// `4-minute warm-up`. Skips bare standalone 1-9 (those would
    /// be pronouns / quantifiers / counts the measurement context
    /// disambiguates against).
    private static func applyMeasurementPass(_ text: String) -> String {
        guard let regex = measurementRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let onesWord = (out as NSString).substring(with: match.range(at: 1)).lowercased()
            let separator = (out as NSString).substring(with: match.range(at: 2))
            let unit = (out as NSString).substring(with: match.range(at: 3))
            guard let value = onesMap[onesWord] else { continue }
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: "\(value)\(separator)\(unit)"
            )
        }
        return out
    }

    /// Spelled countdown sequence → digit sequence. `three, two,
    /// one` → `3, 2, 1`. The outer regex requires at least 2
    /// cardinals separated by commas, so a single spelled cardinal
    /// stays alone (preserves "one of them" / "two ways to go" /
    /// "five fingers" — those aren't countdowns).
    ///
    /// Walks each match's spelled-word substring via a tiny inner
    /// regex so the commas / whitespace / optional "and" between
    /// cardinals stay exactly as in the input — only the cardinal
    /// words themselves get rewritten.
    private static func applySpelledCountdownPass(_ text: String) -> String {
        guard let outerRegex = spelledCountdownRegex,
              let innerRegex = try? NSRegularExpression(
                pattern: "\\b(\(onesAlternation))\\b",
                options: [.caseInsensitive]
              ) else {
            return text
        }
        let ns = text as NSString
        let matches = outerRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let matchText = (out as NSString).substring(with: match.range)
            let innerNS = matchText as NSString
            let innerMatches = innerRegex.matches(
                in: matchText,
                range: NSRange(location: 0, length: innerNS.length)
            )
            var rewritten = matchText
            for inner in innerMatches.reversed() {
                let word = (rewritten as NSString).substring(with: inner.range).lowercased()
                guard let value = onesMap[word] else { continue }
                rewritten = (rewritten as NSString).replacingCharacters(
                    in: inner.range, with: String(value)
                )
            }
            out = (out as NSString).replacingCharacters(in: match.range, with: rewritten)
        }
        return out
    }
}
