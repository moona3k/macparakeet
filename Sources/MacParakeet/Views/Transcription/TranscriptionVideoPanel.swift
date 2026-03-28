import AVKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Video panel for the split-pane detail view. Shows AVPlayer, title, channel, and controls.
struct TranscriptionVideoPanel: View {
    let transcription: Transcription
    @Bindable var playerViewModel: MediaPlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch playerViewModel.playerState {
            case .idle:
                EmptyView()

            case .loading:
                loadingState

            case .ready:
                if let player = playerViewModel.player {
                    VStack(spacing: 0) {
                        VideoPlayerView(
                            player: player,
                            subtitleText: playerViewModel.showSubtitles ? playerViewModel.currentSubtitleText : nil
                        )
                        .aspectRatio(16/9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))

                        // CC toggle
                        HStack {
                            Spacer()
                            Button {
                                playerViewModel.showSubtitles.toggle()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: playerViewModel.showSubtitles ? "captions.bubble.fill" : "captions.bubble")
                                        .font(.system(size: 14, weight: .medium))
                                    Text("CC")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(playerViewModel.showSubtitles ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(playerViewModel.showSubtitles ? DesignSystem.Colors.accent.opacity(0.12) : DesignSystem.Colors.surfaceElevated)
                                )
                            }
                            .buttonStyle(.plain)
                            .help(playerViewModel.showSubtitles ? "Hide subtitles" : "Show subtitles")
                        }
                        .padding(.top, 6)
                    }
                }

            case .error(let message):
                errorState(message: message)

            case .unavailableOffline:
                offlineState
            }
        }
        .padding(DesignSystem.Spacing.md)
    }

    // MARK: - States

    private var loadingState: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surface)

            VStack(spacing: DesignSystem.Spacing.lg) {
                SpinnerRingView(size: 36, tintColor: DesignSystem.Colors.accent)

                VStack(spacing: 4) {
                    Text(loadingTitle)
                        .font(DesignSystem.Typography.bodySmall.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)

                    if let subtitle = loadingSubtitle {
                        Text(subtitle)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    }
                }
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
    }

    private var loadingTitle: String {
        let elapsed = Int(playerViewModel.loadingElapsed)
        if elapsed < 3 {
            return "Loading video..."
        } else {
            return "Fetching stream from YouTube..."
        }
    }

    private var loadingSubtitle: String? {
        let elapsed = Int(playerViewModel.loadingElapsed)
        guard elapsed >= 3 else { return nil }
        return "Usually 10–20s, longer on slow connections (\(elapsed)s)"
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(DesignSystem.Colors.warningAmber)
            Text("Video unavailable")
                .font(DesignSystem.Typography.body.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button("Retry") {
                Task {
                    await playerViewModel.load(for: transcription)
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16/9, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private var offlineState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 28))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            Text("Video unavailable offline")
                .font(DesignSystem.Typography.body.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16/9, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

}
