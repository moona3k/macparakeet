import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Settings card for selecting speech engines (Phase 2.2.1 redesign).
///
/// Top section: three rich engine tiles for the global default. Tapping
/// a tile sets `speechEnginePreferences.global` and routes any feature
/// configured to "Use default" through that engine.
///
/// Middle section (disclosure-gated): per-feature overrides as pill bars.
/// Hidden by default — most users only set the global default.
///
/// Bottom section: model install status for each engine, with Download
/// affordance for VibeVoice (Parakeet and Whisper have their own
/// first-run paths).
struct SpeechEngineCard: View {
    @Bindable var viewModel: SettingsViewModel

    @State private var perFeatureExpanded: Bool = false

    var body: some View {
        SettingsCard(
            title: "Speech Engines",
            subtitle: "Choose the engine that powers dictation, file transcription, and meetings.",
            icon: "waveform",
            iconTint: DesignSystem.Colors.accent
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                globalTiles
                Divider()
                perFeatureSection
                Divider()
                modelsSection
            }
        }
    }

    // MARK: - Global default tiles

    private var globalTiles: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Pick your default engine")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                parakeetTile
                whisperTile
                vibevoiceTile
            }
        }
    }

    private var parakeetTile: some View {
        EngineOptionTile(
            icon: "bolt.fill",
            name: "Parakeet",
            tagline: "Fastest local engine",
            strengths: [
                "English + 24 European languages",
                "155× realtime on Apple Silicon",
                "Runs on the Neural Engine"
            ],
            helpText: "Best for English and other European languages including Spanish, French, German, and Italian. Runs on the Neural Engine for the lowest latency on Apple Silicon.",
            modelStatus: .notLoaded,
            isSelected: viewModel.globalEngine == .parakeet,
            isBusy: false,
            unavailableReason: nil,
            onSelect: { viewModel.globalEngine = .parakeet }
        )
    }

    private var whisperTile: some View {
        EngineOptionTile(
            icon: "globe",
            name: "Whisper",
            tagline: "Multilingual coverage",
            strengths: [
                "Korean, Japanese, Chinese, Thai +95 more",
                "Auto language detection",
                "Whisper Large v3 Turbo (632 MB)"
            ],
            helpText: "Best for languages outside Parakeet's coverage. Adds Korean, Japanese, Chinese, Thai, Hindi, Arabic, Vietnamese, and 80+ more — any language Whisper supports.",
            modelStatus: .notLoaded,
            isSelected: viewModel.globalEngine == .whisper,
            isBusy: false,
            unavailableReason: nil,
            onSelect: { viewModel.globalEngine = .whisper }
        )
    }

    private var vibevoiceTile: some View {
        EngineOptionTile(
            icon: "waveform.circle",
            name: "VibeVoice",
            tagline: "Diarization-aware",
            strengths: [
                "Native speaker labels",
                "60-minute single-pass context",
                "50+ languages, auto-detected"
            ],
            helpText: "Best for long-form multi-speaker content (meetings, interviews, podcasts) — VibeVoice identifies who said what natively. 9.7 GB model, ~RTF 0.4. Not recommended for dictation due to startup latency.",
            modelStatus: viewModel.isVibeVoiceModelInstalled ? .notLoaded : .notDownloaded,
            isSelected: viewModel.globalEngine == .vibevoice,
            isBusy: false,
            unavailableReason: nil,
            onSelect: { viewModel.globalEngine = .vibevoice }
        )
    }

    // MARK: - Per-feature overrides (disclosure-gated)

    private var perFeatureSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Button(action: { perFeatureExpanded.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: perFeatureExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text("Use specific engines per feature")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }
            }
            .buttonStyle(.plain)

            if perFeatureExpanded {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    EnginePillBar(
                        label: "Dictation",
                        selection: Binding(
                            get: { viewModel.dictationEngineSelection },
                            set: { viewModel.dictationEngineSelection = $0 }
                        )
                    )
                    EnginePillBar(
                        label: "File transcription",
                        selection: Binding(
                            get: { viewModel.fileTranscriptionEngineSelection },
                            set: { viewModel.fileTranscriptionEngineSelection = $0 }
                        )
                    )
                    EnginePillBar(
                        label: "Meeting recording",
                        selection: Binding(
                            get: { viewModel.meetingRecordingEngineSelection },
                            set: { viewModel.meetingRecordingEngineSelection = $0 }
                        )
                    )
                    if let hint = dictationHint {
                        Label(hint, systemImage: "exclamationmark.triangle")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.warningAmber)
                    }
                    if let hint = meetingHint {
                        Label(hint, systemImage: "sparkles")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    // MARK: - Models section

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Engine models")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            EngineModelStatusRow(
                engine: .parakeet,
                isInstalled: true,
                downloadProgress: nil,
                downloadAction: {},
                cancelDownloadAction: nil
            )
            EngineModelStatusRow(
                engine: .whisper,
                isInstalled: true,
                downloadProgress: nil,
                downloadAction: {},
                cancelDownloadAction: nil
            )
            EngineModelStatusRow(
                engine: .vibevoice,
                isInstalled: viewModel.isVibeVoiceModelInstalled,
                downloadProgress: viewModel.vibevoiceDownloadProgress,
                downloadAction: { viewModel.startVibeVoiceDownload() },
                cancelDownloadAction: { viewModel.cancelVibeVoiceDownload() }
            )
        }
    }

    // MARK: - Hints

    private var dictationHint: String? {
        let resolved = viewModel.speechEnginePreferences.engine(for: .dictation)
        if resolved == .vibevoice {
            return "VibeVoice has ~13 s startup latency. Dictation may feel slow."
        }
        return nil
    }

    private var meetingHint: String? {
        let resolved = viewModel.speechEnginePreferences.engine(for: .meetingFinalize)
        if resolved == .vibevoice {
            return "VibeVoice provides native speaker labels."
        }
        return nil
    }
}
