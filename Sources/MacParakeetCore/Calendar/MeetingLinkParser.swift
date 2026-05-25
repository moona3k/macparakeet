import Foundation

/// Extracts video-conferencing URLs from calendar event fields.
///
/// Ported verbatim from Oatmeal — both projects share the same heuristic.
/// Order-of-precedence is Zoom → Meet → Teams → Webex → Around → generic so
/// the most specific pattern wins when multiple URLs appear in event notes.
public struct MeetingLinkParser: Sendable {
    public init() {}

    // Zoom: join (`/j/`), webinar (`/w/`), and personal-room (`/my/`) links,
    // on both zoom.us and the government tenant zoomgov.com. The old pattern
    // only matched `/j/<digits>`, silently missing `/w/`, `/my/`, and gov.
    private static let zoomPattern = #"https?://(?:[\w-]+\.)?(?:zoom\.us|zoomgov\.com)/(?:j|w|my)/[\w.@-]+(?:\?[^\s]*)?"#
    private static let meetPattern = #"https?://meet\.google\.com/[\w-]+"#
    private static let teamsPattern = #"https?://teams\.microsoft\.com/[\w/.%-]+"#
    private static let webexPattern = #"https?://[\w-]+\.webex\.com/[\w/.%-]+"#
    private static let aroundPattern = #"https?://around\.co/[\w/-]+"#
    private static let wherebyPattern = #"https?://(?:[\w-]+\.)?whereby\.com/[\w/.-]+"#
    // Word-boundaried tokens so the generic fallback no longer matches
    // `call` inside `recall`/`teamcall`/`?utm_campaign=fallcall` or `video`
    // inside `videogame.com`. The keyword must appear in the host/path
    // (the `[^\s?#]*` prefix stops at `?`/`#`) so a query param like
    // `?type=conference` on a non-meeting link (Jira, CRM) doesn't count.
    // Still catches delimited path tokens like `/meet/`, `/video-call`,
    // `/conference?id=1`.
    private static let genericVideoPattern = #"https?://[^\s?#]*\b(?:meet|video|call|conference)\b[^\s]*"#

    private static let patterns: [(name: String, pattern: String)] = [
        ("zoom", zoomPattern),
        ("meet", meetPattern),
        ("teams", teamsPattern),
        ("webex", webexPattern),
        ("around", aroundPattern),
        ("whereby", wherebyPattern),
        ("generic", genericVideoPattern),
    ]

    public func extractMeetingUrl(from text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        for (_, pattern) in Self.patterns {
            if let match = firstMatch(pattern: pattern, in: text) {
                return match
            }
        }
        return nil
    }

    /// Multi-field overload. URL field wins if it's already a meeting URL,
    /// then location, then notes — matches Oatmeal's precedence.
    public func extractMeetingUrl(
        location: String?,
        notes: String?,
        url: String?
    ) -> String? {
        if let url, isMeetingUrl(url) {
            return url
        }
        if let match = extractMeetingUrl(from: location) {
            return match
        }
        if let match = extractMeetingUrl(from: notes) {
            return match
        }
        return nil
    }

    public func isMeetingUrl(_ url: String?) -> Bool {
        guard let url, !url.isEmpty else { return false }
        for (_, pattern) in Self.patterns {
            if firstMatch(pattern: pattern, in: url) != nil {
                return true
            }
        }
        return false
    }

    /// Friendly service name for UI ("Zoom", "Google Meet", …).
    public func identifyService(from url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        if url.contains("zoom.us") || url.contains("zoomgov.com") { return "Zoom" }
        if url.contains("meet.google.com") { return "Google Meet" }
        if url.contains("teams.microsoft.com") { return "Microsoft Teams" }
        if url.contains("webex.com") { return "Webex" }
        if url.contains("around.co") { return "Around" }
        if url.contains("whereby.com") { return "Whereby" }
        return nil
    }

    private func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        guard let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
    }
}

public extension MeetingLinkParser {
    static let shared = MeetingLinkParser()
}
