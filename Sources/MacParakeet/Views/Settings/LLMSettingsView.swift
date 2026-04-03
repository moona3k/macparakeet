import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct LLMSettingsView: View {
    @Bindable var viewModel: LLMSettingsViewModel

    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            // Provider picker
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Provider")
                        .font(DesignSystem.Typography.body)
                    Text("Choose your AI provider for summaries and chat.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                Picker("Provider", selection: $viewModel.selectedProviderID) {
                    ForEach(LLMProviderID.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            Divider()

            // API key (hidden for local providers)
            if viewModel.requiresAPIKey {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("API Key")
                            .font(DesignSystem.Typography.body)
                        Text("Your key is stored securely in the macOS Keychain.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: DesignSystem.Spacing.md)
                    SecureField("sk-...", text: $viewModel.apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }

                Divider()
            }

            if viewModel.selectedProviderID == .localCLI {
                cliSettingsSection
            } else {
                // Model name
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model")
                            .font(DesignSystem.Typography.body)
                        Text("The model to use for AI features.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: DesignSystem.Spacing.md)
                    modelPicker
                }

                // Advanced: Base URL override
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Base URL")
                                .font(DesignSystem.Typography.body)
                            Text("Override the default API endpoint.")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: DesignSystem.Spacing.md)
                        TextField("https://...", text: $viewModel.baseURLOverride)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    .padding(.top, DesignSystem.Spacing.sm)
                }
                .font(DesignSystem.Typography.caption)
            }

            Divider()

            // Privacy info
            privacyInfo

            Divider()

            // Test connection + status
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button("Test Connection") {
                    viewModel.testConnection()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.connectionTestState == .testing || !viewModel.canTestConnection)

                connectionStatusIndicator

                Spacer()
            }

            if let validationMessage = viewModel.validationMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.warningAmber)
                    Text(validationMessage)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.warningAmber)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            // Save / Clear
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button("Save") {
                    viewModel.saveConfiguration()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.accent)
                .disabled(!viewModel.canSave)

                if viewModel.isConfigured {
                    Button("Clear", role: .destructive) {
                        viewModel.clearConfiguration()
                    }
                    .buttonStyle(.bordered)
                }

                saveStateIndicator

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if viewModel.useCustomModel {
                TextField("Model ID (e.g. gpt-4o)", text: $viewModel.customModelName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            } else {
                Picker("Model", selection: $viewModel.modelName) {
                    ForEach(viewModel.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 180)
            }

            Button(viewModel.useCustomModel ? "Choose from list" : "Use custom model") {
                viewModel.useCustomModel.toggle()
            }
            .buttonStyle(.plain)
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cliSettingsSection: some View {
        // Template picker
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CLI Tool")
                    .font(DesignSystem.Typography.body)
                Text("Choose a preset or enter a custom command.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            Picker("Template", selection: $viewModel.selectedCLITemplate) {
                Text("Custom").tag(LocalCLITemplate?.none)
                ForEach(LocalCLITemplate.allCases, id: \.self) { template in
                    Text(template.displayName).tag(Optional(template))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 160)
        }

        Divider()

        // Command editor
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Command")
                    .font(DesignSystem.Typography.body)
                Text("Prompt is passed via stdin and environment variables. Presets run from an app-owned working directory.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            TextField("claude -p", text: $viewModel.commandTemplate)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 220)
        }

        Divider()

        // Timeout
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Timeout")
                    .font(DesignSystem.Typography.body)
                Text("Maximum seconds to wait for a response.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            TextField("120", value: $viewModel.cliTimeoutSeconds, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            Text("seconds")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var privacyInfo: some View {
        let isLocal = viewModel.selectedProviderID.isLocal
        let isCLI = viewModel.selectedProviderID == .localCLI
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: isLocal ? "lock.fill" : "arrow.up.right.circle")
                .font(.system(size: 12))
                .foregroundStyle(isLocal ? DesignSystem.Colors.successGreen : DesignSystem.Colors.warningAmber)

            Text(isLocal
                 ? "Everything stays on your device."
                 : isCLI
                    ? "Runs via CLI on your device. The tool may send data to its cloud service."
                    : "Transcription is always local. AI features send transcript text to your chosen provider.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(isLocal
                      ? DesignSystem.Colors.successGreen.opacity(0.06)
                      : DesignSystem.Colors.warningAmber.opacity(0.06))
        )
    }

    @ViewBuilder
    private var saveStateIndicator: some View {
        switch viewModel.saveState {
        case .idle:
            EmptyView()
        case .saved:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                Text("Saved")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.successGreen)
            }
        case .error(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                Text(message)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var connectionStatusIndicator: some View {
        switch viewModel.connectionTestState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Testing...")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        case .success:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                Text("Connected")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.successGreen)
            }
        case .error(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                Text(message)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                    .lineLimit(2)
            }
        }
    }
}
