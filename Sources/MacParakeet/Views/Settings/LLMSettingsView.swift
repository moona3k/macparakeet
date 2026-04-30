import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct LLMSettingsView: View {
    @Bindable var viewModel: LLMSettingsViewModel

    @State private var showAdvanced = false
    @State private var showFormattingModelOverride = false

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
                } else if viewModel.selectedProviderID == .localFormattingModel {
                    formattingModelSettingsSection
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

            if let blocker = viewModel.saveBlockerMessage {
                Text(blocker)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    private var formattingModelSettingsSection: some View {
        formattingModelCLISection

        Divider()

        formattingModelRuntimeSection

        Divider()

        // Mode picker
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mode")
                    .font(DesignSystem.Typography.body)
                Text("Auto picks rules for short text and the local LLM for complex transcripts.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            Picker("Mode", selection: $viewModel.formattingModelMode) {
                ForEach(LocalFormattingModelMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)
        }

        Divider()

        // Model picker
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model")
                    .font(DesignSystem.Typography.body)
                Text("Local MLX model the cleanup daemon should load when LLM mode runs.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            Picker("Model", selection: $viewModel.formattingModelModelID) {
                ForEach(formattingModelPickerOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 220)
        }

        formattingModelDownloadRow
    }

    /// Always include the currently-bound `formattingModelModelID` in the
    /// picker's option set. If a user previously saved a custom MLX repo (or
    /// we drop a tag from `suggestedModels`), the bound value is otherwise
    /// not in the menu and SwiftUI's `Picker` falls into undefined behavior.
    private var formattingModelPickerOptions: [String] {
        var options = viewModel.availableModels
        let current = viewModel.formattingModelModelID
        if !current.isEmpty, !options.contains(current) {
            options.insert(current, at: 0)
        }
        return options
    }

    @ViewBuilder
    private var formattingModelRuntimeSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Python Dependencies")
                    .font(DesignSystem.Typography.body)
                Text("MLX, mlx-lm and friends. Installed once into ~/Library/Application Support/MacParakeet — about 350 MB on disk. Doesn't ship in the app bundle to keep downloads small.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                runtimeStatusLabel
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            VStack(alignment: .trailing, spacing: 6) {
                Button(runtimeButtonTitle) {
                    viewModel.installRuntime()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canInstallRuntime)

                if case .installing(let line) = viewModel.runtimeBootstrapState {
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 220, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var runtimeStatusLabel: some View {
        let state = viewModel.runtimeBootstrapState
        HStack(spacing: 4) {
            switch state {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                Text("Installed")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.successGreen)
            case .missing:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                Text("Not installed")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
            case .outdated(let v):
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                Text("Out of date (v\(v))")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
            case .installing:
                ProgressView().controlSize(.small)
                Text("Installing…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            case .error(let msg):
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                Text(msg)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                    .lineLimit(2)
            case .unknown:
                EmptyView()
            }
        }
    }

    private var runtimeButtonTitle: String {
        switch viewModel.runtimeBootstrapState {
        case .ready: return "Reinstall"
        case .installing: return "Installing…"
        case .outdated: return "Update"
        default: return "Install"
        }
    }

    @ViewBuilder
    private var formattingModelDownloadRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                modelDownloadStatusLabel
                if case .downloading(let line) = viewModel.modelDownloadState {
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            Button(modelDownloadButtonTitle) {
                viewModel.downloadFormattingModel()
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canDownloadModel)
        }
    }

    @ViewBuilder
    private var modelDownloadStatusLabel: some View {
        let state = viewModel.modelDownloadState
        HStack(spacing: 4) {
            switch state {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                Text("Model downloaded")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.successGreen)
            case .missing:
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                Text("Not downloaded")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
            case .downloading:
                ProgressView().controlSize(.small)
                Text("Downloading…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            case .error(let msg):
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                Text(msg)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                    .lineLimit(2)
            case .unknown:
                EmptyView()
            }
        }
    }

    private var modelDownloadButtonTitle: String {
        switch viewModel.modelDownloadState {
        case .ready: return "Re-download"
        case .downloading: return "Downloading…"
        default: return "Download"
        }
    }

    @ViewBuilder
    private var formattingModelCLISection: some View {
        let bundledPath = viewModel.bundledFormattingModelCLIPath
        let trimmedOverride = viewModel.formattingModelCLIPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOverride = !trimmedOverride.isEmpty
            && trimmedOverride != LocalFormattingModelConfig.legacyDefaultCLIPathSentinel

        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cleanup CLI")
                    .font(DesignSystem.Typography.body)
                if let bundledPath, !hasOverride {
                    Text("Bundled with MacParakeet. Nothing to configure.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                    Text(bundledPath)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if bundledPath == nil && !hasOverride {
                    Text("Bundled cleanup CLI not found in this build. Set a path to use a system install.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Using a custom path. Clear to fall back to the bundled CLI.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            if bundledPath != nil && !hasOverride {
                Button(showFormattingModelOverride ? "Hide override" : "Override") {
                    showFormattingModelOverride.toggle()
                }
                .buttonStyle(.borderless)
                .font(DesignSystem.Typography.caption)
                .frame(width: 220, alignment: .trailing)
            } else {
                TextField("macparakeet-cleanup", text: $viewModel.formattingModelCLIPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 220)
            }
        }

        if bundledPath != nil && !hasOverride && showFormattingModelOverride {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom path")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                    Text("Absolute path to a `macparakeet-cleanup` launcher. Useful if you maintain your own checkout.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                TextField("/path/to/macparakeet-cleanup", text: $viewModel.formattingModelCLIPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 220)
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
        let isFormattingModel = viewModel.selectedProviderID == .localFormattingModel
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: isLocal ? "lock.fill" : "arrow.up.right.circle")
                .font(.system(size: 12))
                .foregroundStyle(isLocal ? DesignSystem.Colors.successGreen : DesignSystem.Colors.warningAmber)

            Text(isFormattingModel
                 ? "Runs the bundled cleanup script on your device. Nothing leaves your Mac."
                 : isLocal
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
