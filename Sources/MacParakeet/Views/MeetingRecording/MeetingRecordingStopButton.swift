import SwiftUI

/// Stop button with inline confirmation.
/// First click asks for confirmation; second click within 3 seconds stops.
struct StopRecordingButton: View {
    var onStop: () -> Void

    @State private var isHovered = false
    @State private var confirming = false
    @State private var countdownProgress: CGFloat = 1.0
    @State private var revertTask: Task<Void, Never>?

    // Match the idle circle's outer diameter (13pt square + 9pt padding × 2)
    // so the "End now" pill occupies the same vertical box and the row above
    // the tab bar doesn't reflow when toggling state.
    private static let trackHeight: CGFloat = 31

    var body: some View {
        Group {
            if confirming {
                Button {
                    revertTask?.cancel()
                    confirming = false
                    onStop()
                } label: {
                    Text("End now")
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
        .frame(height: Self.trackHeight)
        .help(confirming ? "End recording now" : "End recording")
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

// MARK: - Pause / Resume Button

/// Pill-shaped pause/resume toggle for the meeting panel header (issue #235).
/// Same vertical footprint as `StopRecordingButton` so pause + stop sit side
/// by side without reflowing the row. Single-click toggle (no countdown
/// confirmation — pausing is recoverable, unlike stop).
struct PauseResumeButton: View {
    var isPaused: Bool
    var onToggle: () -> Void

    @State private var isHovered = false

    private static let trackHeight: CGFloat = 31

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    isHovered
                        ? DesignSystem.Colors.textPrimary
                        : DesignSystem.Colors.textTertiary
                )
                .frame(width: 13, height: 13)
                .padding(9)
                .background(
                    Circle()
                        .fill(isHovered ? DesignSystem.Colors.surfaceElevated : DesignSystem.Colors.surfaceElevated.opacity(0.6))
                        .overlay(
                            Circle()
                                .stroke(
                                    isHovered ? DesignSystem.Colors.border.opacity(0.7) : .clear,
                                    lineWidth: 0.5
                                )
                        )
                )
                .scaleEffect(isHovered ? 1.06 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isHovered)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .frame(height: Self.trackHeight)
        .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
        .help(isPaused ? "Resume recording" : "Pause recording")
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
