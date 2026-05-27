import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct LLMSettingsView: View {
    @Bindable var viewModel: LLMSettingsViewModel

    @State private var isChangingAIOption = false
    @State private var selectedPath: AISetupPath?
    @State private var showAdvancedPaths = false
    @State private var showOptionalToken = false
    @State private var showConnectionSettings = false
    @State private var cloudProviderChoice: LLMProviderID = .anthropic

    private static let cloudProviderOrder: [LLMProviderID] = [
        .anthropic,
        .openai,
        .gemini,
        .openrouter,
    ]
    private static let lmStudioDownloadURL = URL(string: "https://lmstudio.ai/download?os=mac")!
    private static let ollamaDownloadURL = URL(string: "https://ollama.com/download")!

    private var shouldShowSetupFlow: Bool {
        !viewModel.isConfigured || isChangingAIOption || viewModel.hasUnsavedChanges
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            connectionOverview

            if shouldShowSetupFlow {
                Divider()
                setupPathSection

                if let selectedPath {
                    Divider()
                    setupDetails(for: selectedPath)
                }
            }

            if viewModel.isConfigured && !shouldShowSetupFlow {
                Divider()
                aiFormatterSection
            }
        }
        .onAppear {
            syncSelectedPathWithDraft()
        }
        .onChange(of: viewModel.selectedProviderID) { _, providerID in
            syncSelectedPath(with: providerID)
        }
    }

    // MARK: - Overview

    private var connectionOverview: some View {
        let status = viewModel.setupStatus
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: setupStatusIcon(for: status))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(setupStatusTint(for: status))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(setupStatusTint(for: status).opacity(0.12))
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(setupStatusTitle(for: status))
                        .font(DesignSystem.Typography.body.weight(.semibold))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(setupStatusCopy(for: status))
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                setupStatusChip(for: status)
            }

            if showsInlineStateIndicators {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    connectionStatusIndicator
                    saveStateIndicator
                    Spacer()
                }
            }

            if !shouldShowSetupFlow {
                overviewActions(for: status)
            }
        }
    }

    private var showsInlineStateIndicators: Bool {
        !shouldShowSetupFlow
            && (viewModel.hasUnsavedChanges
            || viewModel.connectionTestState != .idle
            || viewModel.saveState != .idle)
    }

    @ViewBuilder
    private func setupStatusChip(for status: LLMSettingsViewModel.AISetupStatus) -> some View {
        switch status {
        case .ready:
            SettingsStatusChip(status: .ok, label: "Ready")
        case .cannotConnect:
            SettingsStatusChip(status: .recommended, label: "Check setup")
        case .setUpNeeded:
            if viewModel.selectedProviderID == nil {
                SettingsStatusChip(status: .info, label: "Optional")
            }
        }
    }

    @ViewBuilder
    private func overviewActions(for status: LLMSettingsViewModel.AISetupStatus) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            switch status {
            case .setUpNeeded:
                Button {
                    beginSetup()
                } label: {
                    Label("Connect AI", systemImage: "sparkles")
                }
                .parakeetAction(.primaryProminent)

            case .ready:
                Button {
                    viewModel.testConnection()
                } label: {
                    Label("Test", systemImage: "bolt")
                }
                .parakeetAction(.secondary)
                .disabled(viewModel.connectionTestState == .testing || !viewModel.canTestConnection)

                Button {
                    beginSetup()
                } label: {
                    Label("Change Setup", systemImage: "arrow.triangle.2.circlepath")
                }
                .parakeetAction(.secondary)

            case .cannotConnect:
                Button {
                    viewModel.testConnection()
                } label: {
                    Label("Test Again", systemImage: "bolt")
                }
                .parakeetAction(.primary)
                .disabled(viewModel.connectionTestState == .testing || !viewModel.canTestConnection)

                Button {
                    beginSetup()
                } label: {
                    Label("Fix Setup", systemImage: "wrench.and.screwdriver")
                }
                .parakeetAction(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Setup Paths

    private var setupPathSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose how MacParakeet should use AI")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Capture works without this. Pick one option only when you want summaries, chat, meeting Ask, or Transforms.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                setupPathRow(.localApp)
                Divider()
                setupPathRow(.apiKey)
                Divider()
                setupPathRow(.commandLine)
            }

            DisclosureGroup(isExpanded: $showAdvancedPaths) {
                VStack(spacing: 0) {
                    setupPathRow(.customEndpoint)
                }
                .padding(.top, DesignSystem.Spacing.xs)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text("More options")
                        .font(DesignSystem.Typography.caption.weight(.semibold))
                    Text("Custom API endpoints")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    private func setupPathRow(_ path: AISetupPath) -> some View {
        Button {
            selectSetupPath(path)
        } label: {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                Image(systemName: path.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selectedPath == path ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(path.title)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        if let badge = path.badge {
                            Text(badge)
                                .font(DesignSystem.Typography.micro.weight(.semibold))
                                .foregroundStyle(DesignSystem.Colors.accentDark)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(DesignSystem.Colors.accent.opacity(0.12)))
                        }
                    }
                    Text(path.detail)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                if selectedPath == path {
                    SettingsStatusChip(status: .info, label: "Selected")
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(selectedPath == path ? DesignSystem.Colors.accentLight.opacity(0.55) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(selectedPath == path ? DesignSystem.Colors.accent.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func setupDetails(for path: AISetupPath) -> some View {
        switch path {
        case .localApp:
            localAppSetupPanel
        case .apiKey:
            apiKeySetupPanel
        case .commandLine:
            commandLineSetupPanel
        case .customEndpoint:
            customEndpointSetupPanel
        }
    }

    // MARK: - Path Details

    private var localAppSetupPanel: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            setupPanelHeader(
                title: "Local AI app",
                detail: "Most private path. MacParakeet connects to a local app that is already running on this Mac."
            )

            VStack(spacing: 0) {
                localProviderRow(
                    providerID: .lmstudio,
                    icon: "desktopcomputer",
                    title: "LM Studio",
                    badge: "Recommended",
                    detail: "Best fit for non-technical local setup. Download a model, load it, then start the local server.",
                    installLabel: "Download LM Studio",
                    installURL: Self.lmStudioDownloadURL
                )
                Divider()
                localProviderRow(
                    providerID: .ollama,
                    icon: "terminal",
                    title: "Ollama",
                    badge: nil,
                    detail: "Good if you already use Ollama or are comfortable pulling models from the command line.",
                    installLabel: "Download Ollama",
                    installURL: Self.ollamaDownloadURL
                )
            }

            if viewModel.selectedProviderID == .lmstudio || viewModel.selectedProviderID == .ollama {
                Divider()
                localAppRequirementRow

                Divider()
                modelRow

                if let localModelSetupHint {
                    localModelHintRow(localModelSetupHint)
                }

                Divider()
                setupActions

                if viewModel.selectedProviderID == .lmstudio {
                    DisclosureGroup("Optional token", isExpanded: $showOptionalToken) {
                        apiKeyRow
                            .padding(.top, DesignSystem.Spacing.sm)
                    }
                    .font(DesignSystem.Typography.caption)
                }

                Divider()
                connectionSettingsSection

                Divider()
                privacyInfo
            }
        }
    }

    private var apiKeySetupPanel: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            setupPanelHeader(
                title: "API key",
                detail: "Use Claude, OpenAI, Gemini, or OpenRouter. Audio stays local; transcript text is sent only when you run an AI action."
            )

            apiProviderPickerRow

            Divider()
            apiKeyRow

            Divider()
            modelRow

            Divider()
            setupActions

            Divider()
            connectionSettingsSection

            Divider()
            privacyInfo
        }
    }

    private var commandLineSetupPanel: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            setupPanelHeader(
                title: "Command-line AI tool",
                detail: "Run a local command when MacParakeet needs AI. Best for agent workflows and power users."
            )

            cliSettingsSection

            Divider()
            setupActions

            Divider()
            privacyInfo
        }
    }

    private var customEndpointSetupPanel: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            setupPanelHeader(
                title: "Custom API endpoint",
                detail: "Connect a gateway, remote server, or local server that speaks the OpenAI chat completions format."
            )

            endpointRow

            Divider()
            apiKeyRow

            Divider()
            modelRow

            Divider()
            setupActions

            Divider()
            privacyInfo
        }
    }

    private func setupPanelHeader(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(DesignSystem.Typography.body.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func localProviderRow(
        providerID: LLMProviderID,
        icon: String,
        title: String,
        badge: String?,
        detail: String,
        installLabel: String,
        installURL: URL
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(viewModel.selectedProviderID == providerID ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(title)
                        .font(DesignSystem.Typography.body)
                    if let badge {
                        Text(badge)
                            .font(DesignSystem.Typography.micro.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.accentDark)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(DesignSystem.Colors.accent.opacity(0.12)))
                    }
                }

                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: installURL) {
                    Label(installLabel, systemImage: "arrow.up.right.square")
                }
                .parakeetAction(.subtle)
                .font(DesignSystem.Typography.caption)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            if viewModel.selectedProviderID == providerID {
                SettingsStatusChip(status: .info, label: "Selected")
            } else {
                Button {
                    selectedPath = .localApp
                    viewModel.selectedProviderID = providerID
                } label: {
                    Label("Use \(title)", systemImage: "arrow.right")
                }
                .parakeetAction(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private var localAppRequirementRow: some View {
        let message: String
        switch viewModel.selectedProviderID {
        case .lmstudio:
            message = "In LM Studio, download and load a model, then start the local server. Use Refresh Models after the server is running."
        case .ollama:
            message = "Install or open Ollama, pull a model such as qwen3.5:4b, and keep Ollama running. Use Refresh Models when it is ready."
        default:
            message = "Start your local AI app before saving this setup."
        }

        return HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DesignSystem.Spacing.md)
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.65))
        )
    }

    private var apiProviderPickerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI service")
                    .font(DesignSystem.Typography.body)
                Text("Choose the account where you already have an API key.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            Picker("AI service", selection: cloudProviderBinding) {
                ForEach(Self.cloudProviderOrder, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 220)
        }
    }

    private var localModelSetupHint: LocalModelSetupHint? {
        guard viewModel.canRefreshModelList, viewModel.discoveredModelCount == 0 else { return nil }
        switch viewModel.selectedProviderID {
        case .lmstudio:
            return LocalModelSetupHint(
                message: "No LM Studio models found yet. Start LM Studio's local server with a loaded model, then refresh.",
                downloadLabel: "Get LM Studio",
                downloadURL: Self.lmStudioDownloadURL
            )
        case .ollama:
            return LocalModelSetupHint(
                message: "No Ollama models found yet. Start Ollama and pull a model, then refresh.",
                downloadLabel: "Get Ollama",
                downloadURL: Self.ollamaDownloadURL
            )
        default:
            return nil
        }
    }

    private func localModelHintRow(_ hint: LocalModelSetupHint) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(hint.message)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: hint.downloadURL) {
                    Label(hint.downloadLabel, systemImage: "arrow.up.right.square")
                }
                .parakeetAction(.subtle)
                .font(DesignSystem.Typography.caption)
            }

            Spacer(minLength: DesignSystem.Spacing.md)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Shared Configuration Rows

    private var cloudProviderBinding: Binding<LLMProviderID> {
        Binding(
            get: {
                if let providerID = viewModel.selectedProviderID,
                   Self.cloudProviderOrder.contains(providerID) {
                    return providerID
                }
                return cloudProviderChoice
            },
            set: { providerID in
                cloudProviderChoice = providerID
                viewModel.selectedProviderID = providerID
                selectedPath = .apiKey
            }
        )
    }

    private var apiKeyRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.requiresAPIKey ? "API Key" : "Optional API Key")
                    .font(DesignSystem.Typography.body)
                Text(
                    viewModel.requiresAPIKey
                        ? "Stored securely in the macOS Keychain."
                        : "Leave blank for local servers that do not require authentication."
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            SecureField(viewModel.apiKeyPlaceholder, text: $viewModel.apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        }
    }

    private var modelRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model")
                    .font(DesignSystem.Typography.body)
                Text(modelRowDetail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            modelPicker
        }
    }

    private var modelRowDetail: String {
        switch viewModel.selectedProviderID {
        case .lmstudio:
            return "Pick a model loaded in LM Studio."
        case .ollama:
            return "Pick an installed Ollama model, or use a recommended default."
        case .openaiCompatible:
            return "Enter the exact model ID exposed by this endpoint."
        case .localCLI:
            return "Command-line tools choose their own model."
        default:
            return "The model to use for AI features."
        }
    }

    @ViewBuilder
    private var connectionSettingsSection: some View {
        if viewModel.selectedProviderID?.requiresCustomEndpoint == true {
            endpointRow
        } else {
            DisclosureGroup("Advanced connection settings", isExpanded: $showConnectionSettings) {
                endpointRow
                    .padding(.top, DesignSystem.Spacing.sm)
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    private var endpointRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.selectedProviderID?.requiresCustomEndpoint == true ? "Endpoint" : "Base URL")
                    .font(DesignSystem.Typography.body)
                Text(
                    viewModel.selectedProviderID?.requiresCustomEndpoint == true
                        ? "Base URL, for example https://api.example.com/v1 or http://localhost:1234/v1."
                        : "Override the default endpoint only if your AI app or service uses a custom address."
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            TextField(viewModel.baseURLPlaceholder, text: $viewModel.baseURLOverride)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        }
    }

    private var setupActions: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top) {
                Button {
                    saveAndCollapseIfPossible()
                } label: {
                    Label("Save and Test", systemImage: "checkmark.circle")
                }
                .parakeetAction(.primaryProminent)
                .disabled(!viewModel.canSave || viewModel.connectionTestState == .testing)

                Button {
                    viewModel.testConnection()
                } label: {
                    Label("Test", systemImage: "bolt")
                }
                .parakeetAction(.secondary)
                .disabled(viewModel.connectionTestState == .testing || !viewModel.canTestConnection)

                if viewModel.canRefreshModelList {
                    Button {
                        viewModel.refreshAvailableModels()
                    } label: {
                        Label("Refresh Models", systemImage: "arrow.clockwise")
                    }
                    .parakeetAction(.secondary)
                    .disabled(viewModel.isLoadingModelList)
                }

                Button {
                    cancelSetup()
                } label: {
                    Label(viewModel.isConfigured ? "Cancel" : "Not Now", systemImage: "xmark")
                }
                .parakeetAction(.secondary)

                if viewModel.isConfigured {
                    Button {
                        disconnectAI()
                    } label: {
                        Label("Disconnect", systemImage: "power")
                    }
                    .parakeetAction(.subtle)
                }

                Spacer()
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                connectionStatusIndicator
                saveStateIndicator
                Spacer()
            }

            if let validationMessage = viewModel.validationMessage {
                validationMessageRow(validationMessage)
            }
        }
    }

    private func validationMessageRow(_ message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DesignSystem.Colors.warningAmber)
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.warningAmber)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var modelPicker: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if viewModel.useCustomModel {
                TextField("Model ID (e.g. gpt-4o)", text: $viewModel.customModelName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            } else if viewModel.availableModels.isEmpty {
                Text(viewModel.isLoadingModelList ? "Loading models..." : "No models available")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 240, alignment: .leading)
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

            if let errorMessage = viewModel.modelListErrorMessage {
                Text(errorMessage)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                    .frame(width: 240, alignment: .leading)
            }
        }
    }

    // MARK: - AI Formatter

    @ViewBuilder
    private var aiFormatterSection: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text("AI Formatter")
                                .font(DesignSystem.Typography.body.weight(.semibold))
                            Text("Final step")
                                .font(DesignSystem.Typography.micro.weight(.semibold))
                                .foregroundStyle(DesignSystem.Colors.accentDark)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                                )
                        }
                        Text("Optionally run the final transcript through your selected AI option after the usual cleanup step.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DesignSystem.Spacing.md)
                    AIFormatterActivationToggle(
                        isOn: $viewModel.aiFormatterEnabled,
                        isAvailable: viewModel.canToggleAIFormatter,
                        disabledReason: viewModel.aiFormatterDisabledReason
                    )
                }

                if let disabledReason = viewModel.aiFormatterDisabledReason {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Text(disabledReason)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text("Prompt")
                            .font(DesignSystem.Typography.body)
                        Text(viewModel.aiFormatterPromptModeText)
                            .font(DesignSystem.Typography.micro.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(DesignSystem.Colors.surfaceElevated)
                            )
                    }
                    Text("Uses `{{TRANSCRIPT}}` as the transcript placeholder and runs as the last output step.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DesignSystem.Spacing.md)
                VStack(alignment: .trailing, spacing: 6) {
                    TextEditor(text: $viewModel.aiFormatterPrompt)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .disabled(!viewModel.canToggleAIFormatter)
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
        }
    }

    // MARK: - Local CLI

    @ViewBuilder
    private var cliSettingsSection: some View {
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
                .frame(width: 240)
        }

        Divider()

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

    // MARK: - Indicators

    private var privacyInfo: some View {
        let content = privacyInfoContent

        return HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: content.icon)
                .font(.system(size: 12))
                .foregroundStyle(content.tint)

            Text(content.text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(content.tint.opacity(0.06))
        )
    }

    private var privacyInfoContent: (text: String, icon: String, tint: Color) {
        if viewModel.selectedProviderID == .localCLI {
            return (
                "Runs a command on this Mac. The command may contact its own service.",
                "terminal",
                DesignSystem.Colors.warningAmber
            )
        }
        if viewModel.isLocalConfiguration {
            return (
                "Transcript text is sent only to your local AI endpoint.",
                "lock.fill",
                DesignSystem.Colors.successGreen
            )
        }
        return (
            "Transcription stays local. Transcript text is sent only when you run an AI action.",
            "arrow.up.right.circle",
            DesignSystem.Colors.warningAmber
        )
    }

    @ViewBuilder
    private var saveStateIndicator: some View {
        switch viewModel.saveState {
        case .idle:
            if viewModel.hasUnsavedChanges {
                HStack(spacing: 4) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(DesignSystem.Colors.warningAmber)
                    Text("Unsaved changes")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.warningAmber)
                }
            }
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
                Text(viewModel.connectionSuccessMessage)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                    .lineLimit(2)
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

    // MARK: - Actions

    private func beginSetup() {
        isChangingAIOption = true
        syncSelectedPathWithDraft()
    }

    private func selectSetupPath(_ path: AISetupPath) {
        isChangingAIOption = true
        selectedPath = path
        if path == .customEndpoint {
            showAdvancedPaths = true
        }

        switch path {
        case .localApp:
            if viewModel.selectedProviderID != .lmstudio && viewModel.selectedProviderID != .ollama {
                viewModel.selectedProviderID = .lmstudio
            }
        case .apiKey:
            viewModel.selectedProviderID = cloudProviderChoice
        case .commandLine:
            viewModel.selectedProviderID = .localCLI
        case .customEndpoint:
            viewModel.selectedProviderID = .openaiCompatible
        }
    }

    private func saveAndCollapseIfPossible() {
        viewModel.saveAndTestConfiguration()
        guard viewModel.isConfigured, !viewModel.hasUnsavedChanges else { return }
        isChangingAIOption = false
        syncSelectedPathWithDraft()
    }

    private func cancelSetup() {
        if viewModel.isConfigured {
            viewModel.discardDraftChanges()
            isChangingAIOption = false
            syncSelectedPathWithDraft()
        } else {
            viewModel.selectedProviderID = nil
            selectedPath = nil
            isChangingAIOption = false
        }
    }

    private func disconnectAI() {
        viewModel.selectedProviderID = nil
        viewModel.saveConfiguration()
        selectedPath = nil
        isChangingAIOption = false
    }

    private func syncSelectedPathWithDraft() {
        syncSelectedPath(with: viewModel.selectedProviderID)
    }

    private func syncSelectedPath(with providerID: LLMProviderID?) {
        guard let providerID else {
            if !viewModel.isConfigured {
                selectedPath = nil
            }
            return
        }

        selectedPath = Self.setupPath(for: providerID)
        if Self.cloudProviderOrder.contains(providerID) {
            cloudProviderChoice = providerID
        }
        if providerID == .openaiCompatible {
            showAdvancedPaths = true
        }
    }

    private static func setupPath(for providerID: LLMProviderID) -> AISetupPath {
        switch providerID {
        case .lmstudio, .ollama:
            return .localApp
        case .localCLI:
            return .commandLine
        case .openaiCompatible:
            return .customEndpoint
        case .anthropic, .openai, .gemini, .openrouter:
            return .apiKey
        }
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

    private func setupStatusTitle(for status: LLMSettingsViewModel.AISetupStatus) -> String {
        switch status {
        case .setUpNeeded:
            if viewModel.selectedProviderID != nil {
                return "Finish AI setup"
            }
            return "AI is off"
        case .ready:
            return "AI is connected"
        case .cannotConnect:
            return "AI needs attention"
        }
    }

    private func setupStatusCopy(for status: LLMSettingsViewModel.AISetupStatus) -> String {
        switch status {
        case .setUpNeeded:
            if viewModel.selectedProviderID != nil {
                return "Save and test this option before MacParakeet uses it."
            }
            return "Recording and transcription work now. Turn on AI when you want summaries, chat, meeting Ask, or Transforms."
        case .ready(let displayName):
            return "Ready: using \(displayName)."
        case .cannotConnect(let displayName, let message):
            return "MacParakeet could not reach \(displayName): \(message)"
        }
    }
}

