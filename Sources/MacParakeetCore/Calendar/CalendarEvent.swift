import Foundation

/// A calendar event fetched from EventKit at poll time.
///
/// MacParakeet does **not** persist these — the coordinator fetches and
/// discards on each poll tick. See ADR-017 §6 for the rationale. If we ever
/// need to query event history (e.g., for retro-linking recordings to events),
/// add a `CalendarEvent` table then.
public struct CalendarEvent: Codable, Sendable, Identifiable {
    /// EventKit's `EKEvent.eventIdentifier`. Stable across syncs but can
    /// change for recurring events when the user edits a single occurrence.
    /// Use `externalId` if you need a stronger identity.
    public var id: String

    public var title: String
    public var startTime: Date
    public var endTime: Date
    public var location: String?

    /// Extracted Zoom / Meet / Teams / Webex / Around URL.
    public var meetUrl: String?

    /// Other attendees — current user is filtered out at conversion time
    /// (their participation status is captured separately in `userStatus`).
    public var participants: [EventParticipant]

    public var isAllDay: Bool

    /// e.g. "Work", "Personal" — used for the per-calendar include list.
    public var calendarName: String?

    /// Current user's participation status, lifted off `EKAttendee` before
    /// the participant list is filtered. Used to suppress declined events.
    public var userStatus: EventParticipant.ParticipantStatus?

    /// `EKEvent.calendarItemExternalIdentifier` — more stable than `id` for
    /// recurring events whose occurrences get reorganized server-side.
    public var externalId: String?

    public var syncedAt: Date

    public init(
        id: String,
        title: String,
        startTime: Date,
        endTime: Date,
        location: String? = nil,
        meetUrl: String? = nil,
        participants: [EventParticipant] = [],
        isAllDay: Bool = false,
        calendarName: String? = nil,
        userStatus: EventParticipant.ParticipantStatus? = nil,
        externalId: String? = nil,
        syncedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.location = location
        self.meetUrl = meetUrl
        self.participants = participants
        self.isAllDay = isAllDay
        self.calendarName = calendarName
        self.userStatus = userStatus
        self.externalId = externalId
        self.syncedAt = syncedAt
    }
}

public struct EventParticipant: Codable, Sendable, Hashable {
    public var email: String?
    public var name: String?
    public var status: ParticipantStatus

    public init(email: String? = nil, name: String? = nil, status: ParticipantStatus = .unknown) {
        self.email = email
        self.name = name
        self.status = status
    }

    public enum ParticipantStatus: String, Codable, Sendable {
        case accepted
        case declined
        case tentative
        case pending
        case unknown
    }
}

public extension CalendarEvent {
    var durationMinutes: Int {
        Int(endTime.timeIntervalSince(startTime) / 60)
    }

    var isNow: Bool {
        let now = Date()
        return startTime <= now && endTime >= now
    }

    func startsWithin(minutes: Int) -> Bool {
        let now = Date()
        let threshold = now.addingTimeInterval(TimeInterval(minutes * 60))
        return startTime > now && startTime <= threshold
    }

    var timeUntilStart: TimeInterval {
        startTime.timeIntervalSinceNow
    }

    var formattedTimeRange: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "\(formatter.string(from: startTime)) - \(formatter.string(from: endTime))"
    }

    var attendeeCount: Int {
        participants.count
    }

    var isMeeting: Bool {
        !participants.isEmpty || meetUrl != nil
    }

    var userDeclined: Bool {
        userStatus == .declined
    }
}

extension CalendarEvent: Hashable {
    public static func == (lhs: CalendarEvent, rhs: CalendarEvent) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Lightweight info for the per-calendar include list in Settings — we don't
/// need the full `EKCalendar` surface here.
public struct CalendarInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var sourceTitle: String?

    public init(id: String, title: String, sourceTitle: String? = nil) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
    }
}
