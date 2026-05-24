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
///
/// **Reverse pass for upstream-emitted digits.** Parakeet's native
/// output sometimes emits "4 minutes" / "3 minutes" directly even
/// when the speaker said the spelled form. SRT 36 feedback flagged
/// these as still reading strange. `applyDigitToSpelledPass` runs
/// at the end of `normalize`: it matches single-digit cardinal +
/// (space or hyphen) + measurement unit, replaces the digit with
/// its spelled form. `[1-9]` only — 10+ stays as digits per the
/// same editorial rule.
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

    /// Measurement units that follow a cardinal in transcribed speech.
    /// Used only by `applyDigitToSpelledPass` to disambiguate when
    /// a bare `1-9` digit should be spelled out — without a known
    /// unit immediately after, the digit may be a level / version /
    /// score and shouldn't be touched. Plural forms are included
    /// literally rather than via `s?` so the alternation stays
    /// explicit and easy to grep for.
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

    /// Spelled forms of digits 1-9 for the reverse pass.
    private static let digitToWord: [String: String] = [
        "1": "one", "2": "two", "3": "three", "4": "four", "5": "five",
        "6": "six", "7": "seven", "8": "eight", "9": "nine"
    ]

    /// Matches a single-digit cardinal `[1-9]` followed by space or
    /// hyphen and a measurement unit. The leading `\b` + restricted
    /// `[1-9]` (not `[0-9]+`) means "44 minutes" doesn't match —
    /// only a STANDALONE single digit.
    private static let digitMeasurementRegex: NSRegularExpression? = {
        let pattern = "\\b([1-9])([- ])(\(measurementAlternation))\\b"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Matches a sequence of two or more single-digit cardinals
    /// separated by commas (with optional `and` before the last).
    /// Catches countdown patterns like "3, 2, 1", "3, 2, and 1",
    /// "5, 4", "5, 4, 3, 2, 1" — which `digitMeasurementRegex`
    /// misses because countdowns aren't followed by a measurement
    /// unit. A single digit alone DOESN'T match (the `+` quantifier
    /// requires at least one additional `, N` group), so cadence
    /// callouts ("85"), levels ("level 4"), and times ("4 PM") stay
    /// as digits.
    private static let digitCountdownRegex: NSRegularExpression? = {
        let pattern = "\\b[1-9]\\b(\\s*,\\s*(and\\s+)?\\b[1-9]\\b)+"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Matches a SINGLE bare digit cardinal preceded by an instructional
    /// trigger word (`in`, `at`, `after`) and followed by a comma,
    /// period, or end of string. Catches the cross-cue countdown
    /// leak where a sentence like "...in 3, 2, 1, let's go" gets
    /// SPLIT by the cue-builder into:
    ///   cue N:   "...in 3,"
    ///   cue N+1: "2, 1, let's go."
    /// The sequence regex catches "2, 1" in cue N+1 but the lone
    /// "3," at the end of cue N has no second digit to anchor a
    /// countdown match. Trigger-word context disambiguates: "in 3,"
    /// almost always means a countdown starter, while bare "3,"
    /// could be many things. We deliberately don't include "in 3
    /// minutes" (no comma after the digit) so the measurement pass
    /// still owns that case.
    private static let digitTrailingCountdownRegex: NSRegularExpression? = {
        // Capture group 1 = trigger word, group 2 = digit.
        // Negative lookahead `(?=\s*[,.]|\s*$)` keeps the trailing
        // punctuation out of the match so the replacement can swap
        // the digit cleanly without re-emitting the comma/period.
        let pattern = "\\b(in|at|after)\\s+([1-9])\\b(?=\\s*[,.]|\\s*$)"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Returns `text` with normalised cardinals. Idempotent — running on
    /// already-normalised text returns the same string.
    ///
    /// Pass order matters: the longer, more specific patterns ("one oh five",
    /// "one hundred", "twenty-five") run before the single-tens pass, so the
    /// shared "twenty" / "one" component words aren't consumed early. The
    /// digit-to-spelled pass runs LAST so any spelled→digit conversion
    /// upstream of it has already happened (the digit→spelled rule only
    /// fires on 1-9, which the upstream passes never touch anyway).
    public static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        result = applyOhPass(result)
        result = applyHundredPass(result)
        result = applyCompoundPass(result)
        result = applyStandalonePass(result)
        result = applyDigitToSpelledPass(result)
        result = applyCountdownToSpelledPass(result)
        result = applyTrailingCountdownToSpelledPass(result)
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

    /// Reverse pass: `4 minutes` / `4-minute` → `four minutes` /
    /// `four-minute`. Catches digits Parakeet emits natively that the
    /// upstream spelled→digit passes wouldn't touch (those only run
    /// on spelled cardinals). Bounded to 1-9 so 10+ stays digit per
    /// AP / Chicago style. Preserves the original separator (space
    /// vs hyphen) and the unit's original case.
    private static func applyDigitToSpelledPass(_ text: String) -> String {
        guard let regex = digitMeasurementRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let digit = (out as NSString).substring(with: match.range(at: 1))
            let separator = (out as NSString).substring(with: match.range(at: 2))
            let unit = (out as NSString).substring(with: match.range(at: 3))
            guard let word = digitToWord[digit] else { continue }
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: "\(word)\(separator)\(unit)"
            )
        }
        return out
    }

    /// Trailing-countdown pass: `...in 3,` → `...in three,`.
    /// Catches the cross-cue leak where a sentence "in 3, 2, 1,
    /// let's go" gets split by the cue-builder so one cue ends
    /// with just "in 3," and the next starts with "2, 1, let's
    /// go." — the sequence pass catches "2, 1" in the second cue
    /// but the lone "3," in the first cue had no second digit to
    /// anchor a countdown. The trigger word ("in", "at", "after")
    /// disambiguates from bare digits like "level 4" or "scored a 5".
    private static func applyTrailingCountdownToSpelledPass(_ text: String) -> String {
        guard let regex = digitTrailingCountdownRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let trigger = (out as NSString).substring(with: match.range(at: 1))
            let digit = (out as NSString).substring(with: match.range(at: 2))
            guard let word = digitToWord[digit] else { continue }
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: "\(trigger) \(word)"
            )
        }
        return out
    }

    /// Sequence pass: `3, 2, 1` / `3, 2, and 1` / `5, 4, 3, 2, 1`
    /// → spelled equivalents. Whisper / Parakeet sometimes emits
    /// countdown phrases as digits even when the speaker said
    /// "three, two, one" — and those don't trigger the measurement
    /// pass because there's no unit after the digit. SRT 37
    /// regression showed "in 3, 2, 1, recover" / "in 3, 2, and 1."
    /// patterns scattered through the export.
    ///
    /// Walks each match's bare-digit substring via a tiny inner
    /// regex so the comma/whitespace/"and" punctuation stays
    /// exactly as it was in the input. Single digits alone never
    /// match (the outer regex requires `+` repetition), so cadence
    /// callouts like `85` and bare levels like `4` stay as digits.
    private static func applyCountdownToSpelledPass(_ text: String) -> String {
        guard let outerRegex = digitCountdownRegex,
              let innerRegex = try? NSRegularExpression(pattern: "\\b[1-9]\\b") else {
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
                let digit = (rewritten as NSString).substring(with: inner.range)
                guard let word = digitToWord[digit] else { continue }
                rewritten = (rewritten as NSString).replacingCharacters(
                    in: inner.range, with: word
                )
            }
            out = (out as NSString).replacingCharacters(in: match.range, with: rewritten)
        }
        return out
    }
}
