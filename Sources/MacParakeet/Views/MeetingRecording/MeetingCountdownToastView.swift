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
    let onPrimary: () -> Void
    let onSecondary: (() -> Void)?

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

            progressBar

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button(action: onPrimary) {
                    Text(viewModel.primaryActionLabel)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])

                if let secondaryLabel = viewModel.secondaryActionLabel,
                   let onSecondary {
                    Button(action: onSecondary) {
                        Text(secondaryLabel)
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
        .frame(width: 280)
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
