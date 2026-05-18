import SwiftUI
import MacParakeetViewModels

/// Compact horizontal audio scrubber bar for audio-only playback.
/// Fixed ~44px height with play/pause, scrubber track, and time labels.
struct AudioScrubberBar: View {
    @Bindable var viewModel: MediaPlayerViewModel

    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            // Play/Pause
            Button(action: { viewModel.togglePlayPause() }) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignSystem.Colors.textPrimary)

            // Current time
            Text(formatTime(viewModel.currentTimeMs))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 42, alignment: .trailing)

            // Scrubber track
            GeometryReader { geo in
                let progress = isDragging ? dragProgress : normalizedProgress

                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(DesignSystem.Colors.playbackTrack)
                        .frame(height: 6)

                    // Fill
                    RoundedRectangle(cornerRadius: 3)
                        .fill(DesignSystem.Colors.accent)
                        .frame(width: max(0, geo.size.width * progress), height: 6)

                    // Thumb
                    Circle()
                        .fill(DesignSystem.Colors.accent)
                        .frame(width: 12, height: 12)
                        .offset(x: max(0, geo.size.width * progress - 6))
                }
                .frame(height: 12)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            dragProgress = max(0, min(1, value.location.x / geo.size.width))
                        }
                        .onEnded { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            let targetMs = Int(fraction * Double(viewModel.durationMs))
                            viewModel.seek(toMs: targetMs)
                            isDragging = false
                        }
                )
            }

            // Duration
            Text(formatTime(viewModel.durationMs))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .frame(width: 42, alignment: .leading)

            PlaybackSpeedMenu(viewModel: viewModel)
        }
        .padding(.horizontal, 16)
        .frame(height: DesignSystem.Layout.audioScrubberHeight)
        .background(DesignSystem.Colors.surface)
    }

    private var normalizedProgress: Double {
        guard viewModel.durationMs > 0 else { return 0 }
        return Double(viewModel.currentTimeMs) / Double(viewModel.durationMs)
    }

    private func formatTime(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return String(format: "%d:%02d:%02d", hours, mins, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
