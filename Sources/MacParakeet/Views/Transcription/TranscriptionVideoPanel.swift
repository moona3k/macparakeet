import AVKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Video panel for the split-pane detail view. Shows AVPlayer, title, channel, and controls.
struct TranscriptionVideoPanel: View {
    let transcription: Transcription
    @Bindable var playerViewModel: MediaPlayerViewModel
    var translationViewModel: TranscriptTranslationViewModel
    /// Keep the user's requested language even when source edits reset the
    /// player's active cues. Cleared only by Original or another transcript.
    @State private var requestedSubtitleLanguage: TranslationLanguage?
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
                        if let requested = requestedSubtitleLanguage {
                            subtitleTranslationStatus(for: requested)
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
        .onChange(of: selectedSubtitleTranslation) {
            // A source edit can invalidate the saved row without changing it.
            syncSubtitlesWithTranslations()
        }
        .onChange(of: translationViewModel.currentSourceHash) {
            // Refresh the original fallback too, without launching another job.
            playerViewModel.loadSubtitleCues(from: transcription)
            // loadSubtitleCues clears the displayed cue; refresh it even when paused.
            playerViewModel.showOriginalSubtitles()
            syncSubtitlesWithTranslations()
        }
        .onChange(of: transcription.id) {
            requestedSubtitleLanguage = nil
        }
    }

    // MARK: - Subtitle translation

    private var selectedSubtitleTranslation: TranscriptTranslation? {
        guard let language = requestedSubtitleLanguage else { return nil }
        return translationViewModel.subtitleTranslation(for: language)
    }

    private var subtitleLanguageMenu: some View {
        Menu {
            Button {
                requestedSubtitleLanguage = nil
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
                    if let saved, translationViewModel.isStale(saved) {
                        Text("\(language.displayName) · Out of date")
                    } else if saved != nil {
                        menuItemLabel(
                            "\(language.displayName) · \(language.nativeName)",
                            isSelected: playerViewModel.subtitleLanguage == language
                        )
                    } else {
                        Text("Translate to \(language.displayName) · \(language.nativeName)")
                    }
                }
                .disabled(
                    saved.map { !$0.hasTimedSegments && !translationViewModel.isStale($0) }
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
                HStack {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") { translationViewModel.translate(to: language) }
                        .parakeetAction(.secondary)
                        .controlSize(.small)
                        .disabled(!translationViewModel.canTranslate)
                }
                .padding(.top, 4)
            } else {
                ProgressView(value: job.fractionCompleted) {
                    Text("Translating subtitles to \(language.displayName)…")
                        .font(.caption)
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        } else if let saved = translationViewModel.translation(for: language),
            translationViewModel.isStale(saved)
        {
            HStack {
                Text("\(language.displayName) subtitles are out of date. Showing the original.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Re-translate") { translationViewModel.translate(to: language) }
                    .parakeetAction(.secondary)
                    .controlSize(.small)
                    .disabled(!translationViewModel.canTranslate)
            }
            .padding(.top, 4)
        }
    }

    /// Applies the "translate video subtitles automatically" setting once the
    /// player is ready. Only timed transcripts can be shown as subtitles.
    private func autoTranslateSubtitlesIfNeeded() {
        guard autoTranslate,
            playerViewModel.playerState == .ready,
            playerViewModel.subtitleLanguage == nil,
            requestedSubtitleLanguage == nil,
            transcription.hasWordTimestamps,
            !transcription.isTranscriptEdited,
            let language = TranslationLanguage.resolve(configuredLanguageCode)
        else { return }
        selectSubtitleLanguage(language, startIfMissing: translationViewModel.canTranslate)
    }

    /// Show `language` on the video, generating the translation first when it
    /// does not exist yet.
    private func selectSubtitleLanguage(_ language: TranslationLanguage, startIfMissing: Bool) {
        let saved = translationViewModel.translation(for: language)
        guard saved != nil || startIfMissing else { return }
        requestedSubtitleLanguage = language
        playerViewModel.showSubtitles = true
        syncSubtitlesWithTranslations()
        if saved == nil, startIfMissing {
            translationViewModel.translate(to: language)
        }
    }

    private func syncSubtitlesWithTranslations() {
        guard let requested = requestedSubtitleLanguage else { return }
        // Passive reconciliation preserves the CC toggle and never makes a request.
        if let saved = translationViewModel.subtitleTranslation(for: requested) {
            playerViewModel.showTranslatedSubtitles(saved.segments, language: requested)
        } else {
            playerViewModel.showOriginalSubtitles()
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
        switch playerViewModel.videoPreparationStage {
        case .downloading:
            return "Downloading video..."
        case .combining:
            return "Preparing video..."
        case .extracting:
            break
        }
        let elapsed = Int(playerViewModel.loadingElapsed)
        if elapsed < 3 {
            return "Loading video..."
        } else {
            return "Fetching video stream..."
        }
    }

    private var loadingSubtitle: String? {
        let elapsed = Int(playerViewModel.loadingElapsed)
        if playerViewModel.videoPreparationStage != .extracting {
            return "Preparing playback may take a few minutes (\(elapsed)s)"
        }
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
