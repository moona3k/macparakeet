import Foundation

/// Scope of a persisted per-event mute. Event-level wins when both match.
public enum CalendarSkipScope: String, Sendable, Equatable {
    case occurrence
    case event
}

/// Preference-key helpers for per-event calendar skip (#609). Pure: no
/// EventKit, UserDefaults, or UI.
public enum CalendarSkip {
    public static func eventKey(for event: CalendarEvent) -> String {
        event.externalId ?? event.id
    }

    public static func matches(
        _ event: CalendarEvent,
        occurrences: Set<String>,
        events: Set<String>
    ) -> CalendarSkipScope? {
        if events.contains(eventKey(for: event)) {
            return .event
        }
        if occurrences.contains(event.dedupeKey) {
            return .occurrence
        }
        return nil
    }

    /// Occurrence keys older than `maxAge` may be dropped; they can never
    /// re-fire. Parse `dedupeKey` on the last `|`. Unparseable keys are kept.
    public static func prunedOccurrences(
        _ keys: Set<String>,
        now: Date = Date(),
        maxAge: TimeInterval = 14 * 24 * 60 * 60
    ) -> Set<String> {
        let cutoff = now.timeIntervalSinceReferenceDate - maxAge
        return keys.filter { key in
            guard let separator = key.lastIndex(of: "|") else { return true }
            let startToken = key[key.index(after: separator)...]
            guard let startSeconds = TimeInterval(startToken) else { return true }
            return startSeconds >= cutoff
        }
    }
}
