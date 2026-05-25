import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// The Speech Engines settings card (Phase 2.2). Replaces the legacy
/// single Parakeet/Whisper picker with one global-default selector plus
/// three per-feature overrides (dictation, file transcription, meeting
/// recording) and an Engine Models section showing install status with
/// download affordances for VibeVoice.
///
/// All state comes from `SettingsViewModel.speechEnginePreferences` and
/// related fields. The card is bound to the view model directly via
/// `@Bindable`.
struct SpeechEngineCard: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        SettingsCard(
            title: "Speech Engines",
            subtitle: "Pick a default engine and optionally override per feature.",
            icon: "waveform",
            iconTint: DesignSystem.Colors.accent
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                globalSection
                Divider()
                featurePicker(
                    label: "Dictation",
                    selection: Binding(
                        get: { viewModel.dictationEngineSelection },
                        set: { viewModel.dictationEngineSelection = $0 }
                    ),
                    hint: dictationHint
                )
                featurePicker(
                    label: "File transcription",
                    selection: Binding(
                        get: { viewModel.fileTranscriptionEngineSelection },
                        set: { viewModel.fileTranscriptionEngineSelection = $0 }
                    ),
                    hint: nil
                )
                featurePicker(
                    label: "Meeting recording",
                    selection: Binding(
                        get: { viewModel.meetingRecordingEngineSelection },
                        set: { viewModel.meetingRecordingEngineSelection = $0 }
                    ),
                    hint: meetingHint
                )
                Divider()
                modelsSection
            }
        }
    }

    // MARK: - Sections

    private var globalSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Default engine")
                    .font(DesignSystem.Typography.body)
                Text("Used when a feature below is set to \"Use default\".")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            Picker("", selection: Binding(
                get: { viewModel.globalEngine },
                set: { viewModel.globalEngine = $0 }
            )) {
                ForEach(SpeechEnginePreference.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 180)
        }
    }

    private func featurePicker(
        label: String,
        selection: Binding<FeatureEngineSelection>,
        hint: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(DesignSystem.Typography.body)
                Spacer()
                Picker("", selection: selection) {
                    Text("Use default").tag(FeatureEngineSelection.global)
                    ForEach(SpeechEnginePreference.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(FeatureEngineSelection.specific(engine))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }
            if let hint {
                Text(hint)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Engine models")
                .font(DesignSystem.Typography.body)
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
