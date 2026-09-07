import Foundation

/// Speaker-count prior for the meeting system track, derived from the
/// calendar attendee snapshot captured when the recording started.
///
/// The prior never forces clusters: the minimum is always 1 and only the
/// maximum carries the attendee count. FluidAudio's `minSpeakers` binds by
/// re-clustering upward with K-Means, so a wrong minimum (declined,
/// tentative, or resource attendees, no-shows) would split real speakers,
/// whereas a generous maximum only caps over-splitting, which is the
/// reported complaint (#542). See ADR-010 (2026-09-06 amendment) and issue
/// #972; this deliberately narrows the issue's `min = max(1, n - 1)`.
public enum MeetingSpeakerPrior: Equatable, Sendable {
    /// No usable attendee count; the clusterer picks the count itself.
    case unconstrained(reason: UnconstrainedReason)
    /// Bounds handed to the clusterer: `min` is always 1, `max` is `n + 1`.
    case bounds(min: Int, max: Int)

    public enum UnconstrainedReason: String, Equatable, Sendable {
        /// No calendar snapshot or no countable attendee.
        case noAttendeeCount = "no_attendee_count"
        /// Attendee count above `maxAttendeesForBounds`; large invites are a
        /// poor proxy for who actually speaks and the maximum would never bind.
        case largeAttendeeCount = "large_attendee_count"
    }

    /// Largest remote attendee count that still yields bounds.
    public static let maxAttendeesForBounds = 8

    /// `remoteAttendeeCount` excludes the user. `nil` or zero means unknown.
    public static func derive(remoteAttendeeCount: Int?) -> MeetingSpeakerPrior {
        guard let count = remoteAttendeeCount, count > 0 else {
            return .unconstrained(reason: .noAttendeeCount)
        }
        guard count <= maxAttendeesForBounds else {
            return .unconstrained(reason: .largeAttendeeCount)
        }
        return .bounds(min: 1, max: count + 1)
    }

    /// Attendees in the snapshot already exclude the current user (see
    /// `CalendarService.convertEvent`). Attendees captured as `declined`, and
    /// participants captured as a `room`, `resource`, or `group`, are excluded;
    /// tentative, pending, unknown, and legacy snapshots without status or
    /// kind all count.
    ///
    /// De-duplication uses a single fallback key per entry: the lowercased
    /// email when present, otherwise the lowercased name. Two entries for the
    /// same person where one carries only a name and the other an email are
    /// therefore counted separately, and two different emails with the same
    /// name stay separate. Entries with neither field still count once each.
    public static func derive(from snapshot: MeetingCalendarSnapshot?) -> MeetingSpeakerPrior {
        derive(remoteAttendeeCount: snapshot.map { remoteAttendeeCount(in: $0) })
    }

    static let declinedStatus = EventParticipant.ParticipantStatus.declined.rawValue
    static let nonSpeakingKinds: Set<String> = [
        EventParticipant.ParticipantKind.room.rawValue,
        EventParticipant.ParticipantKind.resource.rawValue,
        EventParticipant.ParticipantKind.group.rawValue,
    ]

    static func remoteAttendeeCount(in snapshot: MeetingCalendarSnapshot) -> Int {
        var seenKeys = Set<String>()
        var count = 0
        for attendee in snapshot.attendees where isCountable(attendee) {
            let email = attendee.email?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            let name = attendee.name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            let key: String
            if !email.isEmpty {
                key = "email:\(email)"
            } else if !name.isEmpty {
                key = "name:\(name)"
            } else {
                count += 1
                continue
            }
            if seenKeys.insert(key).inserted {
                count += 1
            }
        }
        return count
    }

    static func isCountable(_ attendee: MeetingCalendarPerson) -> Bool {
        if attendee.status == declinedStatus { return false }
        if let kind = attendee.kind, nonSpeakingKinds.contains(kind) { return false }
        return true
    }

    /// Constraint to pass to the diarizer, or `nil` when clustering runs
    /// unconstrained.
    public var speakerConstraint: SpeakerDiarizationConstraint? {
        switch self {
        case .bounds(let min, let max):
            return .range(min: min, max: max)
        case .unconstrained:
            return nil
        }
    }

    /// Stable, PII-free label for diagnostics and telemetry.
    public var diagnosticsLabel: String {
        switch self {
        case .unconstrained(let reason):
            return "unconstrained_\(reason.rawValue)"
        case .bounds(let min, let max):
            return "bounds_\(min)_\(max)"
        }
    }
}

/// What the meeting finalizer actually applies to the system-track diarizer
/// after reconciling the calendar prior with an explicit user constraint.
public enum MeetingSpeakerPolicy: Equatable, Sendable {
    /// The calendar-derived prior applies.
    case prior(MeetingSpeakerPrior)
    /// The diarization service carries an explicit constraint (CLI
    /// `--speaker-count` / `--speaker-min` / `--speaker-max`); it wins over the
    /// calendar prior, which is discarded.
    case explicitConstraint

    public static func resolve(
        prior: MeetingSpeakerPrior,
        explicitConstraint: SpeakerDiarizationConstraint?
    ) -> MeetingSpeakerPolicy {
        explicitConstraint == nil ? .prior(prior) : .explicitConstraint
    }

    /// Hint handed to `diarize(audioURL:speakerConstraint:)`. `nil` under an
    /// explicit constraint: the service already holds it and would discard
    /// the hint anyway.
    public var speakerConstraintHint: SpeakerDiarizationConstraint? {
        switch self {
        case .prior(let prior):
            return prior.speakerConstraint
        case .explicitConstraint:
            return nil
        }
    }

    /// Stable, PII-free `speaker_prior` value for diagnostics and telemetry:
    /// `explicit_cli`, `bounds_1_<n+1>`, `unconstrained_no_attendee_count`, or
    /// `unconstrained_large_attendee_count`.
    public var diagnosticsLabel: String {
        switch self {
        case .prior(let prior):
            return prior.diagnosticsLabel
        case .explicitConstraint:
            return "explicit_cli"
        }
    }
}
