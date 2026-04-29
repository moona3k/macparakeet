import SwiftUI

/// Stop button with inline confirmation.
/// First click asks for confirmation; second click within 3 seconds stops.
struct StopRecordingButton: View {
    var onStop: () -> Void

    @State private var isHovered = false
    @State private var confirming = false
    @State private var countdownProgress: CGFloat = 1.0
    @State private var revertTask: Task<Void, Never>?

    var body: some View {
        Group {
            if confirming {
                Button {
                    revertTask?.cancel()
                    confirming = false
                    onStop()
                } label: {
                    Text("Click to end")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.errorRed)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.surfaceElevated)
                                .overlay(
                                    GeometryReader { geo in
                                        Capsule()
                                            .fill(DesignSystem.Colors.errorRed.opacity(0.2))
                                            .frame(width: geo.size.width * countdownProgress)
                                    }
                                    .clipShape(Capsule())
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(DesignSystem.Colors.errorRed.opacity(0.3), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Confirm ending recording")
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                Button {
                    beginConfirmation()
                } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? DesignSystem.Colors.errorRed : DesignSystem.Colors.textTertiary.opacity(0.6))
                        .frame(width: 13, height: 13)
                        .padding(9)
                        .background(
                            Circle()
                                .fill(isHovered
                                    ? DesignSystem.Colors.errorRed.opacity(0.15)
                                    : DesignSystem.Colors.surfaceElevated
                                )
                                .overlay(
                                    Circle()
                                        .stroke(
                                            isHovered ? DesignSystem.Colors.errorRed.opacity(0.3) : .clear,
                                            lineWidth: 0.5
                                        )
                                )
                        )
                        .shadow(color: isHovered ? DesignSystem.Colors.errorRed.opacity(0.25) : .clear, radius: 6)
                        .scaleEffect(isHovered ? 1.08 : 1.0)
                        .animation(.easeOut(duration: 0.15), value: isHovered)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End recording")
                .onHover { hovering in
                    isHovered = hovering
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .help(confirming ? "Click to confirm" : "End recording")
        .onDisappear { revertTask?.cancel() }
    }

    private func beginConfirmation() {
        countdownProgress = 1.0
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            confirming = true
        }
        withAnimation(.linear(duration: 3)) {
            countdownProgress = 0
        }
        revertTask?.cancel()
        revertTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                confirming = false
            }
        }
    }
}
