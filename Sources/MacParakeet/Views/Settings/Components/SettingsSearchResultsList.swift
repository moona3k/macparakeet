import SwiftUI
import MacParakeetViewModels

/// Flat list of search-result rows shown in place of the tabbed content
/// when the Settings search field has a non-empty query. Each row taps
/// through to its tab + scrolls to the card anchor; the tab bar at the
/// top stays visible so the user always has a way out of search.
///
/// Empty-query state is the parent's problem — this view never renders
/// for an empty query (the parent only mounts it when `isSearching`).
struct SettingsSearchResultsList: View {
    let results: [SettingsSearchEntry]
    /// Tapping a result yields its entry to the parent so the parent
    /// can update `activeTab`, clear the search field, and trigger the
    /// scroll target. Keeping the navigation policy out of this view
    /// means the row is just a button.
    let onSelect: (SettingsSearchEntry) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                if results.isEmpty {
                    SettingsEmptyState(
                        icon: "magnifyingglass",
                        title: "No matches",
                        message: "Try a different keyword. Search covers titles, descriptions, and synonyms across every tab."
                    )
                    .padding(.top, DesignSystem.Spacing.xl)
                } else {
                    Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, DesignSystem.Spacing.xs)
                        .accessibilityLabel("\(results.count) results")

                    ForEach(results) { entry in
                        SettingsSearchResultRow(entry: entry) {
                            onSelect(entry)
                        }
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }
}

/// One result row. Card-style affordance with hover lift, breadcrumb
/// subtitle ("in {Card}"), and a faint tab badge so the user can see
/// where they're about to land before they click.
private struct SettingsSearchResultRow: View {
    let entry: SettingsSearchEntry
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(DesignSystem.Typography.body.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(entry.subtitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                tabBadge

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(isHovered ? DesignSystem.Colors.surfaceElevated : DesignSystem.Colors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(
                        isHovered ? DesignSystem.Colors.accent.opacity(0.3) : DesignSystem.Colors.border.opacity(0.5),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("\(entry.title), \(entry.subtitle), in \(SettingsTabMetadata.for(entry.tab).title) tab")
        .accessibilityHint("Opens the \(SettingsTabMetadata.for(entry.tab).title) tab")
    }

    private var tabBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: SettingsTabMetadata.for(entry.tab).systemImage)
                .font(.system(size: 10, weight: .medium))
            Text(SettingsTabMetadata.for(entry.tab).title)
                .font(DesignSystem.Typography.micro.weight(.medium))
        }
        .foregroundStyle(DesignSystem.Colors.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(DesignSystem.Colors.surfaceElevated)
        )
        .accessibilityHidden(true)
    }
}

#Preview("Many results", traits: .fixedLayout(width: 720, height: 540)) {
    SettingsSearchResultsList(
        results: SettingsSearchIndex.matches("microphone")
    ) { _ in }
        .background(DesignSystem.Colors.background)
        .preferredColorScheme(.light)
}

#Preview("No matches — dark", traits: .fixedLayout(width: 720, height: 540)) {
    SettingsSearchResultsList(results: []) { _ in }
        .background(DesignSystem.Colors.background)
        .preferredColorScheme(.dark)
}
