import Foundation

public struct MeetingCalendarSnapshot: Codable, Sendable, Equatable {
    public enum Confidence: String, Codable, Sendable {
        case confirmed
        case probable
    }

    public var confidence: Confidence
    public var eventIdentifier: String
    public var externalId: String?
    public var title: String
    public var scheduledStartAt: Date
    public var scheduledEndAt: Date
    public var attendees: [MeetingCalendarPerson]
    public var organizer: MeetingCalendarPerson?
    public var meetingURL: String?
    public var meetingService: String?
    public var capturedAt: Date

    public init(
        confidence: Confidence,
        eventIdentifier: String,
        externalId: String? = nil,
        title: String,
        scheduledStartAt: Date,
        scheduledEndAt: Date,
        attendees: [MeetingCalendarPerson] = [],
        organizer: MeetingCalendarPerson? = nil,
        meetingURL: String? = nil,
        meetingService: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.confidence = confidence
        self.eventIdentifier = eventIdentifier
        self.externalId = externalId
        self.title = title
        self.scheduledStartAt = scheduledStartAt
        self.scheduledEndAt = scheduledEndAt
        self.attendees = attendees
        self.organizer = organizer
        self.meetingURL = meetingURL
        self.meetingService = meetingService
        self.capturedAt = capturedAt
    }
}

public struct MeetingCalendarPerson: Codable, Sendable, Equatable {
    public var name: String?
    public var email: String?

    public init(name: String? = nil, email: String? = nil) {
        self.name = name
        self.email = email
    }
}

public extension MeetingCalendarSnapshot {
    init(
        event: CalendarEvent,
        confidence: Confidence,
        capturedAt: Date = Date()
    ) {
        self.init(
            confidence: confidence,
            eventIdentifier: event.id,
            externalId: event.externalId,
            title: event.title,
            scheduledStartAt: event.startTime,
            scheduledEndAt: event.endTime,
            attendees: event.participants.map {
                MeetingCalendarPerson(name: $0.name, email: $0.email)
            },
            organizer: event.organizer.map {
                MeetingCalendarPerson(name: $0.name, email: $0.email)
            },
            meetingURL: event.meetUrl,
            meetingService: MeetingLinkParser.shared.identifyService(from: event.meetUrl),
            capturedAt: capturedAt
        )
    }
}
