import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var customWordsViewModel: CustomWordsViewModel
    @Bindable var textSnippetsViewModel: TextSnippetsViewModel

    @State private var showClearAllAlert = false
    @State private var showCustomWords = false
    @State private var showTextSnippets = false

    var body: some View {
        Form {
            Section("License") {
                HStack {
                    Text(viewModel.entitlementsSummary)
                        .font(.headline)
                    Spacer()
                    if viewModel.isUnlocked {
                        Label("Unlocked", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(DesignSystem.Colors.statusGranted)
                            .font(.caption)
                    } else {
                        Label("Trial", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                if !viewModel.entitlementsDetail.isEmpty {
                    Text(viewModel.entitlementsDetail)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                if let err = viewModel.licensingError, !err.isEmpty {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                if !viewModel.isUnlocked {
                    HStack {
                        TextField("License key", text: $viewModel.licenseKeyInput)
                            .textFieldStyle(.roundedBorder)
                        Button(viewModel.licensingBusy ? "Activating..." : "Activate") {
                            viewModel.activateLicense()
                        }
                        .disabled(viewModel.licensingBusy || viewModel.licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let url = viewModel.checkoutURL {
                        Button("Buy License...") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else {
                    Button("Deactivate on This Mac...") {
                        viewModel.deactivateLicense()
                    }
                    .disabled(viewModel.licensingBusy)
                }
            }

            // Processing
            Section("Processing") {
                Picker("Mode", selection: $viewModel.processingMode) {
                    Text("Raw (no processing)").tag("raw")
                    Text("Clean (fillers removed)").tag("clean")
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                HStack {
                    Text("Custom Words")
                    Spacer()
                    Text("\(viewModel.customWordCount)")
                        .foregroundStyle(.secondary)
                    Button("Manage...") {
                        customWordsViewModel.loadWords()
                        showCustomWords = true
                    }
                }

                HStack {
                    Text("Text Snippets")
                    Spacer()
                    Text("\(viewModel.snippetCount)")
                        .foregroundStyle(.secondary)
                    Button("Manage...") {
                        textSnippetsViewModel.loadSnippets()
                        showTextSnippets = true
                    }
                }
            }
            .sheet(isPresented: $showCustomWords) {
                viewModel.refreshStats()
            } content: {
                CustomWordsView(viewModel: customWordsViewModel)
                    .frame(minWidth: 500, minHeight: 400)
            }
            .sheet(isPresented: $showTextSnippets) {
                viewModel.refreshStats()
            } content: {
                TextSnippetsView(viewModel: textSnippetsViewModel)
                    .frame(minWidth: 500, minHeight: 400)
            }

            // Dictation
            Section("Dictation") {
                HStack {
                    Text("Hotkey")
                    Spacer()
                    Text("Fn (double-tap / hold)")
                        .foregroundStyle(.secondary)
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

                HStack {
                    Text("Dictations")
                    Spacer()
                    Text("\(viewModel.dictationCount) \(viewModel.dictationCount == 1 ? "dictation" : "dictations")")
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
                        SpinnerRingView(size: 16, revolutionDuration: 8.0, tintColor: .secondary)
                            .opacity(0.5)
                        Text("MacParakeet \(appVersion)")
                            .font(.caption)
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
        .foregroundStyle(granted ? DesignSystem.Colors.statusGranted : DesignSystem.Colors.statusDenied)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(granted ? DesignSystem.Colors.statusGranted.opacity(0.1) : DesignSystem.Colors.statusDenied.opacity(0.1))
        )
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
