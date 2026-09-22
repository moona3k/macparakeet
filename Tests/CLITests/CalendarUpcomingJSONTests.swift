import Foundation
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class CalendarUpcomingJSONTests: XCTestCase {
    func testMapperPreservesExistingFieldsAndAddsSkipAnnotations() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let event = CalendarEvent(
            id: "evt-1",
            title: "Standup",
            startTime: start,
            endTime: start.addingTimeInterval(1800),
            location: nil,
            meetUrl: "https://zoom.us/j/123",
            participants: [EventParticipant(email: "ava@example.com")],
            isAllDay: false,
            calendarName: "Work",
            calendarIdentifier: "cal-1",
            userStatus: .accepted,
            externalId: "ext-1",
            isRecurring: true,
            syncedAt: start
        )

        let rows = calendarUpcomingJSONEvents(
            [event],
            skippedOccurrences: [],
            skippedEvents: []
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].skipped)
        XCTAssertNil(rows[0].skipScope)

        let dtoData = try cliJSONEncoder.encode(rows)
        let dtoObject = try XCTUnwrap(JSONSerialization.jsonObject(with: dtoData) as? [[String: Any]])
        XCTAssertEqual(dtoObject.count, 1)
        var payload = dtoObject[0]
        XCTAssertNil(payload["isRecurring"])
        XCTAssertEqual(payload["skipped"] as? Bool, false)
        XCTAssertTrue(payload["skipScope"] is NSNull)
        payload.removeValue(forKey: "skipped")
        payload.removeValue(forKey: "skipScope")

        let eventData = try cliJSONEncoder.encode(legacyEncodable(event))
        let eventObject = try XCTUnwrap(JSONSerialization.jsonObject(with: eventData) as? [String: Any])
        XCTAssertEqual(payload as NSDictionary, eventObject as NSDictionary)
    }

    func testSkippedOccurrenceAnnotatesScope() {
        let event = CalendarEvent(
            id: "evt-1",
            title: "Standup",
            startTime: Date(),
            endTime: Date().addingTimeInterval(1800),
            meetUrl: "https://zoom.us/j/123"
        )
        let rows = calendarUpcomingJSONEvents(
            [event],
            skippedOccurrences: [event.dedupeKey],
            skippedEvents: []
        )
        XCTAssertEqual(rows[0].skipped, true)
        XCTAssertEqual(rows[0].skipScope, "occurrence")
    }

    func testFilterMembershipIgnoresExcludedCalendarsAndKeepsDeclinedOutOfLocalFilterOnly() {
        let declined = CalendarEvent(
            id: "d",
            title: "Declined",
            startTime: Date(),
            endTime: Date().addingTimeInterval(1800),
            meetUrl: "https://zoom.us/j/1",
            userStatus: .declined
        )
        XCTAssertTrue(calendarUpcomingPassesFilter(declined, filter: .withLink))
        let allDay = CalendarEvent(
            id: "a",
            title: "All day",
            startTime: Date(),
            endTime: Date().addingTimeInterval(1800),
            meetUrl: "https://zoom.us/j/1",
            isAllDay: true
        )
        XCTAssertFalse(calendarUpcomingPassesFilter(allDay, filter: .withLink))
    }

    private struct LegacyCalendarJSON: Encodable {
        let id: String
        let title: String
        let startTime: Date
        let endTime: Date
        let location: String?
        let meetUrl: String?
        let participants: [EventParticipant]
        let organizer: EventParticipant?
        let isAllDay: Bool
        let calendarName: String?
        let calendarIdentifier: String?
        let userStatus: EventParticipant.ParticipantStatus?
        let externalId: String?
        let syncedAt: Date

        func encode(to encoder: Encoder) throws {
            enum CodingKeys: String, CodingKey {
                case id, title, startTime, endTime, location, meetUrl, participants
                case organizer, isAllDay, calendarName, calendarIdentifier, userStatus
                case externalId, syncedAt
            }
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
            try container.encode(syncedAt, forKey: .syncedAt)
        }
    }

    private func legacyEncodable(_ event: CalendarEvent) -> LegacyCalendarJSON {
        LegacyCalendarJSON(
            id: event.id,
            title: event.title,
            startTime: event.startTime,
            endTime: event.endTime,
            location: event.location,
            meetUrl: event.meetUrl,
            participants: event.participants,
            organizer: event.organizer,
            isAllDay: event.isAllDay,
            calendarName: event.calendarName,
            calendarIdentifier: event.calendarIdentifier,
            userStatus: event.userStatus,
            externalId: event.externalId,
            syncedAt: event.syncedAt
        )
    }
}
