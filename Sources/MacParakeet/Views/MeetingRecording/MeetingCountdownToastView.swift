import MacParakeetViewModels
import SwiftUI

/// Compact "countdown halo" toast for calendar-driven **auto-start**. The
/// sacred-geometry rosette (shared with the recording pill via
/// `MerkabaPillIcon`) sits inside a coral ring that sweeps over the countdown —
/// the ring *is* the timer, so there's no separate progress bar. Minimal text:
/// the meeting title plus one status line. Lives top-right (ADR-017 / ADR-020 §10).
///
/// `✕` cancels this auto-start; `↵` starts now. If left alone, the ring fills
/// and recording starts automatically. (Auto-*stop* was removed — see the
/// ADR-017 amendment — so there is no stop variant of this toast.)
struct MeetingCountdownToastView: View {
    @Bindable var viewModel: MeetingCountdownToastViewModel
    /// Dismissive action — Cancel. Bound to `.escape`.
    let onDismiss: () -> Void
    /// Affirmative action — Start Now. Bound to `.return` via a hidden shortcut.
    let onConfirm: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One short status line under the title. Kept deliberately terse — the
    /// rosette + ring already carry "recording" and "counting down".
    private var subtitle: String {
        if let service = viewModel.calendarContext?.serviceName {
            return "Recording · \(service)"
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
            .accessibilityLabel("Cancel auto-start")
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
        // Hidden Return shortcut for "Start Now". Kept out of the visible
        // layout so the toast stays button-free per the design.
        .background(returnShortcut)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(viewModel.title). \(subtitle). Starting automatically."))
    }

    /// Rosette wrapped in the countdown ring. The track is a faint full circle;
    /// the coral arc trims from 0 → `progress` and fills as the countdown
    /// completes (full ring = recording starts).
    private var halo: some View {
        ZStack {
            Circle()
                .stroke(DesignSystem.Colors.meetingPillText.opacity(0.12), lineWidth: 2.5)

            Circle()
                .trim(from: 0, to: max(0, min(1, viewModel.progress)))
                .stroke(DesignSystem.Colors.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.05), value: viewModel.progress)

            MerkabaPillIcon(
                isAnimating: !reduceMotion,
                audioLevel: 0,
                showStem: false
            )
            .frame(width: 30, height: 30)
        }
        .frame(width: 46, height: 46)
    }

    @ViewBuilder
    private var returnShortcut: some View {
        if let onConfirm {
            Button("", action: onConfirm)
                .keyboardShortcut(.return, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
