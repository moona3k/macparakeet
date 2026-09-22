import Foundation

/// A calendar event fetched from EventKit at poll time.
///
/// MacParakeet does not persist the polling cache, but a meeting recording may
/// snapshot the triggering event onto its local transcript row and artifacts.
/// See ADR-017 §6 for the current persistence boundary.
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

    /// EventKit's organizer, when supplied by the backing calendar.
    public var organizer: EventParticipant?

    public var isAllDay: Bool

    /// e.g. "Work", "Personal" — display label for UI surfaces. **Don't key
    /// the per-calendar exclude list on this** — multiple accounts can have
    /// the same human-readable title (two "Calendar"s, two "Work"s). Use
    /// `calendarIdentifier` for filtering.
    public var calendarName: String?

    /// Stable `EKCalendar.calendarIdentifier`. Used to key the per-calendar
    /// exclude list — survives renames and disambiguates same-titled
    /// calendars across accounts.
    public var calendarIdentifier: String?

    /// Current user's participation status, lifted off `EKAttendee` before
    /// the participant list is filtered. Used to suppress declined events.
    public var userStatus: EventParticipant.ParticipantStatus?

    /// `EKEvent.calendarItemExternalIdentifier` — more stable than `id` for
    /// recurring events whose occurrences get reorganized server-side.
    public var externalId: String?

    /// `EKEvent.hasRecurrenceRules || EKEvent.isDetached`. Not inferred from
    /// a non-nil `externalId`. Default `false` so fixtures compile.
    public var isRecurring: Bool

    public var syncedAt: Date

    public init(
        id: String,
        title: String,
        startTime: Date,
        endTime: Date,
        location: String? = nil,
        meetUrl: String? = nil,
        participants: [EventParticipant] = [],
        organizer: EventParticipant? = nil,
        isAllDay: Bool = false,
        calendarName: String? = nil,
        calendarIdentifier: String? = nil,
        userStatus: EventParticipant.ParticipantStatus? = nil,
        externalId: String? = nil,
        isRecurring: Bool = false,
        syncedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.location = location
        self.meetUrl = meetUrl
        self.participants = participants
        self.organizer = organizer
        self.isAllDay = isAllDay
        self.calendarName = calendarName
        self.calendarIdentifier = calendarIdentifier
        self.userStatus = userStatus
        self.externalId = externalId
        self.isRecurring = isRecurring
        self.syncedAt = syncedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, startTime, endTime, location, meetUrl, participants
        case organizer, isAllDay, calendarName, calendarIdentifier, userStatus
        case externalId, isRecurring, syncedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        startTime = try container.decode(Date.self, forKey: .startTime)
        endTime = try container.decode(Date.self, forKey: .endTime)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        meetUrl = try container.decodeIfPresent(String.self, forKey: .meetUrl)
        participants = try container.decodeIfPresent([EventParticipant].self, forKey: .participants) ?? []
        organizer = try container.decodeIfPresent(EventParticipant.self, forKey: .organizer)
        isAllDay = try container.decodeIfPresent(Bool.self, forKey: .isAllDay) ?? false
        calendarName = try container.decodeIfPresent(String.self, forKey: .calendarName)
        calendarIdentifier = try container.decodeIfPresent(String.self, forKey: .calendarIdentifier)
        userStatus = try container.decodeIfPresent(EventParticipant.ParticipantStatus.self, forKey: .userStatus)
        externalId = try container.decodeIfPresent(String.self, forKey: .externalId)
        isRecurring = try container.decodeIfPresent(Bool.self, forKey: .isRecurring) ?? false
        syncedAt = try container.decodeIfPresent(Date.self, forKey: .syncedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(meetUrl, forKey: .meetUrl)
        try container.encode(participants, forKey: .participants)
        try container.encodeIfPresent(organizer, forKey: .organizer)
        try container.encode(isAllDay, forKey: .isAllDay)
        try container.encodeIfPresent(calendarName, forKey: .calendarName)
        try container.encodeIfPresent(calendarIdentifier, forKey: .calendarIdentifier)
        try container.encodeIfPresent(userStatus, forKey: .userStatus)
        try container.encodeIfPresent(externalId, forKey: .externalId)
        try container.encode(isRecurring, forKey: .isRecurring)
        try container.encode(syncedAt, forKey: .syncedAt)
    }
}

public struct EventParticipant: Codable, Sendable, Hashable {
    public var email: String?
    public var name: String?
    public var status: ParticipantStatus
    /// EventKit participant type. Optional so events encoded before the field
    /// existed still decode; `nil` is treated as a person.
    public var kind: ParticipantKind?

    public init(
        email: String? = nil,
        name: String? = nil,
        status: ParticipantStatus = .unknown,
        kind: ParticipantKind? = nil
    ) {
        self.email = email
        self.name = name
        self.status = status
        self.kind = kind
    }

    public enum ParticipantStatus: String, Codable, Sendable {
        case accepted
        case declined
        case tentative
        case pending
        case unknown
    }

    public enum ParticipantKind: String, Codable, Sendable {
        case person
        case room
        case resource
        case group
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

    /// Stable key for the coordinator's per-occurrence suppression sets
    /// (reminded / countdown-shown / skipped occurrence). Combines `id` with the start
    /// time so rescheduling an event to a different time is treated as a fresh
    /// occurrence that can re-fire — keying on `id` alone permanently
    /// suppressed a same-day reschedule. Whole-second granularity is plenty;
    /// meetings don't move by sub-second amounts.
    var dedupeKey: String {
        "\(id)|\(Int(startTime.timeIntervalSinceReferenceDate))"
    }

    var isMeeting: Bool {
        !participants.isEmpty || meetUrl != nil
    }

    var userDeclined: Bool {
        userStatus == .declined
    }

    /// Meeting/series identity for event-level skip. `externalId` when
    /// present, otherwise `id`.
    var eventKey: String {
        CalendarSkip.eventKey(for: self)
    }
}

// Identity is `id` only (EventKit's `eventIdentifier`). This is deliberate:
// `==`/`hash` answer "same calendar event," not "same occurrence." A
// rescheduled occurrence keeps its `id`, so two occurrences of one recurring
// series can compare equal — meaning a `Set<CalendarEvent>` would silently
// collapse them. The coordinator never does that: occurrence-level identity
// (suppression sets, reschedule re-fire) is keyed on `dedupeKey` (id + start
// time), and the only `contains` over a `[CalendarEvent]` (owned-event merge)
// matches on `id` on purpose. If a future caller needs per-occurrence set
// semantics, key on `dedupeKey`, not the event itself.
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
