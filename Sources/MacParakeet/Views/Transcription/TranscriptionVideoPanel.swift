import AVKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Video panel for the split-pane detail view. Shows AVPlayer, title, channel, and controls.
struct TranscriptionVideoPanel: View {
    let transcription: Transcription
    @Bindable var playerViewModel: MediaPlayerViewModel
    var translationViewModel: TranscriptTranslationViewModel
    /// Language the user asked to see as subtitles while its translation is
    /// still being generated; applied as soon as the translation is saved.
    @State private var pendingSubtitleLanguage: TranslationLanguage?
    @AppStorage(UserDefaultsAppRuntimePreferences.autoTranslateTranscriptsKey) private var autoTranslate = false
    @AppStorage(UserDefaultsAppRuntimePreferences.transcriptTranslationLanguageKey)
    private var configuredLanguageCode = TranslationLanguage.persian.rawValue

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

                        HStack(spacing: 8) {
                            Spacer()

                            PlaybackSpeedMenu(viewModel: playerViewModel)

                            subtitleLanguageMenu

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
                        if let pending = pendingSubtitleLanguage {
                            subtitleTranslationStatus(for: pending)
                        }
                    }
                }

            case .error(let message):
                errorState(message: message)

            case .unavailableOffline:
                offlineState
            }
        }
        .padding(DesignSystem.Spacing.md)
        .onAppear { autoTranslateSubtitlesIfNeeded() }
        .onChange(of: playerViewModel.playerState) { autoTranslateSubtitlesIfNeeded() }
        .onChange(of: translationViewModel.translations) {
            syncSubtitlesWithTranslations()
        }
        .onChange(of: transcription.id) {
            pendingSubtitleLanguage = nil
        }
    }

    // MARK: - Subtitle translation

    private var subtitleLanguageMenu: some View {
        Menu {
            Button {
                pendingSubtitleLanguage = nil
                playerViewModel.showOriginalSubtitles()
            } label: {
                menuItemLabel("Original", isSelected: playerViewModel.subtitleLanguage == nil)
            }
            Divider()
            ForEach(TranslationLanguage.allCases) { language in
                let saved = translationViewModel.translation(for: language)
                Button {
                    selectSubtitleLanguage(language, startIfMissing: true)
                } label: {
                    if saved != nil {
                        menuItemLabel(
                            "\(language.displayName) · \(language.nativeName)",
                            isSelected: playerViewModel.subtitleLanguage == language
                        )
                    } else {
                        Text("Translate to \(language.displayName) · \(language.nativeName)")
                    }
                }
                .disabled(
                    saved.map { !$0.hasTimedSegments }
                        ?? (!translationViewModel.canTranslate || translationViewModel.isTranslating(language))
                )
            }
        } label: {
            Label(playerViewModel.subtitleLanguage?.displayName ?? "Translate", systemImage: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
        .help(
            translationViewModel.canTranslate
                ? "Subtitle language"
                : "Set up an AI provider in Settings to translate subtitles"
        )
    }

    @ViewBuilder
    private func menuItemLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private func subtitleTranslationStatus(for language: TranslationLanguage) -> some View {
        if let job = translationViewModel.job(for: language) {
            if let message = job.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                ProgressView(value: job.fractionCompleted) {
                    Text("Translating subtitles to \(language.displayName)…")
                        .font(.caption)
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
    }

    /// Applies the "translate video subtitles automatically" setting once the
    /// player is ready. Only timed transcripts can be shown as subtitles.
    private func autoTranslateSubtitlesIfNeeded() {
        guard autoTranslate,
              playerViewModel.playerState == .ready,
              playerViewModel.subtitleLanguage == nil,
              pendingSubtitleLanguage == nil,
              transcription.hasWordTimestamps,
              !transcription.isTranscriptEdited,
              let language = TranslationLanguage.resolve(configuredLanguageCode)
        else { return }
        selectSubtitleLanguage(language, startIfMissing: translationViewModel.canTranslate)
    }

    /// Show `language` on the video, generating the translation first when it
    /// does not exist yet.
    private func selectSubtitleLanguage(_ language: TranslationLanguage, startIfMissing: Bool) {
        if let saved = translationViewModel.translation(for: language) {
            pendingSubtitleLanguage = nil
            playerViewModel.showTranslatedSubtitles(saved.segments, language: language)
            playerViewModel.showSubtitles = true
        } else if startIfMissing {
            pendingSubtitleLanguage = language
            translationViewModel.translate(to: language)
        }
    }

    private func syncSubtitlesWithTranslations() {
        if let pending = pendingSubtitleLanguage,
           translationViewModel.translation(for: pending) != nil {
            selectSubtitleLanguage(pending, startIfMissing: false)
        } else if let shown = playerViewModel.subtitleLanguage {
            // Keep the overlay in step with a re-translation or a deletion.
            if let saved = translationViewModel.translation(for: shown) {
                playerViewModel.showTranslatedSubtitles(saved.segments, language: shown)
            } else {
                playerViewModel.showOriginalSubtitles()
            }
        }
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
            return "Fetching video stream..."
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
            .parakeetAction(.secondary)
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
