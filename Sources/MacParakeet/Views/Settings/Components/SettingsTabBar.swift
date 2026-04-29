import SwiftUI
import MacParakeetViewModels

/// Pill-style segmented control for the four Settings tabs.
///
/// Visual model: a rounded-capsule container (`surfaceElevated`) holds four
/// labels; the currently-active tab is rendered as a lifted pill that slides
/// between segments via `matchedGeometryEffect`. Each pill can show a colored
/// status dot when its tab has something the user should attend to (mirrors
/// the per-card `SettingsStatusChip` semantics: `.recommended` = action
/// recommended, `.required` = action required).
///
/// Keyboard: ⌘1–⌘4 navigate to each tab. The shortcut hint is shown via
/// `.help(...)` on hover.
struct SettingsTabBar: View {
    @Binding var activeTab: SettingsTab
    let tabBadges: [SettingsTab: SettingsStatusChip.Status]

    @Namespace private var activePillNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(4)
        .background(
            Capsule()
                .fill(DesignSystem.Colors.surfaceElevated)
        )
        .overlay(
            Capsule()
                .strokeBorder(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings tabs")
    }

    @ViewBuilder
    private func tabButton(for tab: SettingsTab) -> some View {
        let isActive = (tab == activeTab)
        let metadata = SettingsTabMetadata.for(tab)
        let badge = tabBadges[tab]

        Button {
            withAnimation(DesignSystem.Animation.contentSwap) {
                activeTab = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: metadata.systemImage)
                    .font(.system(size: 12, weight: .medium))

                Text(metadata.title)
                    .font(DesignSystem.Typography.bodySmall.weight(.medium))

                if let badge {
                    Circle()
                        .fill(badge.color)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(isActive ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background {
                if isActive {
                    Capsule()
                        .fill(DesignSystem.Colors.cardBackground)
                        .matchedGeometryEffect(id: "activePill", in: activePillNamespace)
                        .cardShadow(DesignSystem.Shadows.cardRest)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(metadata.keyboardShortcut, modifiers: .command)
        .help("\(metadata.title) (⌘\(metadata.shortcutDigit))")
        .accessibilityLabel(accessibilityLabel(for: tab, badge: badge))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func accessibilityLabel(for tab: SettingsTab, badge: SettingsStatusChip.Status?) -> String {
        let base = SettingsTabMetadata.for(tab).title
        guard let badge else { return base }
        switch badge {
        case .ok: return base
        case .recommended: return "\(base), action recommended"
        case .required: return "\(base), action required"
        case .info: return base
        }
    }
}

/// View-target metadata for each `SettingsTab`. Lives here (not in the
/// `MacParakeetViewModels` target) so the ViewModels target stays free of
/// SwiftUI / SF Symbol references.
enum SettingsTabMetadata {
    struct Info {
        let title: String
        let systemImage: String
        let keyboardShortcut: KeyEquivalent
        let shortcutDigit: String
    }

    static func `for`(_ tab: SettingsTab) -> Info {
        switch tab {
        case .modes:
            return Info(title: "Modes", systemImage: "rectangle.3.group", keyboardShortcut: "1", shortcutDigit: "1")
        case .engine:
            return Info(title: "Engine", systemImage: "cpu", keyboardShortcut: "2", shortcutDigit: "2")
        case .ai:
            return Info(title: "AI", systemImage: "sparkles", keyboardShortcut: "3", shortcutDigit: "3")
        case .system:
            return Info(title: "System", systemImage: "gearshape", keyboardShortcut: "4", shortcutDigit: "4")
        }
    }
}

#Preview("Light — clean", traits: .fixedLayout(width: 640, height: 120)) {
    @Previewable @State var tab: SettingsTab = .modes

    return SettingsTabBar(activeTab: $tab, tabBadges: [:])
        .padding()
        .background(DesignSystem.Colors.background)
        .preferredColorScheme(.light)
}

#Preview("Light — mixed badges", traits: .fixedLayout(width: 640, height: 120)) {
    @Previewable @State var tab: SettingsTab = .engine

    return SettingsTabBar(
        activeTab: $tab,
        tabBadges: [
            .modes: .recommended,
            .engine: .required,
            .system: .recommended
        ]
    )
    .padding()
    .background(DesignSystem.Colors.background)
    .preferredColorScheme(.light)
}

#Preview("Dark — mixed badges", traits: .fixedLayout(width: 640, height: 120)) {
    @Previewable @State var tab: SettingsTab = .system

    return SettingsTabBar(
        activeTab: $tab,
        tabBadges: [
            .modes: .recommended,
            .engine: .required
        ]
    )
    .padding()
    .background(DesignSystem.Colors.background)
    .preferredColorScheme(.dark)
}
