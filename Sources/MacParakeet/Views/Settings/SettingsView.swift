import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    @State private var showClearAllAlert = false
    @State private var showClearYouTubeAudioAlert = false

    var body: some View {
        Form {
            // EARLY ACCESS BYPASS: License section hidden while the app is free.
            // To re-enable, restore the License Section UI from git history.
            // The full licensing code (EntitlementsService, LemonSqueezy API, Keychain
            // storage) remains intact and ready to re-enable.
            Section("General") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Menu bar only mode", isOn: $viewModel.menuBarOnlyMode)
                    Text("Hide the Dock icon and run from the menu bar only.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // Dictation
            Section("Dictation") {
                Picker("Hotkey", selection: $viewModel.hotkeyTrigger) {
                    ForEach(TriggerKey.allCases, id: \.rawValue) { key in
                        Text("\(key.shortSymbol) \(key.displayName)").tag(key.rawValue)
                    }
                }

                Toggle("Auto-stop after silence", isOn: $viewModel.silenceAutoStop)

                if viewModel.silenceAutoStop {
                    Picker("Silence delay", selection: $viewModel.silenceDelay) {
                        Text("1 sec").tag(1.0)
                        Text("1.5 sec").tag(1.5)
                        Text("2 sec").tag(2.0)
                        Text("3 sec").tag(3.0)
                        Text("5 sec").tag(5.0)
                    }
                }
            }

            // Storage
            Section("Storage") {
                Toggle("Save audio recordings", isOn: $viewModel.saveAudioRecordings)

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Keep downloaded YouTube audio", isOn: $viewModel.saveTranscriptionAudio)
                    Text("Enabled by default. Turn off to auto-delete downloaded YouTube audio after transcription.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Auto-update YouTube engine", isOn: $viewModel.autoUpdateYouTubeEngine)
                    Text("Enabled by default. Checks weekly and updates the YouTube download engine in the background.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack {
                    Text("Dictations")
                    Spacer()
                    Text("\(viewModel.dictationCount) \(viewModel.dictationCount == 1 ? "dictation" : "dictations")")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("YouTube downloads")
                    Spacer()
                    Text("\(viewModel.youtubeDownloadCount) file\(viewModel.youtubeDownloadCount == 1 ? "" : "s") \u{2022} \(viewModel.youtubeDownloadStorageMB, specifier: "%.1f") MB")
                        .foregroundStyle(.secondary)
                }

                Button("Clear All Dictations...", role: .destructive) {
                    showClearAllAlert = true
                }
                .alert("Clear All Dictations?", isPresented: $showClearAllAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear All", role: .destructive) {
                        viewModel.clearAllDictations()
                    }
                } message: {
                    Text("This will permanently delete all \(viewModel.dictationCount) dictation\(viewModel.dictationCount == 1 ? "" : "s") and their audio files. This cannot be undone.")
                }

                Button("Clear Downloaded YouTube Audio...", role: .destructive) {
                    showClearYouTubeAudioAlert = true
                }
                .alert("Clear Downloaded YouTube Audio?", isPresented: $showClearYouTubeAudioAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear Audio", role: .destructive) {
                        viewModel.clearDownloadedYouTubeAudio()
                    }
                } message: {
                    Text("This will permanently delete all downloaded YouTube audio files and detach them from existing transcriptions.")
                }
            }

            Section("Onboarding") {
                Button("Run Onboarding Again...") {
                    NotificationCenter.default.post(name: .macParakeetOpenOnboarding, object: nil)
                }
            }

            // Permissions
            Section("Permissions") {
                HStack {
                    Text("Microphone")
                    Spacer()
                    permissionPill(granted: viewModel.microphoneGranted)
                }

                HStack {
                    Text("Accessibility")
                    Spacer()
                    permissionPill(granted: viewModel.accessibilityGranted)
                }

                if !viewModel.accessibilityGranted {
                    Button("Open System Settings") {
                        openAccessibilitySettings()
                    }
                }
            }

            // Version footer with merkaba ornament
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: DesignSystem.Spacing.sm) {
                        SpinnerRingView(size: 16, revolutionDuration: 8.0, tintColor: DesignSystem.Colors.accent)
                            .opacity(0.4)
                        Text("MacParakeet \(appVersion)")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            viewModel.refreshPermissions()
            viewModel.refreshStats()
            viewModel.refreshEntitlements()
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: - Permission Pill

    @ViewBuilder
    private func permissionPill(granted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
            Text(granted ? "Granted" : "Not Granted")
                .font(.caption2)
        }
        .foregroundStyle(granted ? DesignSystem.Colors.successGreen : DesignSystem.Colors.errorRed)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(granted ? DesignSystem.Colors.successGreen.opacity(0.1) : DesignSystem.Colors.errorRed.opacity(0.1))
        )
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
