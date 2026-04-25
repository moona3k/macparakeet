import Foundation
import MacParakeetCore

/// In-memory `CalendarServicing` for coordinator + ViewModel tests. Lets
/// callers control the permission status (so tests can simulate
/// `.notDetermined` → grant flows), preset the events returned by
/// `fetchUpcomingEvents`, and observe how many fetches actually happened
/// (so polling-cadence tests can assert "exactly N fetches in this window").
///
/// `final class` not actor: tests run synchronously and need to inspect
/// state immediately after a poll completes. The `nonisolated(unsafe)`
/// storage is fine because XCTest tests run their assertions on a single
/// thread.
final class MockCalendarService: CalendarServicing, @unchecked Sendable {
    nonisolated(unsafe) var stubPermissionStatus: CalendarService.PermissionStatus = .notDetermined
    nonisolated(unsafe) var requestPermissionResult: Bool = true
    nonisolated(unsafe) var stubCalendars: [CalendarInfo] = []
    nonisolated(unsafe) var stubEvents: [CalendarEvent] = []
    nonisolated(unsafe) var stubFetchError: Error?

    nonisolated(unsafe) private(set) var requestPermissionCallCount = 0
    nonisolated(unsafe) private(set) var fetchUpcomingEventsCallCount = 0
    nonisolated(unsafe) private(set) var availableCalendarsCallCount = 0

    nonisolated var permissionStatus: CalendarService.PermissionStatus {
        stubPermissionStatus
    }

    func requestPermission() async -> Bool {
        requestPermissionCallCount += 1
        if requestPermissionResult {
            stubPermissionStatus = .granted
        } else {
            stubPermissionStatus = .denied
        }
        return requestPermissionResult
    }

    func availableCalendars() async -> [CalendarInfo] {
        availableCalendarsCallCount += 1
        return stubCalendars
    }

    func fetchUpcomingEvents(from: Date, days: Int?) async throws -> [CalendarEvent] {
        fetchUpcomingEventsCallCount += 1
        if let stubFetchError {
            throw stubFetchError
        }
        return stubEvents
    }
}
