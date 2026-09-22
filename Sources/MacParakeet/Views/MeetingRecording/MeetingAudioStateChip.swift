import MacParakeetCore
import SwiftUI

struct MeetingAudioStateChip: View {
    let state: MeetingAudioFile.State
    @State private var showingUnavailableAudioExplanation = false

    @ViewBuilder
    var body: some View {
        switch state {
        case .saved, .notMeeting:
            EmptyView()
        case .removed:
            Button {
                showingUnavailableAudioExplanation.toggle()
            } label: {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Audio unavailable. Transcript is still available.")
            .accessibilityLabel("Audio unavailable")
            .accessibilityHint("Shows why playback and retranscription are unavailable")
            .popover(isPresented: $showingUnavailableAudioExplanation, arrowEdge: .bottom) {
                Text(
                    "Audio unavailable. The transcript is still available, but playback and retranscription need retained meeting audio."
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .frame(width: 250, alignment: .leading)
                .padding(DesignSystem.Spacing.md)
            }
        case .missing:
            Label("Audio missing", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(background)
                )
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var foreground: Color {
        switch state {
        case .missing:
            return DesignSystem.Colors.warningAmber
        case .saved, .removed, .notMeeting:
            return DesignSystem.Colors.textTertiary
        }
    }

    private var background: Color {
        switch state {
        case .missing:
            return DesignSystem.Colors.warningAmber.opacity(0.12)
        case .saved, .removed, .notMeeting:
            return .clear
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .missing:
            return "Meeting audio file is missing"
        case .saved, .removed, .notMeeting:
            return ""
        }
    }
}
