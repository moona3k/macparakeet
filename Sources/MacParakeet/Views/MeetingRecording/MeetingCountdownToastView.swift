import MacParakeetViewModels
import SwiftUI

/// Compact "countdown halo" toast for meeting automation. The
/// sacred-geometry rosette (shared with the recording pill via
/// `MerkabaPillIcon`) sits inside a coral ring that sweeps over the countdown —
/// the ring *is* the timer, so there's no separate progress bar. Lives top-right
/// (ADR-017 / ADR-020 §10, reused by ADR-023).
struct MeetingCountdownToastView: View {
    @Bindable var viewModel: MeetingCountdownToastViewModel
    /// Dismissive action — Cancel. Bound to `.escape`.
    let onDismiss: () -> Void
    /// Affirmative auto-start action. Bound to `.return` only for auto-start to
    /// avoid making auto-stop easier to accept accidentally.
    let onConfirm: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One short status line under the title. Kept deliberately terse — the
    /// rosette + ring already carry "counting down".
    private var subtitle: String {
        if viewModel.kind == .autoStop {
            return "Stopping soon · Keep recording"
        }
        if let service = viewModel.calendarContext?.serviceName {
            return "Auto-recording · \(service)"
        }
        return "Auto-recording"
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            halo

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.title)
                    .font(DesignSystem.Typography.meetingPillStatus)
                    .foregroundStyle(DesignSystem.Colors.meetingPillText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.meetingPillText.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            // Bare ✕ — minimal cancel. "Cancel auto-start" via accessibility.
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.meetingPillText.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel(viewModel.kind == .autoStop ? "Keep recording" : "Cancel auto-start")
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm + 2)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.meetingPillBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                        .stroke(DesignSystem.Colors.meetingPillStroke, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        )
        .background(returnShortcut)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// Rosette wrapped in the countdown ring. The track is a faint full circle;
    /// the coral arc trims from 0 → `progress` and fills as the countdown
    /// completes (full ring = recording starts).
    private var halo: some View {
        ZStack {
            Circle()
                .stroke(DesignSystem.Colors.meetingPillText.opacity(0.12), lineWidth: 2.5)

            // `progress` is driven at 60Hz by the controller, so the ring is
            // already smooth — no per-update `.animation` (it would just stack
            // redundant 50ms interpolations on a value that changes every ~16ms).
            Circle()
                .trim(from: 0, to: max(0, min(1, viewModel.progress)))
                .stroke(DesignSystem.Colors.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            MerkabaPillIcon(
                isAnimating: !reduceMotion,
                audioLevel: 0,
                showStem: false
            )
            .frame(width: 30, height: 30)
        }
        .frame(width: 46, height: 46)
    }

    private var returnShortcut: some View {
        Group {
            if viewModel.kind == .autoStart {
                Button("", action: onConfirm)
                    .keyboardShortcut(.return, modifiers: [])
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var accessibilityLabel: String {
        switch viewModel.kind {
        case .autoStart:
            return "\(viewModel.title). \(subtitle). Starting automatically."
        case .autoStop:
            return "\(viewModel.title). \(subtitle). Stopping automatically."
        }
    }
}
