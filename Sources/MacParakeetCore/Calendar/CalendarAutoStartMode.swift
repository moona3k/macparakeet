import Foundation

/// User-facing mode for the calendar-driven meeting feature.
///
/// One enum, three values — keeps reasoning about behavior simple. The
/// reminder lead time and trigger filter are independent settings; this enum
/// only controls *what happens when a matching event fires*.
public enum CalendarAutoStartMode: String, Codable, Sendable, CaseIterable {
    /// No calendar integration. The coordinator is a no-op even if Calendar
    /// permission is granted.
    case off

    /// Show a macOS notification at `T - reminderMinutes`. Recording is not
    /// started automatically.
    case notify

    /// Notify *and* start recording at `T-0` (after a short cancellable
    /// countdown). Phase 2 — see ADR-017.
    case autoStart
}
