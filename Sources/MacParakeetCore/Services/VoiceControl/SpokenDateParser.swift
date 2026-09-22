import Foundation

/// Deterministic parser for dates as people say them to Voice Control.
///
/// Absolute forms are delegated to `NSDataDetector`; a small pre-pass covers the
/// relative forms the detector misses or resolves inconsistently. Every result is
/// truncated to the start of its day in `calendar`.
///
/// Weekday semantics: a bare weekday ("Friday"), "this Friday", and "next Friday"
/// all resolve to the next occurrence strictly after `today`. Distinguishing
/// "this" from "next" is ambiguous in everyday speech, so it is deliberately not
/// attempted.
public enum SpokenDateParser {
    private static let monthNames = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]
    private static let weekdayNames = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    ]

    /// First calendar date mentioned in `text`, resolved relative to `today` in `calendar`.
    /// Handles absolute forms ("September 20 2026", "20 Sep", "2026-09-20", "9/20/2026") and relative
    /// forms ("today", "tomorrow", "next Friday", "this Friday", "Friday", "in 3 days", "the 20th").
    /// A missing year is the current year, or next year if that date is more than 60 days in the past.
    public static func firstDate(in text: String, today: Date = Date(), calendar: Calendar = .current) -> Date? {
        let todayStart = calendar.startOfDay(for: today)
        if let relative = relativeDate(in: text, today: todayStart, calendar: calendar) { return relative }
        return detectedDate(in: text, today: todayStart, calendar: calendar)
    }

    /// "2026-09-20 (in 25 days)" | "2026-09-20 (today)" | "2026-09-20 (3 days ago)"
    public static func describe(_ date: Date, today: Date = Date(), calendar: Calendar = .current) -> String {
        let days =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: date)
            ).day ?? 0
        let relative: String
        switch days {
        case 0: relative = "today"
        case 1: relative = "in 1 day"
        case -1: relative = "1 day ago"
        case let d where d > 0: relative = "in \(d) days"
        case let d: relative = "\(-d) days ago"
        }
        return "\(iso(date, calendar: calendar)) (\(relative))"
    }

    /// ISO yyyy-MM-dd in `calendar`'s time zone.
    public static func iso(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Relative pre-pass

    private static func relativeDate(in text: String, today: Date, calendar: Calendar) -> Date? {
        let lower = text.lowercased()
        let words = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if words.contains("today") { return today }
        if words.contains("tomorrow") { return calendar.date(byAdding: .day, value: 1, to: today) }
        if words.contains("yesterday") { return calendar.date(byAdding: .day, value: -1, to: today) }
        if let days = firstCapture(#"\bin (\d{1,3}) days?\b"#, in: lower).flatMap({ Int($0) }) {
            return calendar.date(byAdding: .day, value: days, to: today)
        }
        let mentionsMonth = !words.isDisjoint(with: monthNames)
        let hasDigits = lower.contains { $0.isNumber }
        if !mentionsMonth, let day = firstCapture(#"\bthe (\d{1,2})(?:st|nd|rd|th)\b"#, in: lower).flatMap({ Int($0) }),
            (1...31).contains(day)
        {
            let currentDay = calendar.component(.day, from: today)
            var components = calendar.dateComponents([.year, .month], from: today)
            components.day = day
            if day < currentDay { components.month = (components.month ?? 1) + 1 }
            return calendar.date(from: components)
        }
        if !mentionsMonth, !hasDigits,
            let index = weekdayNames.firstIndex(where: { words.contains($0) })
        {
            let current = calendar.component(.weekday, from: today)  // 1 = Sunday
            var delta = (index + 1 - current + 7) % 7
            if delta == 0 { delta = 7 }
            return calendar.date(byAdding: .day, value: delta, to: today)
        }
        return nil
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    // MARK: - Absolute forms via NSDataDetector

    private static func detectedDate(in text: String, today: Date, calendar: Calendar) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        guard let match = matches.first(where: { $0.date != nil }), let detected = match.date,
            let matchRange = Range(match.range, in: text)
        else { return nil }
        // The detector reports instants in the system time zone; read the civil date back in that zone.
        var systemCalendar = calendar
        systemCalendar.timeZone = match.timeZone ?? .current
        var parts = systemCalendar.dateComponents([.year, .month, .day], from: detected)
        let matchedText = String(text[matchRange])
        let hasExplicitYear = matchedText.range(of: #"\b\d{4}\b"#, options: .regularExpression) != nil
        if !hasExplicitYear {
            let currentYear = calendar.component(.year, from: today)
            parts.year = currentYear
            if let candidate = calendar.date(from: parts),
                let daysAgo = calendar.dateComponents([.day], from: candidate, to: today).day, daysAgo > 60
            {
                parts.year = currentYear + 1
            }
        }
        guard let date = calendar.date(from: parts) else { return nil }
        return calendar.startOfDay(for: date)
    }
}
