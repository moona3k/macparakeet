import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

private struct MeetingRecordingCheckmarkView: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(DesignSystem.Colors.successGreen)
    }
}

private struct PulsingRecordDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(DesignSystem.Colors.recordingRed)
            .frame(width: 10, height: 10)
            .shadow(color: DesignSystem.Colors.recordingRed.opacity(0.6), radius: pulse ? 8 : 2)
            .scaleEffect(pulse ? 1.05 : 0.92)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

private struct MeetingAudioMeterGroup: View {
    let systemName: String
    let level: Float

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemName)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.white.opacity(0.45))

            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barColor(for: index))
                        .frame(width: 3, height: 12)
                        .scaleEffect(y: barScale(for: index), anchor: .bottom)
                        .animation(.easeInOut(duration: 0.1), value: level)
                }
            }
        }
    }

    private func barScale(for index: Int) -> CGFloat {
        let threshold = CGFloat(index) / 5
        let clamped = CGFloat(max(0, min(1, level)))
        return max(0.18, min(1, (clamped - threshold * 0.5) * 1.5))
    }

    private func barColor(for index: Int) -> Color {
        let threshold = CGFloat(index) / 5
        let active = CGFloat(level) > threshold * 0.7
        return active ? DesignSystem.Colors.accent : Color.white.opacity(0.18)
    }
}

struct MeetingRecordingPillView: View {
    @Bindable var viewModel: MeetingRecordingPillViewModel

    var body: some View {
        VStack(spacing: 0) {
            pillContent
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
        HStack(spacing: 14) {
            PulsingRecordDot()

            Text(viewModel.formattedElapsed)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 42, alignment: .leading)

            MeetingAudioMeterGroup(systemName: "mic.fill", level: viewModel.micLevel)
            MeetingAudioMeterGroup(systemName: "speaker.wave.2.fill", level: viewModel.systemLevel)

            Button(action: { viewModel.onStop?() }) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .padding(8)
                    .background(
                        Circle()
                            .fill(DesignSystem.Colors.recordingRed.opacity(0.92))
                            .shadow(color: DesignSystem.Colors.recordingRed.opacity(0.45), radius: 6)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop meeting recording")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(pillBackground)
    }

    private func statusPill(icon: AnyView, title: String) -> some View {
        HStack(spacing: 10) {
            icon
            Text(title)
                .font(DesignSystem.Typography.bodySmall.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(pillBackground)
    }

    private var pillBackground: some View {
        Capsule()
            .fill(DesignSystem.Colors.pillBackground)
            .overlay(
                Capsule()
                    .strokeBorder(DesignSystem.Colors.pillBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
    }
}
