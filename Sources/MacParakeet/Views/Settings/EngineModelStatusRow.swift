import SwiftUI
import MacParakeetCore

/// A single row in the Speech Engines model-status section. Shows one
/// engine's installation status with an optional download button or
/// progress indicator.
///
/// Stateless: all rendering is driven by parameters. `SpeechEngineCard`
/// (Task 13) supplies the actual install/progress state from
/// `SettingsViewModel`.
struct EngineModelStatusRow: View {
    let engine: SpeechEnginePreference
    let isInstalled: Bool
    /// 0.0-1.0 when a download is in progress; nil otherwise.
    let downloadProgress: Double?
    let downloadAction: () -> Void
    let cancelDownloadAction: (() -> Void)?

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            engineIcon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.displayName)
                    .font(DesignSystem.Typography.body)
                statusLine
            }
            Spacer()
            if downloadProgress != nil {
                Button("Cancel") { cancelDownloadAction?() }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            } else if !isInstalled, needsDownloadButton {
                Button("Download") { downloadAction() }
                    .parakeetAction(.secondary)
            }
        }
    }

    @ViewBuilder
    private var engineIcon: some View {
        Image(systemName: iconName)
            .foregroundStyle(DesignSystem.Colors.accent.opacity(0.7))
    }

    private var iconName: String {
        switch engine {
        case .parakeet: return "bird"
        case .whisper: return "globe"
        case .vibevoice: return "waveform.circle"
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let progress = downloadProgress {
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                Text("\(Int(progress * 100))%")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(isInstalled ? "Installed" : missingText)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var missingText: String {
        switch engine {
        case .vibevoice: return "9.7 GB needed"
        case .whisper:   return "Not installed"
        case .parakeet:  return "Not installed"
        }
    }

    /// Phase 2.2 only adds an in-Settings download for VibeVoice; Parakeet
    /// and Whisper have existing first-run paths that handle their installs.
    private var needsDownloadButton: Bool {
        engine == .vibevoice
    }
}
