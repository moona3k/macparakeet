import Foundation

/// Top-level Settings information architecture.
///
/// The four-tab IA decomposes a previously single-scroll Settings panel into
/// destination-shaped buckets. Order is `Capture / Engine / AI / System` —
/// daily-ops first, infrastructure-toward-the-back. The `capture` case keeps
/// the old raw value so users who last opened the previous Modes tab return to
/// the same daily-ops surface after the rename.
public enum SettingsTab: String, CaseIterable, Codable, Sendable, Identifiable {
    case capture = "modes"
    case engine
    case ai
    case system

    public var id: String { rawValue }

    /// The default tab shown on first launch and when no last-viewed tab is
    /// persisted. Capture is the daily-ops surface; users return there most often.
    public static let `default`: SettingsTab = .capture
}
