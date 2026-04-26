import MacParakeetViewModels
import SwiftUI

/// Compact non-activating toast for calendar-driven auto-start countdowns.
/// Two flavors via `MeetingCountdownToastViewModel.Style`:
///
/// - `.autoStart` → "Standup starts in 5s" + Cancel + Start Now
/// - `.autoStop`  → "Wrap ending — stop recording?" + Keep Recording
///
/// Bound to a `@Bindable` view model so the controller can drive `progress`
/// from a 60Hz timer without re-rendering the whole subtree.
struct MeetingCountdownToastView: View {
    @Bindable var viewModel: MeetingCountdownToastViewModel
    /// Always present — the dismissive action (Cancel / Keep Recording).
    /// Bound to `.escape` and rendered with `.bordered` (less prominent).
    let onDismiss: () -> Void
    /// Optional affirmative action (Start Now). Only present in the
    /// `.autoStart` style; bound to `.return` and rendered with
    /// `.borderedProminent` so it visually reads as the default.
    let onConfirm: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: viewModel.style == .autoStart ? "calendar.badge.clock" : "stop.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.meetingPillText)
                Text(viewModel.title)
                    .font(DesignSystem.Typography.meetingPillStatus)
                    .foregroundStyle(DesignSystem.Colors.meetingPillText)
                    .lineLimit(1)
                Spacer()
            }

            Text(viewModel.body)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.meetingPillText.opacity(0.75))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Rich variant — only present for calendar-triggered auto-start
            // (ADR-020 §10). Carries attendee count + meeting service icon
            // and a steering hint pointing the user at the Notes tab. Manual
            // toasts skip this block entirely.
            if let summary = viewModel.contextSummary, let hint = viewModel.calendarContext?.steeringHint {
                Divider()
                    .opacity(0.3)
                HStack(spacing: 6) {
                    if let service = viewModel.calendarContext?.serviceName {
                        Image(systemName: serviceIconName(for: service))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DesignSystem.Colors.meetingPillText.opacity(0.8))
                            .accessibilityHidden(true)
                    }
                    Text(summary)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(DesignSystem.Colors.meetingPillText.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(hint)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(DesignSystem.Colors.meetingPillText.opacity(0.65))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            progressBar

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button(action: onDismiss) {
                    Text(viewModel.primaryActionLabel)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])

                if let confirmLabel = viewModel.secondaryActionLabel,
                   let onConfirm {
                    Button(action: onConfirm) {
                        Text(confirmLabel)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.meetingPillBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                        .stroke(DesignSystem.Colors.meetingPillStroke, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        )
        .frame(width: viewModel.calendarContext == nil ? 280 : 320)
    }

    /// SF Symbol name for the meeting service. Names match the strings
    /// `MeetingLinkParser.identifyService` returns — keep this list in
    /// sync with that switch (Sources/MacParakeetCore/Calendar/
    /// MeetingLinkParser.swift). Unknown services fall through to a
    /// generic link icon.
    private func serviceIconName(for service: String) -> String {
        switch service {
        case "Zoom", "Google Meet", "Microsoft Teams", "Webex", "Around":
            return "video.fill"
        default:
            return "link"
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignSystem.Colors.meetingPillText.opacity(0.12))
                Capsule()
                    .fill(DesignSystem.Colors.accent)
                    .frame(width: max(0, min(1, viewModel.progress)) * geo.size.width)
                    .animation(.linear(duration: 0.05), value: viewModel.progress)
            }
        }
        .frame(height: 4)
    }
}
