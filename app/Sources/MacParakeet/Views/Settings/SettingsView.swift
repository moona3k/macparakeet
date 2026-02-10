import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    @State private var showClearAllAlert = false

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
                    permissionBadge(granted: viewModel.microphoneGranted)
                }

                HStack {
                    Text("Accessibility")
                    Spacer()
                    permissionBadge(granted: viewModel.accessibilityGranted)
                }

                if !viewModel.accessibilityGranted {
                    Button("Open System Settings") {
                        openAccessibilitySettings()
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Text("MacParakeet \(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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

    @ViewBuilder
    private func permissionBadge(granted: Bool) -> some View {
        if granted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(DesignSystem.Colors.statusGranted)
                .font(.caption)
        } else {
            Label("Not Granted", systemImage: "xmark.circle.fill")
                .foregroundStyle(DesignSystem.Colors.statusDenied)
                .font(.caption)
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
