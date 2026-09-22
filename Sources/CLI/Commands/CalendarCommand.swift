import ArgumentParser
import Foundation
import MacParakeetCore

/// `macparakeet-cli calendar` — agent-friendly access to the EventKit
/// pipeline that powers calendar auto-start. Lets a developer or a CI agent
/// verify "is my permission set up + does my filter actually pick the right
/// events?" without launching the GUI.
struct CalendarCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Inspect the calendar pipeline used by meeting auto-start.",
        subcommands: [UpcomingCommand.self]
    )

    struct UpcomingCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "upcoming",
            abstract: "List upcoming calendar events visible to MacParakeet."
        )

        @Option(name: .long, help: "Number of days to look ahead. Default: 1.")
        var days: Int = 1

        @Option(name: .long, help: "Trigger filter: link | participants | all. Default: link.")
        var filter: String = "link"

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        func run() async throws {
            try await emitJSONOrRethrow(json: json) {
                guard let triggerFilter = parsedFilter() else {
                    throw ValidationError("--filter must be one of: link, participants, all")
                }
                switch CalendarService.shared.permissionStatus {
                case .denied:
                    throw CalendarCLIError.calendarPermissionDenied
                case .notDetermined:
                    throw CalendarCLIError.calendarPermissionNotDetermined
                case .granted:
                    break
                }

                let raw = try await CalendarService.shared.fetchUpcomingEvents(days: max(1, days))
                let events = raw.filter { calendarUpcomingPassesFilter($0, filter: triggerFilter) }
                let annotated = calendarUpcomingJSONEvents(
                    events,
                    skippedOccurrences: CalendarAutoStartPreferences.skippedOccurrences(
                        defaults: macParakeetAppDefaults()
                    ),
                    skippedEvents: CalendarAutoStartPreferences.skippedEvents(
                        defaults: macParakeetAppDefaults()
                    )
                )

                if json {
                    try printJSON(annotated)
                } else {
                    printHuman(annotated, filter: triggerFilter)
                }
            }
        }

        private func parsedFilter() -> MeetingTriggerFilter? {
            switch filter.lowercased() {
            case "link", "with-link", "withlink": return .withLink
            case "participants", "with-participants": return .withParticipants
            case "all", "all-events", "allevents": return .allEvents
            default: return nil
            }
        }

        private func printHuman(_ events: [CalendarUpcomingJSONEvent], filter: MeetingTriggerFilter) {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short

            print("Upcoming events (filter=\(filter.rawValue), days=\(max(1, days)))")
            print(String(repeating: "=", count: 60))
            if events.isEmpty {
                print("No matching events.")
                return
            }
            for row in events {
                let when = formatter.string(from: row.startTime)
                print()
                let skipMark = row.skipped ? " [skipped]" : ""
                print("• \(row.title)\(skipMark)")
                print("  Starts: \(when)  (\(durationMinutes(row)) min)")
                if let calendar = row.calendarName {
                    print("  Calendar: \(calendar)")
                }
                if let meetUrl = row.meetUrl {
                    let service = MeetingLinkParser.shared.identifyService(from: meetUrl) ?? "Link"
                    print("  \(service): \(meetUrl)")
                }
                if !row.participants.isEmpty {
                    print("  Participants: \(row.participants.count)")
                }
                if let status = row.userStatus, status != .accepted {
                    print("  Your status: \(status.rawValue)")
                }
            }
        }

        private func durationMinutes(_ event: CalendarUpcomingJSONEvent) -> Int {
            Int(event.endTime.timeIntervalSince(event.startTime) / 60)
        }
    }
}

private enum CalendarCLIError: Error, LocalizedError {
    case calendarPermissionDenied
    case calendarPermissionNotDetermined

    var errorDescription: String? {
        switch self {
        case .calendarPermissionDenied:
            return "Calendar access denied. Open System Settings → Privacy & Security → Calendars to grant MacParakeet access."
        case .calendarPermissionNotDetermined:
            return "Calendar access not yet requested. Launch MacParakeet, run onboarding (or visit Settings → Calendar), then retry."
        }
    }
}

/// Flat CLI JSON for `calendar upcoming`. Same fields as today's
/// `CalendarEvent` encoding plus skip annotations. Omits `isRecurring`.
struct CalendarUpcomingJSONEvent: Encodable, Equatable {
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
    let skipped: Bool
    let skipScope: String?

    enum CodingKeys: String, CodingKey {
        case id, title, startTime, endTime, location, meetUrl, participants
        case organizer, isAllDay, calendarName, calendarIdentifier, userStatus
        case externalId, syncedAt, skipped, skipScope
    }

    func encode(to encoder: Encoder) throws {
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
        try container.encode(skipped, forKey: .skipped)
        try container.encode(skipScope, forKey: .skipScope)
    }
}

func calendarUpcomingPassesFilter(_ event: CalendarEvent, filter: MeetingTriggerFilter) -> Bool {
    switch filter {
    case .allEvents: return !event.isAllDay
    case .withParticipants: return !event.isAllDay && event.participants.count >= 1
    case .withLink: return !event.isAllDay && event.meetUrl != nil
    }
}

func calendarUpcomingJSONEvents(
    _ events: [CalendarEvent],
    skippedOccurrences: Set<String>,
    skippedEvents: Set<String>
) -> [CalendarUpcomingJSONEvent] {
    events.map { event in
        let scope = CalendarSkip.matches(
            event,
            occurrences: skippedOccurrences,
            events: skippedEvents
        )
        return CalendarUpcomingJSONEvent(
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
            syncedAt: event.syncedAt,
            skipped: scope != nil,
            skipScope: scope?.rawValue
        )
    }
}
