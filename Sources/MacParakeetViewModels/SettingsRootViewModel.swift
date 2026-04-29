import Foundation

/// Coordinator view-model for the tabbed Settings panel.
///
/// Owns purely-UI state that spans tabs:
/// - `activeTab` — currently visible tab; persisted across launches via
///   UserDefaults so a user who lives in System (e.g. while auditing
///   permissions) returns there on next launch.
/// - `searchQuery` — top-of-panel search text; non-empty switches the panel
///   into flat-results mode.
///
/// Intentionally **does not** own per-tab state. Sub-VMs (`Modes`, `Engine`,
/// `AI`, `System`) will be wired in subsequent commits and addressed by the
/// parent view, not stored here. Keeping this VM small is the explicit
/// remedy for the 1,265-line god-object pattern that motivated the split.
@MainActor
@Observable
public final class SettingsRootViewModel {
    /// UserDefaults key for the last-viewed tab. Scoped to the root VM
    /// because it is a UI-only preference and does not belong in the runtime
    /// preferences contract consumed by Core services.
    public static let lastViewedTabKey = "settings.lastViewedTab"

    public var activeTab: SettingsTab {
        didSet {
            guard activeTab != oldValue else { return }
            defaults.set(activeTab.rawValue, forKey: Self.lastViewedTabKey)
        }
    }

    public var searchQuery: String = ""

    /// `true` when the user has typed something into the search field. The
    /// view collapses the tab layout into flat results in this state.
    /// Trims `.whitespacesAndNewlines` so a pasted newline can't enter
    /// search mode while `SettingsSearchIndex.matches` (which also trims
    /// newlines) returns nothing — that mismatch produces a confusing
    /// "No matches" state for what is effectively an empty query.
    public var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.lastViewedTabKey),
           let restored = SettingsTab(rawValue: raw) {
            self.activeTab = restored
        } else {
            self.activeTab = .default
        }
    }

    /// Clears the search query and returns the panel to the tabbed layout.
    /// Called by the search field's clear button and `Esc` handler.
    public func clearSearch() {
        searchQuery = ""
    }
}
