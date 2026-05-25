import SwiftUI

struct BetaBadge: View {
    static let message = "This feature depends on macOS Now Playing support and may vary by media app."

    var body: some View {
        Text("Beta")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(DesignSystem.Colors.accent)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.accent.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .strokeBorder(DesignSystem.Colors.accent.opacity(0.28), lineWidth: 0.5)
            )
            .fixedSize()
            .help(Self.message)
            .accessibilityLabel("Beta")
            .accessibilityHint(Self.message)
    }
}
