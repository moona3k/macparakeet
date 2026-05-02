import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct LLMSettingsView: View {
    @Bindable var viewModel: LLMSettingsViewModel

    @State private var showAdvanced = false

    private static let providerOrder: [LLMProviderID] = [
        .lmstudio,
        .ollama,
        .anthropic,
        .openai,
        .gemini,
        .openrouter,
        .openaiCompatible,
        .localCLI,
    ]

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            setupStatusSection

            Divider()

            localAIAppSection

            Divider()

            selectedAIOptionSection

            if viewModel.selectedProviderID != nil {
                Divider()

                // API key (hidden for local providers)
                if viewModel.supportsAPIKey {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("API Key")
                                .font(DesignSystem.Typography.body)
                            Text(
                                viewModel.requiresAPIKey
                                    ? "Your key is stored securely in the macOS Keychain."
                                    : "Optional. Leave blank for servers that do not require authentication."
                            )
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
                            TextField(viewModel.baseURLPlaceholder, text: $viewModel.baseURLOverride)
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
                                TextField(viewModel.baseURLPlaceholder, text: $viewModel.baseURLOverride)
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
    private var setupStatusSection: some View {
        let status = viewModel.setupStatus
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: setupStatusIcon(for: status))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(setupStatusTint(for: status))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(setupStatusTint(for: status).opacity(0.12))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("AI for summaries and chat")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(setupStatusCopy(for: status))
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            if case .ready = status {
                Text("Ready")
                    .font(DesignSystem.Typography.caption.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DesignSystem.Colors.successGreen.opacity(0.10)))
            }
        }
    }

    private var localAIAppSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use a local AI app")
                    .font(DesignSystem.Typography.body)
                Text("Run AI on this Mac. Transcript text stays on this Mac.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            localAIAppRow(
                provider: .lmstudio,
                subtitle: "Recommended. Start LM Studio's local server, then refresh models.",
                buttonTitle: "Use LM Studio",
                badge: "Recommended"
            )

            localAIAppRow(
                provider: .ollama,
                subtitle: "Also works. Start Ollama or run `ollama serve`, then refresh models.",
                buttonTitle: "Use Ollama",
                badge: nil
            )
        }
    }

    private var selectedAIOptionSection: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current choice")
                        .font(DesignSystem.Typography.body)
                    Text("Choose a local app, an API key, or a command-line AI tool.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                Picker("AI option", selection: $viewModel.selectedProviderID) {
                    Text("None").tag(LLMProviderID?.none)
                    ForEach(Self.providerOrder, id: \.self) { provider in
                        Text(provider.displayName).tag(Optional(provider))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 190)
            }

            if viewModel.selectedProviderID == nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("API keys and command-line tools are still available from this menu.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                    Text("Dictation, transcription, and meeting recording work without AI setup.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func localAIAppRow(
        provider: LLMProviderID,
        subtitle: String,
        buttonTitle: String,
        badge: String?
    ) -> some View {
        let isSelected = viewModel.selectedProviderID == provider
        return HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: provider == .lmstudio ? "desktopcomputer" : "terminal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? DesignSystem.Colors.accent : DesignSystem.Colors.textTertiary)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(
                        isSelected
                            ? DesignSystem.Colors.accent.opacity(0.10)
                            : DesignSystem.Colors.surfaceElevated
                    )
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(DesignSystem.Typography.bodySmall.weight(.medium))
                    if let badge {
                        Text(badge)
                            .font(DesignSystem.Typography.micro.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.successGreen)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(DesignSystem.Colors.successGreen.opacity(0.10)))
                    }
                }
                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isSelected {
                    Text(localAIAppStatusText(for: provider))
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(localAIAppStatusTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            VStack(alignment: .trailing, spacing: 6) {
                Button(isSelected ? "Selected" : buttonTitle) {
                    viewModel.chooseLocalAIApp(provider)
                }
                .buttonStyle(.bordered)
                .tint(DesignSystem.Colors.accent)
                .disabled(isSelected)

                if isSelected {
                    Button(viewModel.isLoadingModelList ? "Refreshing..." : "Refresh models") {
                        viewModel.refreshAvailableModels()
                    }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .disabled(viewModel.isLoadingModelList)
                }
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(isSelected ? DesignSystem.Colors.accentLight : DesignSystem.Colors.surfaceElevated.opacity(0.55))
        )
    }

    private func setupStatusIcon(for status: LLMSettingsViewModel.AISetupStatus) -> String {
        switch status {
        case .setUpNeeded:
            return "sparkles"
        case .ready:
            return "checkmark"
        case .cannotConnect:
            return "exclamationmark"
        }
    }

    private func setupStatusTint(for status: LLMSettingsViewModel.AISetupStatus) -> Color {
        switch status {
        case .setUpNeeded:
            return DesignSystem.Colors.accent
        case .ready:
            return DesignSystem.Colors.successGreen
        case .cannotConnect:
            return DesignSystem.Colors.warningAmber
        }
    }

    private func setupStatusCopy(for status: LLMSettingsViewModel.AISetupStatus) -> String {
        switch status {
        case .setUpNeeded:
            return "Choose how MacParakeet should run AI features. Transcription still works without this."
        case .ready(let displayName):
            return "Ready: using \(displayName)."
        case .cannotConnect(let displayName, let message):
            return "MacParakeet could not reach \(displayName): \(message)"
        }
    }

    private func localAIAppStatusText(for provider: LLMProviderID) -> String {
        if viewModel.isLoadingModelList {
            return "Checking for models..."
        }
        if let error = viewModel.modelListErrorMessage {
            return error
        }
        if viewModel.discoveredModelCount == 1 {
            return "Detected 1 model."
        }
        if viewModel.discoveredModelCount > 1 {
            return "Detected \(viewModel.discoveredModelCount) models."
        }
        if provider == .ollama {
            return "No running Ollama server detected yet. You can still save a recommended model name."
        }
        return "No running LM Studio server detected yet."
    }

    private var localAIAppStatusTint: Color {
        if viewModel.modelListErrorMessage != nil {
            return DesignSystem.Colors.warningAmber
        }
        if viewModel.discoveredModelCount > 0 {
            return DesignSystem.Colors.successGreen
        }
        return DesignSystem.Colors.textSecondary
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
                    Text("Optionally run the final transcript through your selected AI option after the usual cleanup step.")
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
        let isLocal = viewModel.isLocalConfiguration
        let isCLI = viewModel.selectedProviderID == .localCLI
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: isLocal ? "lock.fill" : "arrow.up.right.circle")
                .font(.system(size: 12))
                .foregroundStyle(isLocal ? DesignSystem.Colors.successGreen : DesignSystem.Colors.warningAmber)

            Text(isLocal
                 ? "Transcript text stays on this Mac."
                 : isCLI
                    ? "Runs a command on this Mac. The command may contact its own service."
                    : "Transcription stays local. Transcript text is sent only when you run an AI action.")
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
