import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Plan") {
                HStack {
                    Text(viewModel.entitlementsSummary)
                        .font(.headline)
                    Spacer()
                    if viewModel.isUnlocked {
                        Label("Unlocked", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Label("Not Unlocked", systemImage: "lock.fill")
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

            // General
            Section("General") {
                Toggle("Launch at login", isOn: $viewModel.launchAtLogin)
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
                    Text("\(viewModel.dictationCount) recordings")
                        .foregroundStyle(.secondary)
                }

                Button("Clear All Dictations...", role: .destructive) {
                    viewModel.clearAllDictations()
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
        }
        .formStyle(.grouped)
        .onAppear {
            viewModel.refreshPermissions()
            viewModel.refreshStats()
            viewModel.refreshEntitlements()
        }
    }

    @ViewBuilder
    private func permissionBadge(granted: Bool) -> some View {
        if granted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else {
            Label("Not Granted", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
