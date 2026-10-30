import Foundation

/// One Transform row for the menu-bar submenu. Pure data so AppKit can
/// render titles and shortcut glyphs without talking to the database.
public struct MenuBarTransformListing: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let shortcut: KeyboardShortcut?

    public init(id: UUID, name: String, shortcut: KeyboardShortcut?) {
        self.id = id
        self.name = name
        self.shortcut = shortcut
    }
}

/// Filters and orders visible Transform prompts for the status-item menu.
public enum MenuBarTransformCatalog: Sendable {
    public static func listings(
        from prompts: [Prompt],
        hiddenIDs: Set<UUID>
    ) -> [MenuBarTransformListing] {
        prompts
            .filter { $0.category == .transform && $0.isVisible && !hiddenIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map { MenuBarTransformListing(id: $0.id, name: $0.name, shortcut: $0.shortcut) }
    }
}
