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
                    VideoPlayerView(player: player)
                        .aspectRatio(16/9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
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
        VStack(spacing: DesignSystem.Spacing.md) {
            ProgressView()
                .controlSize(.large)
            Text(loadingMessage)
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16/9, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private var loadingMessage: String {
        let elapsed = Int(playerViewModel.loadingElapsed)
        if elapsed < 3 {
            return "Loading video..."
        } else {
            return "Fetching stream from YouTube... (\(elapsed)s)"
        }
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
