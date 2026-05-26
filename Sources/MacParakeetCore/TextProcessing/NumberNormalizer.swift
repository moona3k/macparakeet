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
        "degree", "degrees",
        // Iteration / repetition terms — "two times", "one more
        // time", "three rounds" are quantities in fitness context.
        "time", "times",
        // Exercise-specific counts — "one push", "five jumps",
        // "one more jog", "three blocks of work".
        "push", "pushes", "jump", "jumps",
        "jog", "jogs", "block", "blocks", "build", "builds",
        "interval", "intervals",
        // Sentence-counter nouns — "three questions to ask you",
        // "two points to make".
        "question", "questions", "point", "points",
        "thing", "things", "way", "ways"
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

    /// `<ones> more|fewer|less|extra|additional <unit>` →
    /// `<digit> <modifier> <unit>`. Catches "two more minutes",
    /// "one more time", "three more reps" — phrasings where a
    /// modifier word sits between the cardinal and the unit. The
    /// allowed modifier set is intentionally narrow so we don't
    /// match "two of those" or "two great minutes".
    private static let measurementWithModifierRegex: NSRegularExpression? = {
        let modifiers = "more|fewer|less|extra|additional"
        let pattern = "\\b(\(onesAlternation))\\s+(\(modifiers))\\s+(\(measurementAlternation))\\b"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Trailing spelled-countdown pattern: "...in three," / "...in
    /// three." / "...in three" at end of string → "in 3," / "in 3."
    /// / "in 3". Mirror of the digit-form pattern, kept here so the
    /// cross-cue countdown leak gets the spelled side too. Trigger
    /// words anchor it.
    private static let spelledTrailingCountdownRegex: NSRegularExpression? = {
        let pattern = "\\b(in|at|after)\\s+(\(onesAlternation))\\b(?=\\s*[,.]|\\s*$)"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// "Bare spelled cardinal at cue end" — only fires when the cue
    /// ALSO contains a digit cardinal somewhere, which is the
    /// telltale sign of a mid-countdown text fragment. Catches the
    /// cross-cue leak where Whisper emits "Up 1, 2, down one, two."
    /// and the cue split orphans a single spelled cardinal at end:
    ///   cue N:   "Up 1, 2, down one,"     ← "1, 2" + spelled "one,"
    ///   cue N+1: "two."
    /// The has-digit guard prevents firing on pure-spelled cues
    /// where conversion would be wrong: "the next one." has no
    /// digit, stays as "the next one.".
    private static let bareSpelledAtCueEndRegex: NSRegularExpression? = {
        let pattern = "\\b(\(onesAlternation))\\b(\\s*[,.]?)\\s*$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()
    private static let hasDigitOneToNineRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\b[1-9]\\b")
    }()

    /// Standalone-cardinal-only cue, no other text: "two.", "one,",
    /// "five" alone. These are countdown remnants that got their
    /// own cue and have no surrounding context to disambiguate.
    /// Fire unconditionally — single-cardinal cues are almost
    /// always countdown tails in this domain (fitness instruction).
    private static let standaloneCardinalCueRegex: NSRegularExpression? = {
        let pattern = "^\\s*(\(onesAlternation))(\\s*[,.]?)\\s*$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// "X and a half" / "X and one half" — fraction phrasing for
    /// measurements. Catches "after two and a half minutes" without
    /// disturbing the "and a half" idiom.
    private static let cardinalAndAHalfRegex: NSRegularExpression? = {
        let pattern = "\\b(\(onesAlternation))\\s+and\\s+(?:a|one)\\s+half\\b"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// `your <X>` / `about <X>` at the end of a cue → digit. Catches
    /// the cross-cue measurement leak where a cue ends mid-phrase
    /// with a possessive or approximator + cardinal, and the unit
    /// is in the next cue ("because your four" + "minute warm-up").
    /// Narrow trigger list — "first/last/next" deliberately omitted
    /// because those are ordinal pronouns ("First one", "Last one",
    /// "next one") where conversion would read wrong.
    private static let determinerCardinalAtEndRegex: NSRegularExpression? = {
        let pattern = "\\b(your|about)\\s+(\(onesAlternation))\\b(?=\\s*[,.]|\\s*$)"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// `<action-verb> [it|that] <X>` at cue end → digit. Catches
    /// cross-cue measurement leaks like "back and do two" / "we
    /// do it two" where the unit ("rounds", "times") is in the
    /// next cue. Narrow verb list — only verbs that typically
    /// take a count object.
    private static let verbCardinalAtEndRegex: NSRegularExpression? = {
        let verbs = "do|did|does|have|had|got|take|took|give|gave|make|made"
        let pattern = "\\b(\(verbs))\\s+(?:(?:it|that)\\s+)?(\(onesAlternation))\\b(?=\\s*[,.]|\\s*$)"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// `<ones> <body-part> <unit>` → digit. Catches the common
    /// fitness phrasing "two arm blocks", "one leg segment", "three
    /// arm intervals". Body-part word sits between cardinal and
    /// unit, so the plain measurement regex misses it.
    private static let cardinalBodyPartUnitRegex: NSRegularExpression? = {
        let bodyParts = "arm|leg|body|core|knee|elbow|shoulder"
        let pattern = "\\b(\(onesAlternation))\\s+(\(bodyParts))\\s+(\(measurementAlternation))\\b"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Reverse pattern: `<unit-word> <ones>` → `<unit-word>
    /// <digit>`. Catches the unit-BEFORE-cardinal phrasing used for
    /// ordered counters and questions: "round one" / "number six" /
    /// "set three". Conventional digit form ("Round 1", "Question
    /// 3", "Set 5") is already the precedent for these.
    private static let unitBeforeCardinalRegex: NSRegularExpression? = {
        // Trigger words that conventionally take a digit counter
        // after them. Narrower than the full measurementUnits list
        // to avoid false positives like "minute one of the class"
        // (which would convert "minute one" wrong).
        let counters = "round|rounds|number|set|sets|question|questions|level|chapter|round\\s+number"
        let pattern = "\\b(\(counters))\\s+(\(onesAlternation))\\b"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Matches a sequence of 2+ cardinal tokens (spelled OR digit
    /// 1-9) separated by commas OR plain whitespace, with optional
    /// `and` before the last. Catches countdown patterns in any
    /// surface form Whisper emits — "three, two, one" / "3, 2, 1"
    /// / "Up 1, 2, down one, two" / "in 2, and one." The inner
    /// replacement step only converts SPELLED tokens; digit tokens
    /// in the match stay as digits (no change). The `+` quantifier
    /// requires at least one follow-up cardinal, so a single bare
    /// spelled cardinal stays alone — preserves "one of them",
    /// "two ways to go" where digit conversion would read wrong.
    private static let spelledCountdownRegex: NSRegularExpression? = {
        let cardinal = "(?:[1-9]|\(onesAlternation))"
        let pattern = "\\b\(cardinal)\\b(?:(?:\\s*,\\s*|\\s+)(?:and\\s+)?\\b\(cardinal)\\b)+"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Period-separated countdown at cue start. Catches Whisper output
    /// like "Four. Three. Two." where the instructor's pauses between
    /// numbers became sentence boundaries. Anchored at cue start to
    /// avoid converting mid-prose cardinals ("I have four. Three of
    /// them are nice." should NOT convert).
    private static let periodCountdownAtCueStartRegex: NSRegularExpression? = {
        let cardinal = "(?:[1-9]|\(onesAlternation))"
        let pattern = "^\\s*\\b\(cardinal)\\b(?:\\s*\\.\\s*\\b\(cardinal)\\b)+"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Trigger words that introduce a cadence increment: "add five",
    /// "plus five", "by five", "of five". Whisper emits these
    /// frequently in fitness instruction; user wants them as digits
    /// for consistency with the digit-form increments already in the
    /// SRT ("adding 5", "plus 5", "by 5").
    private static let incrementTriggerRegex: NSRegularExpression? = {
        let pattern = "\\b(add|adding|added|plus|by|of)\\s+(\(onesAlternation))\\b"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Matches spelled ones in number-range contexts: "one to two",
    /// "five to nine", "one to two to the right". Just the two-
    /// cardinal range — both digits convert. Requires the literal
    /// word "to" between two ones-cardinals.
    private static let spelledRangeRegex: NSRegularExpression? = {
        let pattern = "\\b(\(onesAlternation))\\s+to\\s+(\(onesAlternation))\\b"
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
        result = applyMeasurementWithModifierPass(result)
        result = applyIncrementTriggerPass(result)
        result = applySpelledRangePass(result)
        result = applySpelledTrailingCountdownPass(result)
        result = applySpelledCountdownPass(result)
        result = applyPeriodCountdownAtCueStartPass(result)
        result = applyBareSpelledAtCueEndPass(result)
        result = applyStandaloneCardinalCuePass(result)
        result = applyCardinalAndAHalfPass(result)
        result = applyDeterminerCardinalAtEndPass(result)
        result = applyVerbCardinalAtEndPass(result)
        result = applyCardinalBodyPartUnitPass(result)
        result = applyUnitBeforeCardinalPass(result)
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

    /// `<ones> <modifier> <unit>` → digit. Captures the cardinal
    /// in group 1, modifier in group 2, unit in group 3 so the
    /// modifier ("more" / "fewer" / etc.) and unit are preserved.
    private static func applyMeasurementWithModifierPass(_ text: String) -> String {
        guard let regex = measurementWithModifierRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let onesWord = (out as NSString).substring(with: match.range(at: 1)).lowercased()
            let modifier = (out as NSString).substring(with: match.range(at: 2))
            let unit = (out as NSString).substring(with: match.range(at: 3))
            guard let value = onesMap[onesWord] else { continue }
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: "\(value) \(modifier) \(unit)"
            )
        }
        return out
    }

    /// Increment trigger pass: `add five` → `add 5`, `of five` →
    /// `of 5`, etc. Whisper sometimes emits cadence increments
    /// spelled out even when other increments in the same SRT are
    /// digits. Trigger word disambiguates from quantifier contexts
    /// ("have five drinks" — "have" not in trigger list, no match).
    private static func applyIncrementTriggerPass(_ text: String) -> String {
        guard let regex = incrementTriggerRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let trigger = (out as NSString).substring(with: match.range(at: 1))
            let word = (out as NSString).substring(with: match.range(at: 2)).lowercased()
            guard let value = onesMap[word] else { continue }
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: "\(trigger) \(value)"
            )
        }
        return out
    }

    /// Trailing spelled-countdown pass: `...in three,` → `...in 3,`.
    /// Mirror of the digit-form trailing pass — catches the
    /// cross-cue countdown leak where one cue ends with a single
    /// spelled cardinal preceded by an instructional trigger word
    /// ("in", "at", "after") and the rest of the countdown is in
    /// the next cue. Trigger word disambiguates from bare
    /// quantifiers like "one of them" / "two ways".
    private static func applySpelledTrailingCountdownPass(_ text: String) -> String {
        guard let regex = spelledTrailingCountdownRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let trigger = (out as NSString).substring(with: match.range(at: 1))
            let word = (out as NSString).substring(with: match.range(at: 2)).lowercased()
            guard let value = onesMap[word] else { continue }
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: "\(trigger) \(value)"
            )
        }
        return out
    }

    /// Bare-spelled-at-cue-end pass. Only fires when the cue text
    /// already contains a digit cardinal somewhere — that's the
    /// telltale sign this single trailing spelled cardinal is the
    /// orphaned tail of a cross-cue countdown. Preserves pure-text
    /// cues like "the next one." (no digit, no conversion).
    private static func applyBareSpelledAtCueEndPass(_ text: String) -> String {
        guard let regex = bareSpelledAtCueEndRegex,
              let digitGuard = hasDigitOneToNineRegex else { return text }
        let ns = text as NSString
        // Has-digit guard: if no `\b[1-9]\b` anywhere in the cue,
        // don't risk converting an in-prose "one" / "two" that
        // would read wrong.
        guard digitGuard.firstMatch(
            in: text, range: NSRange(location: 0, length: ns.length)
        ) != nil else { return text }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let word = (out as NSString).substring(with: match.range(at: 1)).lowercased()
            let trailing = (out as NSString).substring(with: match.range(at: 2))
            guard let value = onesMap[word] else { continue }
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: "\(value)\(trailing)"
            )
        }
        return out
    }

    /// Standalone-cardinal-only cue pass. Cues whose ENTIRE text
    /// is just a spelled cardinal + optional punctuation are
    /// almost always countdown tails in fitness instruction — they
    /// got their own cue from the layout planner because of a
    /// pause boundary. Convert unconditionally.
    private static func applyStandaloneCardinalCuePass(_ text: String) -> String {
        guard let regex = standaloneCardinalCueRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let word = (out as NSString).substring(with: match.range(at: 1)).lowercased()
            let trailing = (out as NSString).substring(with: match.range(at: 2))
            guard let value = onesMap[word] else { continue }
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: "\(value)\(trailing)"
            )
        }
        return out
    }

    /// `<cardinal> and a half` → digit + " and a half". Just the
    /// cardinal converts; "and a half" stays as natural prose
    /// (`2 and a half minutes` reads natural; `2.5 minutes` would
    /// be more aggressive than warranted).
    private static func applyCardinalAndAHalfPass(_ text: String) -> String {
        guard let regex = cardinalAndAHalfRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let word = (out as NSString).substring(with: match.range(at: 1)).lowercased()
            guard let value = onesMap[word] else { continue }
            // Re-render with "a" since the regex captures both "a"
            // and "one"; we normalize to "a" for cleaner reading.
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: "\(value) and a half"
            )
        }
        return out
    }

    /// `your <X>` / `about <X>` at cue end → digit. Catches the
    /// cross-cue measurement leak where the unit lives in the next
    /// cue.
    private static func applyDeterminerCardinalAtEndPass(_ text: String) -> String {
        guard let regex = determinerCardinalAtEndRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let trigger = (out as NSString).substring(with: match.range(at: 1))
            let word = (out as NSString).substring(with: match.range(at: 2)).lowercased()
            guard let value = onesMap[word] else { continue }
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: "\(trigger) \(value)"
            )
        }
        return out
    }

    /// `<verb> [it|that] <X>` at cue end → digit. Catches cross-
    /// cue measurement leaks where verb takes a count object and
    /// the unit is in the next cue. Has-digit guard: only fires
    /// when the cue already contains a `\b[1-9]\b` digit cardinal
    /// somewhere — that's the telltale sign this trailing spelled
    /// cardinal is the orphaned tail of a cross-cue countdown vs.
    /// a general-prose "have four" / "make two" / "took three".
    private static func applyVerbCardinalAtEndPass(_ text: String) -> String {
        guard let regex = verbCardinalAtEndRegex,
              let digitGuard = hasDigitOneToNineRegex else { return text }
        let ns = text as NSString
        guard digitGuard.firstMatch(
            in: text, range: NSRange(location: 0, length: ns.length)
        ) != nil else { return text }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let matchText = (out as NSString).substring(with: match.range)
            let word = (out as NSString).substring(with: match.range(at: 2)).lowercased()
            guard let value = onesMap[word] else { continue }
            // Rebuild the matched text with digit substituted for
            // the cardinal. Capture group 2 = the cardinal; replace
            // only that.
            let cardinalRange = match.range(at: 2)
            let prefixLen = cardinalRange.location - match.range.location
            let prefix = (matchText as NSString).substring(to: prefixLen)
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: "\(prefix)\(value)"
            )
        }
        return out
    }

    /// `<ones> <body-part> <unit>` → digit. "two arm blocks" →
    /// "2 arm blocks".
    private static func applyCardinalBodyPartUnitPass(_ text: String) -> String {
        guard let regex = cardinalBodyPartUnitRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let onesWord = (out as NSString).substring(with: match.range(at: 1)).lowercased()
            let bodyPart = (out as NSString).substring(with: match.range(at: 2))
            let unit = (out as NSString).substring(with: match.range(at: 3))
            guard let value = onesMap[onesWord] else { continue }
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: "\(value) \(bodyPart) \(unit)"
            )
        }
        return out
    }

    /// `round one` / `number six` / `set three` → digit. Reverse
    /// of measurement pass: counter word BEFORE cardinal.
    private static func applyUnitBeforeCardinalPass(_ text: String) -> String {
        guard let regex = unitBeforeCardinalRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let counter = (out as NSString).substring(with: match.range(at: 1))
            let word = (out as NSString).substring(with: match.range(at: 2)).lowercased()
            guard let value = onesMap[word] else { continue }
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: "\(counter) \(value)"
            )
        }
        return out
    }

    /// Spelled range → digit range. `one to two` → `1 to 2`,
    /// `five to nine` → `5 to 9`. Runs before the countdown pass
    /// because `one to two` would otherwise look like a countdown
    /// sequence (`one`, `two` with space separator); the range
    /// rewrite is correct in both readings, but firing this pass
    /// first avoids the countdown regex catching it.
    private static func applySpelledRangePass(_ text: String) -> String {
        guard let regex = spelledRangeRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = text
        for match in matches.reversed() {
            let left = (out as NSString).substring(with: match.range(at: 1)).lowercased()
            let right = (out as NSString).substring(with: match.range(at: 2)).lowercased()
            guard let l = onesMap[left], let r = onesMap[right] else { continue }
            out = (out as NSString).replacingCharacters(
                in: match.range,
                with: "\(l) to \(r)"
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

    /// Period-separated countdown pass. Mirrors `applySpelledCountdownPass`
    /// but matches `Four. Three. Two.` instead of `Four, Three, Two,`.
    /// Anchored at cue start (no mid-prose false positives).
    private static func applyPeriodCountdownAtCueStartPass(_ text: String) -> String {
        guard let outerRegex = periodCountdownAtCueStartRegex,
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
