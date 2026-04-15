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
                    Text("None").tag(LLMProviderID?.none)
                    ForEach(LLMProviderID.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(Optional(provider))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 190)
            }

            if viewModel.selectedProviderID != nil {
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
                    if viewModel.selectedProviderID?.requiresCustomEndpoint == true {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Custom Endpoint")
                                    .font(DesignSystem.Typography.body)
                                Text("OpenAI-compatible base URL, for example https://api.example.com/v1.")
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: DesignSystem.Spacing.md)
                            TextField("https://api.example.com/v1", text: $viewModel.baseURLOverride)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                        }

                        Divider()
                    }

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
                    if viewModel.selectedProviderID?.requiresCustomEndpoint != true {
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
                }

                Divider()

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
            }

            Divider()

            aiFormatterSection

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
            } else if viewModel.availableModels.isEmpty {
                Text(viewModel.isLoadingModelList ? "Loading models..." : "No models available")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 220, alignment: .leading)
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

            HStack(spacing: 10) {
                if viewModel.useCustomModel {
                    if viewModel.canChooseModelFromList {
                        Button("Choose from list") {
                            viewModel.useCustomModel = false
                        }
                        .buttonStyle(.plain)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Use custom model") {
                        viewModel.useCustomModel = true
                    }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                }

                if viewModel.canRefreshModelList {
                    Button(viewModel.isLoadingModelList ? "Refreshing..." : "Refresh list") {
                        viewModel.refreshAvailableModels()
                    }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .disabled(viewModel.isLoadingModelList)
                }
            }

            if let errorMessage = viewModel.modelListErrorMessage {
                Text(errorMessage)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                    .frame(width: 220, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var aiFormatterSection: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Formatter")
                        .font(DesignSystem.Typography.body)
                    Text("Optionally run the final transcript through your AI provider after the usual cleanup step.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                HStack(spacing: 8) {
                    Toggle("", isOn: $viewModel.aiFormatterEnabled)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(!viewModel.canToggleAIFormatter)

                    Text(viewModel.aiFormatterStatusText)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(
                            viewModel.aiFormatterEnabled
                                ? DesignSystem.Colors.successGreen
                                : DesignSystem.Colors.textSecondary
                        )
                }
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prompt")
                        .font(DesignSystem.Typography.body)
                    Text("Uses `{{TRANSCRIPT}}` as the transcript placeholder and runs as the last output step.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                VStack(alignment: .trailing, spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $viewModel.aiFormatterPrompt)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .disabled(!viewModel.canToggleAIFormatter)
                    }
                    .frame(width: 380)
                    .frame(minHeight: 220)
                    .background(DesignSystem.Colors.background)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
                    )

                    Button("Reset Prompt") {
                        viewModel.resetAIFormatterPrompt()
                    }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .disabled(!viewModel.canResetAIFormatterPrompt)
                }
            }

            if let disabledReason = viewModel.aiFormatterDisabledReason {
                Text(disabledReason)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        let isLocal = viewModel.selectedProviderID?.isLocal ?? false
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
