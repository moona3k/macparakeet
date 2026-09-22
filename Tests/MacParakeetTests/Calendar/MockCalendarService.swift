import Foundation
import MacParakeetCore

/// In-memory `CalendarServicing` for coordinator + ViewModel tests. Lets
/// callers control the permission status (so tests can simulate
/// `.notDetermined` → grant flows), preset the events returned by
/// `fetchUpcomingEvents`, and observe how many fetches actually happened
/// (so polling-cadence tests can assert "exactly N fetches in this window").
///
/// `final class` rather than an actor: tests set and inspect simple stubs
/// synchronously. Calendar discovery state is lock-protected because its
/// refresh tests intentionally overlap async calls; coordinator stubs are
/// exercised serially by their existing tests.
final class MockCalendarService: CalendarServicing, @unchecked Sendable {
    private struct AvailableCalendarsState {
        var stubCalendars: [CalendarInfo] = []
        var callCount = 0
        var holdNextCall = false
        var isWaitingForRelease = false
        var releaseRequested = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let availableCalendarsLock = NSLock()
    private var availableCalendarsState = AvailableCalendarsState()

    nonisolated(unsafe) var stubPermissionStatus: CalendarService.PermissionStatus = .notDetermined
    nonisolated(unsafe) var requestPermissionResult: Bool = true
    nonisolated(unsafe) var stubEvents: [CalendarEvent] = []
    nonisolated(unsafe) var stubFetchError: Error?

    var stubCalendars: [CalendarInfo] {
        get { availableCalendarsLock.withLock { availableCalendarsState.stubCalendars } }
        set { availableCalendarsLock.withLock { availableCalendarsState.stubCalendars = newValue } }
    }

    nonisolated(unsafe) private(set) var requestPermissionCallCount = 0
    nonisolated(unsafe) private(set) var fetchUpcomingEventsCallCount = 0
    var availableCalendarsCallCount: Int {
        availableCalendarsLock.withLock { availableCalendarsState.callCount }
    }

    /// When set, the *next* fetch parks until `releaseHeldFetch()` is called.
    /// Lets reentrancy tests hold one poll inside its `await` so a second poll
    /// can be issued deterministically (no sleeps).
    nonisolated(unsafe) var holdNextFetch = false
    nonisolated(unsafe) private var fetchContinuation: CheckedContinuation<Void, Never>?
    var holdNextAvailableCalendars: Bool {
        get { availableCalendarsLock.withLock { availableCalendarsState.holdNextCall } }
        set { availableCalendarsLock.withLock { availableCalendarsState.holdNextCall = newValue } }
    }

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
        let (result, shouldHold) = availableCalendarsLock.withLock {
            availableCalendarsState.callCount += 1
            let result = availableCalendarsState.stubCalendars
            let shouldHold = availableCalendarsState.holdNextCall
            if shouldHold {
                availableCalendarsState.holdNextCall = false
                availableCalendarsState.isWaitingForRelease = true
            }
            return (result, shouldHold)
        }

        if shouldHold {
            await withCheckedContinuation { continuation in
                let resumeImmediately = availableCalendarsLock.withLock {
                    if availableCalendarsState.releaseRequested {
                        availableCalendarsState.releaseRequested = false
                        availableCalendarsState.isWaitingForRelease = false
                        return true
                    }
                    availableCalendarsState.continuation = continuation
                    return false
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        }
        return result
    }

    func fetchUpcomingEvents(from: Date, days: Int?) async throws -> [CalendarEvent] {
        fetchUpcomingEventsCallCount += 1
        if holdNextFetch {
            holdNextFetch = false
            await withCheckedContinuation { fetchContinuation = $0 }
        }
        if let stubFetchError {
            throw stubFetchError
        }
        return stubEvents
    }

    /// Resume a fetch parked by `holdNextFetch`.
    func releaseHeldFetch() {
        fetchContinuation?.resume()
        fetchContinuation = nil
    }

    func releaseHeldAvailableCalendars() {
        let continuation: CheckedContinuation<Void, Never>? = availableCalendarsLock.withLock {
            guard availableCalendarsState.isWaitingForRelease else { return nil }
            if let continuation = availableCalendarsState.continuation {
                availableCalendarsState.continuation = nil
                availableCalendarsState.isWaitingForRelease = false
                return continuation
            }
            availableCalendarsState.releaseRequested = true
            return nil
        }
        continuation?.resume()
    }
}
