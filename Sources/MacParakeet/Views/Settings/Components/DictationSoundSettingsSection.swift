import SwiftUI
import UniformTypeIdentifiers
import MacParakeetCore

@MainActor
struct DictationSoundSettingsSection: View {
    let controller: DictationSoundController
    @State private var choosingFor: DictationSoundCue = .start
    @State private var showingImporter = false
    @State private var pendingImport: PendingImport?
    @State private var importError: String?
    @State private var previewNotice: String?

    private struct PendingImport: Identifiable {
        let id = UUID()
        let cue: DictationSoundCue
        let url: URL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            ForEach(DictationSoundCue.allCases, id: \.self) { cue in
                if cue == .stop { Divider() }
                soundRow(cue)
            }
            Text("WAV, AIFF, MP3, M4A, or CAF; up to 5 MB and 5 seconds. Imported files are copied into MacParakeet.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let previewNotice {
                Text(previewNotice)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: DictationSoundConfiguration.supportedExtensions.sorted().compactMap {
                UTType(filenameExtension: $0)
            }
        ) { result in
            switch result {
            case .success(let url): pendingImport = PendingImport(cue: choosingFor, url: url)
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .task(id: pendingImport?.id) {
            guard let request = pendingImport else { return }
            do {
                try await controller.importSound(from: request.url, for: request.cue)
                previewNotice = nil
            } catch is CancellationError {
                // Navigating away cancels import and preserves the old sound.
            } catch {
                importError = error.localizedDescription
            }
            if pendingImport?.id == request.id { pendingImport = nil }
        }
        .alert(
            "Could not import sound",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Choose another audio file.")
        }
        .onDisappear { controller.stopPreview() }
    }

    private func soundRow(_ cue: DictationSoundCue) -> some View {
        let value = controller.configuration(for: cue)
        let isImporting = controller.importing.contains(cue)
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text(cue.title).font(DesignSystem.Typography.body)
                Spacer(minLength: DesignSystem.Spacing.sm)
                Picker(
                    cue.title,
                    selection: Binding(
                        get: { controller.configuration(for: cue).style },
                        set: {
                            controller.setStyle($0, for: cue); previewNotice = nil
                        }
                    )
                ) {
                    ForEach(DictationSoundStyle.allCases, id: \.self) { style in
                        if style != .custom || value.customFileName != nil {
                            Text(style == .system ? "macOS · \(cue.systemSoundName)" : style.title).tag(style)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)
                .accessibilityLabel(cue.title)
                Button {
                    switch controller.preview(cue) {
                    case .played: previewNotice = nil
                    case .mutedBySystem:
                        previewNotice =
                            "Sound effects are disabled in macOS. Enable them in System Settings → Sound to hear previews and dictation cues."
                    case .silent:
                        previewNotice = "This cue is silent. Choose a sound and increase its volume to preview it."
                    case .captureCuePlaying:
                        previewNotice = "A dictation cue is playing. Preview again after it finishes."
                    case .unavailable: previewNotice = "This sound could not be played. Choose another sound."
                    }
                } label: {
                    Image(systemName: "play.fill")
                }
                .parakeetAction(.secondary)
                .accessibilityLabel("Preview \(cue.title.lowercased())")
                .help("Preview \(cue.title.lowercased())")
                .disabled(value.style == .silent || value.volume == 0)
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "speaker.wave.1")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(
                    value: Binding(
                        get: { controller.configuration(for: cue).volume },
                        set: { controller.setVolume($0, for: cue) }
                    ), in: 0...1, step: 0.01
                )
                .accessibilityLabel("\(cue.title) volume")
                .accessibilityValue("\(Int((value.volume * 100).rounded())) percent")
                .disabled(value.style == .silent)
                Text("\(Int((value.volume * 100).rounded()))%")
                    .font(DesignSystem.Typography.caption)
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button(value.customFileName == nil ? "Import sound…" : "Replace custom sound…") {
                    choosingFor = cue
                    showingImporter = true
                }
                .parakeetAction(.secondary)
                .accessibilityLabel("Import \(cue.title.lowercased())")
                if isImporting { ProgressView().controlSize(.small) }
                Spacer(minLength: DesignSystem.Spacing.sm)
                Button("Reset") {
                    Task { await controller.reset(cue) }
                    previewNotice = nil
                }
                .parakeetAction(.subtle)
                .disabled(value == DictationSoundConfiguration())
                .accessibilityLabel("Reset \(cue.title.lowercased())")
                .help("Restore \(cue.systemSoundName) at 40% and remove this imported sound.")
            }
            if value.style == .custom, let name = value.customDisplayName {
                Text(name)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name)
            }
            if let warning = controller.warnings[cue] {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!controller.importing.isEmpty)
    }
}
