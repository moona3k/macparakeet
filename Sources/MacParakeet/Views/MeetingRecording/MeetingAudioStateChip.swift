import MacParakeetCore
import SwiftUI

struct MeetingAudioStateChip: View {
    let state: MeetingAudioFile.State

    var body: some View {
        Label(title, systemImage: systemImage)
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

    private var title: String {
        switch state {
        case .saved:
            return "Audio saved"
        case .removed:
            return "Audio removed"
        case .missing:
            return "Audio missing"
        case .notMeeting:
            return ""
        }
    }

    private var systemImage: String {
        switch state {
        case .saved:
            return "waveform"
        case .removed:
            return "waveform.slash"
        case .missing:
            return "exclamationmark.triangle"
        case .notMeeting:
            return "waveform"
        }
    }

    private var foreground: Color {
        switch state {
        case .saved:
            return DesignSystem.Colors.textTertiary
        case .removed:
            return DesignSystem.Colors.textSecondary
        case .missing:
            return DesignSystem.Colors.warningAmber
        case .notMeeting:
            return DesignSystem.Colors.textTertiary
        }
    }

    private var background: Color {
        switch state {
        case .saved:
            return DesignSystem.Colors.surfaceElevated.opacity(0.65)
        case .removed:
            return DesignSystem.Colors.surfaceElevated.opacity(0.9)
        case .missing:
            return DesignSystem.Colors.warningAmber.opacity(0.12)
        case .notMeeting:
            return .clear
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .saved:
            return "Meeting audio is saved"
        case .removed:
            return "Meeting audio has been removed"
        case .missing:
            return "Meeting audio file is missing"
        case .notMeeting:
            return ""
        }
    }
}