private enum AISetupPath: String, CaseIterable, Identifiable {
    case localApp
    case apiKey
    case commandLine
    case customEndpoint

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .localApp:
            return "desktopcomputer"
        case .apiKey:
            return "key.fill"
        case .commandLine:
            return "terminal"
        case .customEndpoint:
            return "network"
        }
    }

    var title: String {
        switch self {
        case .localApp:
            return "Local AI app"
        case .apiKey:
            return "API key"
        case .commandLine:
            return "Command-line tool"
        case .customEndpoint:
            return "Custom API endpoint"
        }
    }

    var detail: String {
        switch self {
        case .localApp:
            return "LM Studio or Ollama. Best privacy, but you install the app and model first."
        case .apiKey:
            return "Claude, OpenAI, Gemini, or OpenRouter. Best if you already have an AI API key."
        case .commandLine:
            return "Codex, Claude Code, or a custom command. Best for agent workflows."
        case .customEndpoint:
            return "Connect another local server, gateway, or hosted API with a base URL."
        }
    }

    var badge: String? {
        switch self {
        case .localApp:
            return "Recommended"
        case .commandLine:
            return "Advanced"
        case .apiKey, .customEndpoint:
            return nil
        }
    }
}

private struct LocalModelSetupHint {
    let message: String
    let downloadLabel: String
    let downloadURL: URL
}

