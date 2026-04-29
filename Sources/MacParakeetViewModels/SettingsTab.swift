import Foundation

/// Top-level Settings information architecture.
///
/// The four-tab IA decomposes a previously single-scroll Settings panel into
/// destination-shaped buckets. Order is `Modes / Engine / AI / System` —
/// daily-ops first, infrastructure-toward-the-back. See
/// `plans/active/2026-04-settings-ia-overhaul.md` for the IA rationale.
public enum SettingsTab: String, CaseIterable, Codable, Sendable, Identifiable {
    case modes
    case engine
    case ai
    case system

    public var id: String { rawValue }

    /// The default tab shown on first launch and when no last-viewed tab is
    /// persisted. Modes is the daily-ops surface; users return there most often.
    public static let `default`: SettingsTab = .modes
}
