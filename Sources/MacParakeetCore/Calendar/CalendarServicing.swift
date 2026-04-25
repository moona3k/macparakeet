import Foundation

/// Protocol surface that the meeting auto-start coordinator (and tests) talk
/// to. Defined in `MacParakeetCore` so test targets can stub without taking
/// a dependency on EventKit. The concrete `CalendarService` actor conforms;
/// tests inject a `MockCalendarService` (in `Tests/`) with controllable
/// permission status and event lists.
///
/// Mirrors the public surface of `CalendarService` that has consumers today.
/// Properties stay `nonisolated` to match the actor; methods are `async` so
/// the actor implementation can serialize `EKEventStore` access without
/// blocking the main thread.
public protocol CalendarServicing: Sendable {
    /// Cheap synchronous read backed by `EKEventStore.authorizationStatus`.
    nonisolated var permissionStatus: CalendarService.PermissionStatus { get }

    /// Triggers the EventKit prompt. Returns the granted state. On grant the
    /// concrete service also resets the event store so the next fetch sees
    /// the new permission immediately.
    func requestPermission() async -> Bool

    /// Lightweight list for the per-calendar include UI. Returns empty when
    /// permission is missing rather than throwing.
    func availableCalendars() async -> [CalendarInfo]

    /// Look-ahead fetch used by the polling coordinator. Throws
    /// `CalendarError.permissionDenied` when access is missing or
    /// `CalendarError.fetchFailed` for malformed input.
    func fetchUpcomingEvents(from: Date, days: Int?) async throws -> [CalendarEvent]
}

extension CalendarService: CalendarServicing {}

/// Convenience overload so callers can omit the date parameter — matches the
/// concrete `CalendarService` default. Defined on the protocol so mocks
/// inherit it for free.
public extension CalendarServicing {
    func fetchUpcomingEvents(days: Int? = nil) async throws -> [CalendarEvent] {
        try await fetchUpcomingEvents(from: Date(), days: days)
    }
}
