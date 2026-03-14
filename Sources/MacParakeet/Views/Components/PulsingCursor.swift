import SwiftUI

struct PulsingCursor: View {
    @State private var isVisible = true

    var body: some View {
        Text("|")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(DesignSystem.Colors.accent)
            .opacity(isVisible ? 1.0 : 0.2)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isVisible)
            .onAppear { isVisible = false }
    }
}