private struct AIFormatterActivationToggle: View {
    @Binding var isOn: Bool
    let isAvailable: Bool
    let disabledReason: String?

    var body: some View {
        Toggle("AI Formatter", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(AIFormatterActivationToggleStyle())
            .disabled(!isAvailable)
            .help(disabledReason ?? "Run AI formatting after the standard cleanup step.")
            .accessibilityLabel("AI Formatter")
            .accessibilityValue(isOn ? "Enabled" : "Disabled")
            .accessibilityHint(disabledReason ?? "Runs after local transcription cleanup as the final output step.")
    }
}

private struct AIFormatterActivationToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: configuration.isOn ? "sparkles" : "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconTint(isOn: configuration.isOn))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(iconBackground(isOn: configuration.isOn))
                    )
                    .accessibilityHidden(true)

                Text(labelText(isOn: configuration.isOn))
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(labelTint(isOn: configuration.isOn))
                    .lineLimit(1)

                Spacer(minLength: 4)

                switchTrack(isOn: configuration.isOn)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .frame(width: 164, height: 38)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(controlBackground(isOn: configuration.isOn))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(controlBorder(isOn: configuration.isOn), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private func switchTrack(isOn: Bool) -> some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(trackBackground(isOn: isOn))
                .overlay(
                    Capsule()
                        .strokeBorder(trackBorder(isOn: isOn), lineWidth: 1)
                )

            Circle()
                .fill(knobFill(isOn: isOn))
                .frame(width: 14, height: 14)
                .padding(2)
                .shadow(color: .black.opacity(isOn && isEnabled ? 0.18 : 0), radius: 2, y: 1)
        }
        .frame(width: 34, height: 18)
        .accessibilityHidden(true)
    }

    private func labelText(isOn: Bool) -> String {
        guard isEnabled else { return "Unavailable" }
        return isOn ? "Enabled" : "Enable"
    }

    private func iconTint(isOn: Bool) -> Color {
        if !isEnabled { return DesignSystem.Colors.textTertiary }
        return isOn ? DesignSystem.Colors.onAccent : DesignSystem.Colors.accent
    }

    private func iconBackground(isOn: Bool) -> Color {
        if !isEnabled { return DesignSystem.Colors.surfaceElevated.opacity(0.75) }
        return isOn ? DesignSystem.Colors.accent : DesignSystem.Colors.accent.opacity(0.12)
    }

    private func labelTint(isOn: Bool) -> Color {
        if !isEnabled { return DesignSystem.Colors.textTertiary }
        return isOn ? DesignSystem.Colors.accentDark : DesignSystem.Colors.textSecondary
    }

    private func controlBackground(isOn: Bool) -> Color {
        if !isEnabled { return DesignSystem.Colors.surfaceElevated.opacity(0.45) }
        return isOn ? DesignSystem.Colors.accentLight : DesignSystem.Colors.surfaceElevated
    }

    private func controlBorder(isOn: Bool) -> Color {
        if !isEnabled { return DesignSystem.Colors.border.opacity(0.45) }
        return isOn ? DesignSystem.Colors.accent.opacity(0.45) : DesignSystem.Colors.border.opacity(0.75)
    }

    private func trackBackground(isOn: Bool) -> Color {
        if !isEnabled { return DesignSystem.Colors.border.opacity(0.35) }
        return isOn ? DesignSystem.Colors.accent : DesignSystem.Colors.border.opacity(0.35)
    }

    private func trackBorder(isOn: Bool) -> Color {
        if !isEnabled { return Color.clear }
        return isOn ? DesignSystem.Colors.accent.opacity(0.35) : DesignSystem.Colors.border.opacity(0.75)
    }

    private func knobFill(isOn: Bool) -> Color {
        if !isEnabled { return DesignSystem.Colors.textTertiary.opacity(0.45) }
        return isOn ? DesignSystem.Colors.onAccent : DesignSystem.Colors.textSecondary
    }
}
