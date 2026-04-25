import Foundation
import EventKit
import OSLog

/// Wraps EventKit (`EKEventStore`) so the rest of the app talks to a small,
/// testable surface instead of the framework directly.
///
/// MacParakeet does not run its own OAuth flows — the user's macOS Calendar
/// already aggregates Google/iCloud/Exchange accounts. ADR-002 (local-first):
/// events are read into memory on each poll and discarded, never persisted.
///
/// **Concurrency.** `EKEventStore` is documented as not thread-safe, and
/// Apple recommends a single long-lived store per app. This type is an
/// `actor` so all instance-method calls are serialized on the actor's
/// background executor — that solves both the thread-safety constraint *and*
/// keeps EventKit's synchronous `events(matching:)` disk I/O off the main
/// actor. Use `CalendarService.shared` rather than constructing your own.
public actor CalendarService {

    // MARK: - State

    private let eventStore = EKEventStore()
    private let linkParser = MeetingLinkParser()
    private let logger = Logger(subsystem: "com.macparakeet", category: "CalendarService")

    public var lookAheadDays: Int = 7
    public var excludeAllDay: Bool = true
    public var excludeDeclined: Bool = true

    /// Shared singleton — Apple recommends a single long-lived `EKEventStore`
    /// for the lifetime of the app. Multiple stores can return stale data and
    /// duplicate the file-system watcher cost.
    public static let shared = CalendarService()

    public init() {}

    // MARK: - Permission

    public enum PermissionStatus: Sendable {
        case notDetermined
        case granted
        case denied
    }

    /// `EKEventStore.authorizationStatus(for:)` is a thread-safe class method
    /// that doesn't touch the instance store, so we can read it without
    /// hopping into the actor — keeps Settings + Onboarding sync code paths
    /// simple. (`requestPermission` *does* touch the store so it stays
    /// actor-isolated.)
    public nonisolated var permissionStatus: PermissionStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined:
            return .notDetermined
        case .fullAccess, .authorized:
            return .granted
        case .denied, .restricted, .writeOnly:
            return .denied
        @unknown default:
            return .denied
        }
    }

    /// Whether any calendars are visible. Triggers `eventStore.reset()` so we
    /// pick up permissions granted by *another* `EKEventStore` instance —
    /// e.g. when `PermissionService` shows the prompt during onboarding, this
    /// service's stale state would otherwise still report no calendars.
    public func hasCalendars() -> Bool {
        guard permissionStatus == .granted else { return false }
        eventStore.reset()
        return !eventStore.calendars(for: .event).isEmpty
    }

    /// Modern macOS Sonoma+ API. Returns `false` when the user denies or the
    /// system reports an error (logged for debugging).
    public func requestPermission() async -> Bool {
        logger.info("Requesting calendar permission")
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            if granted {
                logger.info("Calendar permission granted")
            } else {
                logger.warning("Calendar permission denied")
            }
            return granted
        } catch {
            logger.error("Calendar permission request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Available Calendars

    /// Lightweight metadata for the per-calendar include list in Settings.
    /// Returns empty if permission is missing rather than throwing — Settings
    /// just shows an empty state in that case.
    public func availableCalendars() -> [CalendarInfo] {
        guard permissionStatus == .granted else { return [] }
        eventStore.reset()
        return eventStore.calendars(for: .event).map { calendar in
            CalendarInfo(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                sourceTitle: calendar.source?.title
            )
        }
    }

    // MARK: - Fetch Events

    public func fetchUpcomingEvents(from: Date = Date(), days: Int? = nil) async throws -> [CalendarEvent] {
        guard permissionStatus == .granted else {
            throw CalendarError.permissionDenied
        }

        let lookAhead = days ?? lookAheadDays
        let endDate = Calendar.current.date(byAdding: .day, value: lookAhead, to: from)!

        logger.debug("Fetching events from \(from) to \(endDate)")

        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(
            withStart: from,
            end: endDate,
            calendars: calendars
        )
        let ekEvents = eventStore.events(matching: predicate)

        let events = ekEvents.compactMap { convertEvent($0) }
            .filter { shouldInclude($0) }
            .sorted { $0.startTime < $1.startTime }

        logger.info("Returning \(events.count) filtered events")
        return events
    }

    /// Includes in-progress events (looks back 2h) so a user starting the app
    /// mid-meeting still sees the matching event.
    public func fetchCurrentAndUpcoming(withinMinutes: Int = 15) async throws -> [CalendarEvent] {
        guard permissionStatus == .granted else {
            throw CalendarError.permissionDenied
        }

        let now = Date()
        let startDate = now.addingTimeInterval(-2 * 60 * 60)
        let endDate = now.addingTimeInterval(TimeInterval(withinMinutes * 60))

        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars
        )
        let ekEvents = eventStore.events(matching: predicate)

        return ekEvents.compactMap { convertEvent($0) }
            .filter { shouldInclude($0) }
            .filter { $0.isNow || $0.startsWithin(minutes: withinMinutes) }
            .sorted { $0.startTime < $1.startTime }
    }

    // MARK: - EKEvent → CalendarEvent

    private func convertEvent(_ ekEvent: EKEvent) -> CalendarEvent? {
        guard let startDate = ekEvent.startDate,
              let endDate = ekEvent.endDate else {
            return nil
        }

        // Capture the user's status *before* filtering them out of the
        // participant list — otherwise we lose the signal needed to honor
        // declined events.
        var userStatus: EventParticipant.ParticipantStatus?
        if let attendees = ekEvent.attendees {
            if let currentUser = attendees.first(where: { $0.isCurrentUser }) {
                userStatus = mapStatus(currentUser.participantStatus)
            }
        }

        let participants = (ekEvent.attendees ?? []).compactMap { attendee -> EventParticipant? in
            if attendee.isCurrentUser { return nil }

            let email: String? = {
                let urlString = attendee.url.absoluteString
                if urlString.hasPrefix("mailto:") {
                    return urlString.replacingOccurrences(of: "mailto:", with: "")
                }
                return nil
            }()

            return EventParticipant(
                email: email,
                name: attendee.name,
                status: mapStatus(attendee.participantStatus)
            )
        }

        let meetUrl = linkParser.extractMeetingUrl(
            location: ekEvent.location,
            notes: ekEvent.notes,
            url: ekEvent.url?.absoluteString
        )

        return CalendarEvent(
            id: ekEvent.eventIdentifier,
            title: ekEvent.title ?? "Untitled",
            startTime: startDate,
            endTime: endDate,
            location: ekEvent.location,
            meetUrl: meetUrl,
            participants: participants,
            isAllDay: ekEvent.isAllDay,
            calendarName: ekEvent.calendar?.title,
            calendarIdentifier: ekEvent.calendar?.calendarIdentifier,
            userStatus: userStatus,
            externalId: ekEvent.calendarItemExternalIdentifier,
            syncedAt: Date()
        )
    }

    private func mapStatus(_ status: EKParticipantStatus) -> EventParticipant.ParticipantStatus {
        switch status {
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        case .pending: return .pending
        default: return .unknown
        }
    }

    private func shouldInclude(_ event: CalendarEvent) -> Bool {
        if excludeAllDay && event.isAllDay { return false }
        if excludeDeclined && event.userDeclined { return false }
        return true
    }
}

public enum CalendarError: Error, LocalizedError {
    case permissionDenied
    case fetchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Calendar access denied. Please grant access in System Settings > Privacy & Security > Calendars."
        case .fetchFailed(let message):
            return "Failed to fetch calendar events: \(message)"
        }
    }
}

public extension CalendarService {
    /// Deep-link to the Calendar privacy pane in System Settings.
    nonisolated static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
}
