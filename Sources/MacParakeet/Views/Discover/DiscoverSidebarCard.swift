import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct DiscoverSidebarCard: View {
    let viewModel: DiscoverViewModel
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        if let item = viewModel.sidebarItem {
            Button(action: onTap) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: item.icon.isEmpty ? "sparkles" : item.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.accent)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(DesignSystem.Colors.accent.opacity(0.12))
                        )

                    Text(item.title)
                        .font(DesignSystem.Typography.caption.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }
                .padding(DesignSystem.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .fill(isSelected ? DesignSystem.Colors.accentLight : (isHovered ? DesignSystem.Colors.surfaceElevated : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .strokeBorder(
                            isSelected ? DesignSystem.Colors.accent.opacity(0.4) : .clear,
                            lineWidth: 0.5
                        )
                )
            }
            .buttonStyle(.plain)
            .help(item.body)
            .onHover { hovering in
                withAnimation(DesignSystem.Animation.hoverTransition) {
                    isHovered = hovering
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.bottom, DesignSystem.Spacing.sm)
        }
    }
}
