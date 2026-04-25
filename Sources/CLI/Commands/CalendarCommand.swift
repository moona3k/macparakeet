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
            let events = raw.filter { passesFilter($0, filter: triggerFilter) }

            if json {
                printJSON(events)
            } else {
                printHuman(events, filter: triggerFilter)
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

        private func passesFilter(_ event: CalendarEvent, filter: MeetingTriggerFilter) -> Bool {
            switch filter {
            case .allEvents: return !event.isAllDay
            case .withParticipants: return !event.isAllDay && event.participants.count >= 1
            case .withLink: return !event.isAllDay && event.meetUrl != nil
            }
        }

        private func printHuman(_ events: [CalendarEvent], filter: MeetingTriggerFilter) {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short

            print("Upcoming events (filter=\(filter.rawValue), days=\(max(1, days)))")
            print(String(repeating: "=", count: 60))
            if events.isEmpty {
                print("No matching events.")
                return
            }
            for event in events {
                let when = formatter.string(from: event.startTime)
                print()
                print("• \(event.title)")
                print("  Starts: \(when)  (\(event.durationMinutes) min)")
                if let calendar = event.calendarName {
                    print("  Calendar: \(calendar)")
                }
                if let meetUrl = event.meetUrl {
                    let service = MeetingLinkParser.shared.identifyService(from: meetUrl) ?? "Link"
                    print("  \(service): \(meetUrl)")
                }
                if !event.participants.isEmpty {
                    print("  Participants: \(event.participants.count)")
                }
                if let status = event.userStatus, status != .accepted {
                    print("  Your status: \(status.rawValue)")
                }
            }
        }

        private func printJSON(_ events: [CalendarEvent]) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                let data = try encoder.encode(events)
                if let s = String(data: data, encoding: .utf8) {
                    print(s)
                }
            } catch {
                FileHandle.standardError.write(Data("Failed to encode JSON: \(error.localizedDescription)\n".utf8))
            }
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
