import Foundation

/// Determines which calendar events the meeting coordinator considers
/// "real meetings worth recording." Higher precision filters reduce false
/// positives (a "Lunch" calendar block won't fire a recording reminder); lower
/// precision filters cover edge cases (phone calls, single-attendee meetings).
public enum MeetingTriggerFilter: String, Codable, Sendable, CaseIterable {
    /// Default. Event has a Zoom / Google Meet / Teams / Webex / Around link
    /// in its location, notes, or URL field. Highest signal-to-noise.
    case withLink

    /// 2+ attendees including "me" — i.e. the event has at least one other
    /// participant. Catches phone calls and meetings without dial-in URLs.
    case withParticipants

    /// Every non-all-day event. Useful for solo focus blocks the user wants
    /// transcribed (e.g. "Record voice memo at 3pm").
    case allEvents
}
