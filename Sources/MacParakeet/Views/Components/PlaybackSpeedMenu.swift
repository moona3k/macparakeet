import SwiftUI
import MacParakeetViewModels

struct PlaybackSpeedMenu: View {
    @Bindable var viewModel: MediaPlayerViewModel

    var body: some View {
        Menu {
            ForEach(PlaybackRate.options, id: \.self) { rate in
                Button {
                    viewModel.setPlaybackRate(rate)
                } label: {
                    HStack {
                        Text(PlaybackRate.label(for: rate))
                        if isSelected(rate) {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .medium))
                Text(viewModel.playbackRateLabel)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 28, alignment: .leading)
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.surfaceElevated)
            )
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed")
        .accessibilityLabel("Playback speed")
        .accessibilityValue(viewModel.playbackRateLabel)
    }

    private func isSelected(_ rate: Float) -> Bool {
        abs(viewModel.playbackRate - rate) < 0.001
    }
}
