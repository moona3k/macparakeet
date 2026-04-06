import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

private struct MeetingRecordingCheckmarkView: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(DesignSystem.Typography.meetingPillCheckmark)
            .foregroundStyle(DesignSystem.Colors.successGreen)
    }
}

struct MeetingRecordingPillView: View {
    @Bindable var viewModel: MeetingRecordingPillViewModel
    var onTap: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            pillContent
        }
        .padding(.bottom, DesignSystem.Spacing.md - DesignSystem.Spacing.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onHover { hovering in
            isHovered = hovering
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard case .recording = viewModel.state else { return }
            onTap?()
        }
    }

    @ViewBuilder
    private var pillContent: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
        case .recording:
            recordingPill
        case .transcribing:
            statusPill(
                icon: AnyView(ProgressView().controlSize(.small).tint(.white)),
                title: "Transcribing meeting"
            )
        case .completed:
            statusPill(
                icon: AnyView(MeetingRecordingCheckmarkView()),
                title: "Saved to library"
            )
        case .error(let message):
            statusPill(
                icon: AnyView(
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignSystem.Colors.warningAmber)
                ),
                title: message
            )
        }
    }

    private var recordingPill: some View {
        sacredRecordingPill
    }

    private func statusPill(icon: AnyView, title: String) -> some View {
        HStack(spacing: 10) {
            icon
            Text(title)
                .font(DesignSystem.Typography.meetingPillStatus)
                .foregroundStyle(DesignSystem.Colors.meetingPillText)
                .lineLimit(2)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.md - DesignSystem.Spacing.xs)
        .background(pillBackground)
    }

    private var sacredRecordingPill: some View {
        VStack(spacing: 0) {
            MerkabaPillIcon(
                isAnimating: true,
                audioLevel: max(viewModel.micLevel, viewModel.systemLevel)
            )
        }
        .frame(width: DesignSystem.Layout.meetingPillWidth, height: DesignSystem.Layout.meetingPillHeight)
        .background(
            Capsule()
                .fill(isHovered ? DesignSystem.Colors.meetingPillBackgroundHover : DesignSystem.Colors.meetingPillBackground)
                .overlay(
                    Capsule()
                        .stroke(
                            isHovered ? DesignSystem.Colors.meetingPillStrokeHover : DesignSystem.Colors.meetingPillStroke,
                            lineWidth: 0.5
                        )
                )
                .animation(DesignSystem.Animation.meetingPillHover, value: isHovered)
        )
        .clipShape(Capsule())
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(DesignSystem.Animation.meetingPillHover, value: isHovered)
        .padding(DesignSystem.Spacing.sm)
        .overlay(alignment: .top) {
            if isHovered && viewModel.elapsedSeconds > 0 {
                Text(viewModel.formattedElapsed)
                    .font(DesignSystem.Typography.meetingPillBadge)
                    .foregroundStyle(DesignSystem.Colors.meetingPillText)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, 3)
                    .background(DesignSystem.Colors.meetingPillBadgeBackground)
                    .clipShape(Capsule())
                    .offset(y: -24)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording meeting, \(viewModel.formattedElapsed) elapsed")
    }

    private var pillBackground: some View {
        RoundedRectangle(cornerRadius: 999)
            .fill(DesignSystem.Colors.pillBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 999)
                    .strokeBorder(DesignSystem.Colors.pillBorder, lineWidth: 1)
            )
            .cardShadow(DesignSystem.Shadows.meetingPill)
    }
}
