import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

private struct AIFormatterInstalledApp: Identifiable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let path: String

    var id: String { bundleIdentifier }
}

struct LLMSettingsView: View {
    @Bindable var viewModel: LLMSettingsViewModel

    @State private var showAdvanced = false
    @State private var showAIFormatterPrompt = false
    @State private var showAIFormatterCustomProfiles = false
    @State private var showAIFormatterAppPicker = false
    @State private var showAIFormatterBundleFields = false
    @State private var aiFormatterAppSearch = ""
    @State private var aiFormatterInstalledApps: [AIFormatterInstalledApp] = []
    @State private var isLoadingAIFormatterInstalledApps = false

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

    private static let smartDefaultGridColumns = [
        GridItem(.adaptive(minimum: 112), spacing: DesignSystem.Spacing.sm)
    ]

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            setupStatusSection

            Divider()

            selectedAIOptionSection

            if viewModel.selectedProviderID != nil {
                Divider()

                // API key (hidden for providers that cannot use one)
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
                        SecureField(viewModel.apiKeyPlaceholder, text: $viewModel.apiKeyInput)
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
                    .parakeetAction(.secondary)
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

            configurationActionsRow

            Divider()

            transcriptAIContextSection

            Divider()

            aiFormatterSection
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
                Text("AI for summaries, chat, meeting Ask, and Transforms")
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

    private var selectedAIOptionSection: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current choice")
                        .font(DesignSystem.Typography.body)
                    Text("Choose a local provider, an API key, or a command-line AI tool.")
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
                    Text("Local providers, API keys, and command-line tools are available from this menu.")
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
            return "Choose how MacParakeet should run AI features. Transcription, dictation, and meeting recording still work without this."
        case .ready(let displayName):
            return "Ready: using \(displayName)."
        case .cannotConnect(let displayName, let message):
            return "MacParakeet could not reach \(displayName): \(message)"
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

    private var transcriptAIContextSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Transcript context for AI")
                        .font(DesignSystem.Typography.body.weight(.semibold))
                    Text("Controls what summaries, transcript chat, and Meeting Ask send to your AI provider.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                Picker("Transcript context for AI", selection: $viewModel.transcriptAIContextMode) {
                    ForEach(TranscriptAIContextMode.allCases) { mode in
                        Text(mode.displayTitle).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 300)
            }

            Text(viewModel.transcriptAIContextMode.detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.transcriptAIContextMode == .richTranscript {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text("Speaker labels are a rough reference from audio-source separation and diarization, not a high-accuracy identification of who said each line.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .id("ai.transcriptContext")
    }

    @ViewBuilder
    private var aiFormatterSection: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
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
                        Text("Uses the saved LLM provider after cleanup for file and meeting transcripts. Dictation use can add latency.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: DesignSystem.Spacing.md)

                    if viewModel.isAIFormatterAvailable {
                        Toggle("Use for dictation", isOn: $viewModel.aiFormatterEnabledForDictation)
                            .toggleStyle(.switch)
                            .font(DesignSystem.Typography.caption.weight(.medium))
                            .fixedSize()
                    }
                }

                if let disabledReason = viewModel.aiFormatterUnavailableReason {
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

            if AppFeatures.aiFormatterProfilesEnabled {
                aiFormatterSmartDefaultsSection
            }

            aiFormatterPromptDisclosure

            if AppFeatures.aiFormatterProfilesEnabled {
                Divider()

                if viewModel.aiFormatterProfiles.isEmpty, viewModel.aiFormatterProfileDraft == nil {
                    DisclosureGroup("Advanced custom profiles", isExpanded: $showAIFormatterCustomProfiles) {
                        aiFormatterProfilesSection
                            .padding(.top, DesignSystem.Spacing.sm)
                    }
                    .font(DesignSystem.Typography.caption)
                    .id("ai.formatter")
                } else {
                    aiFormatterProfilesSection
                        .id("ai.formatter")
                }
            }
        }
    }

    private var aiFormatterSmartDefaultsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: 7) {
                Text("Smart defaults")
                    .font(DesignSystem.Typography.body)
                Text("On")
                    .font(DesignSystem.Typography.micro.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.successGreen)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DesignSystem.Colors.successGreen.opacity(0.10)))
            }
            Text("Custom app profiles override custom category profiles; unknown apps use the fallback prompt.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: Self.smartDefaultGridColumns, alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ForEach(AIFormatterSmartDefaults.categoryDefaults) { categoryDefault in
                    HStack(spacing: 6) {
                        Image(systemName: smartDefaultIcon(for: categoryDefault.category))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.accent)
                            .frame(width: 16, height: 16)
                        Text(categoryDefault.name)
                            .font(DesignSystem.Typography.caption.weight(.medium))
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .fill(DesignSystem.Colors.surfaceElevated)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var aiFormatterPromptDisclosure: some View {
        DisclosureGroup("Customize fallback prompt", isExpanded: $showAIFormatterPrompt) {
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
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $viewModel.aiFormatterPrompt)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .disabled(!viewModel.isAIFormatterAvailable)
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
            .padding(.top, DesignSystem.Spacing.sm)
        }
        .font(DesignSystem.Typography.caption)
    }

    @ViewBuilder
    private var aiFormatterProfilesSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text("Profiles")
                            .font(DesignSystem.Typography.body.weight(.semibold))
                        if !viewModel.aiFormatterProfiles.isEmpty {
                            Text(profileCountText)
                                .font(DesignSystem.Typography.micro.weight(.semibold))
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(DesignSystem.Colors.surfaceElevated)
                                )
                        }
                    }
                    Text("Override smart defaults for specific app bundle IDs or broad app categories.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Precedence: app profile, category profile, smart default, fallback prompt.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DesignSystem.Spacing.md)

                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button {
                        viewModel.startCreatingAIFormatterProfile(targetKind: .bundle)
                    } label: {
                        Label("Add App", systemImage: "app.badge")
                    }
                    .parakeetAction(.secondary)
                    .disabled(!viewModel.canManageAIFormatterProfiles)

                    Button {
                        viewModel.startCreatingAIFormatterProfile(targetKind: .category)
                    } label: {
                        Label("Add Category", systemImage: "square.grid.2x2")
                    }
                    .parakeetAction(.secondary)
                    .disabled(!viewModel.canManageAIFormatterProfiles)
                }
            }

            if let error = viewModel.aiFormatterProfileError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.warningAmber)
                    Text(error)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.warningAmber)
                }
            }

            if let draft = viewModel.aiFormatterProfileDraft {
                aiFormatterProfileEditor(draft)
            }

            if viewModel.aiFormatterProfiles.isEmpty {
                Text("No profiles yet.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DesignSystem.Spacing.xs)
            } else {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(viewModel.aiFormatterProfiles) { profile in
                        aiFormatterProfileRow(profile)
                    }
                }
            }
        }
    }

    private var profileCountText: String {
        let count = viewModel.aiFormatterProfiles.count
        return count == 1 ? "1 profile" : "\(count) profiles"
    }

    private func aiFormatterProfileRow(_ profile: AIFormatterProfile) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: profile.targetKind == .bundle ? "app" : "square.grid.2x2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(DesignSystem.Colors.accent.opacity(0.10)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(profile.name)
                        .font(DesignSystem.Typography.body.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(profilePromptModeText(profile))
                        .font(DesignSystem.Typography.micro.weight(.semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.background)
                        )
                }
                Text(profileTargetText(profile))
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            Toggle(
                "",
                isOn: Binding(
                    get: { profile.isEnabled },
                    set: { viewModel.setAIFormatterProfile(profile, enabled: $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Enable \(profile.name)")
            .accessibilityValue(profile.isEnabled ? "Enabled" : "Disabled")

            Button {
                viewModel.editAIFormatterProfile(profile)
            } label: {
                Image(systemName: "pencil")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Edit profile")
            .accessibilityLabel("Edit \(profile.name)")

            Button(role: .destructive) {
                viewModel.deleteAIFormatterProfile(profile)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignSystem.Colors.errorRed)
            .help("Delete profile")
            .accessibilityLabel("Delete \(profile.name)")
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private func aiFormatterProfileEditor(_ draft: LLMSettingsViewModel.AIFormatterProfileDraft) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .center) {
                Text(draft.profileID == nil ? "New profile" : "Edit profile")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                Spacer()
                Toggle(
                    "Enabled",
                    isOn: profileDraftBinding(\.isEnabled, fallback: true)
                )
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Type")
                        .font(DesignSystem.Typography.caption.weight(.medium))
                    Picker("Profile type", selection: profileDraftTargetKindBinding) {
                        Text("App").tag(AIFormatterProfileTargetKind.bundle)
                        Text("Category").tag(AIFormatterProfileTargetKind.category)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Name")
                        .font(DesignSystem.Typography.caption.weight(.medium))
                    TextField(
                        "Profile name",
                        text: profileDraftBinding(\.name, fallback: "")
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                }
            }

            if draft.targetKind == .bundle {
                aiFormatterAppProfileTargetEditor(draft)
            } else {
                aiFormatterCategoryProfileTargetEditor(draft)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Text("Prompt")
                        .font(DesignSystem.Typography.caption.weight(.medium))
                    Spacer()
                    Button("Use Fallback Prompt") {
                        viewModel.updateAIFormatterProfileDraft(
                            \.promptTemplate,
                            to: viewModel.aiFormatterPrompt
                        )
                    }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: profileDraftBinding(\.promptTemplate, fallback: AIFormatter.defaultPromptTemplate))
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 150)
                .background(DesignSystem.Colors.background)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
                )
            }

            if let validationMessage = draft.validationMessage {
                Text(validationMessage)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button("Save Profile") {
                    _ = viewModel.saveAIFormatterProfileDraft()
                }
                .parakeetAction(.primaryProminent)
                .disabled(!draft.canSave)

                Button("Cancel") {
                    viewModel.cancelAIFormatterProfileEdit()
                }
                .parakeetAction(.secondary)

                Spacer()
            }
        }
        .padding(.top, DesignSystem.Spacing.xs)
    }

    private func aiFormatterAppProfileTargetEditor(
        _ draft: LLMSettingsViewModel.AIFormatterProfileDraft
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("App")
                .font(DesignSystem.Typography.caption.weight(.medium))

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    showAIFormatterAppPicker = true
                    loadAIFormatterInstalledAppsIfNeeded()
                } label: {
                    Label("Choose App", systemImage: "app.badge")
                }
                .parakeetAction(.secondary)
                .popover(isPresented: $showAIFormatterAppPicker, arrowEdge: .bottom) {
                    aiFormatterAppPicker
                }
            }

            aiFormatterProfileMatchPreview(draft)

            DisclosureGroup("Manual bundle details", isExpanded: $showAIFormatterBundleFields) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Bundle ID")
                            .font(DesignSystem.Typography.caption.weight(.medium))
                        TextField(
                            "com.example.app",
                            text: profileDraftBinding(\.bundleIdentifier, fallback: "")
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Display name")
                            .font(DesignSystem.Typography.caption.weight(.medium))
                        TextField(
                            "Optional",
                            text: profileDraftBinding(\.appDisplayName, fallback: "")
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    }
                }
                .padding(.top, DesignSystem.Spacing.sm)
            }
            .font(DesignSystem.Typography.caption)
        }
    }

    private func aiFormatterCategoryProfileTargetEditor(
        _ draft: LLMSettingsViewModel.AIFormatterProfileDraft
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Category")
                .font(DesignSystem.Typography.caption.weight(.medium))
            Picker("Category", selection: profileDraftCategoryBinding) {
                ForEach(TelemetryAppCategory.allCases, id: \.self) { category in
                    Text(categoryTitle(category)).tag(category)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 220)

            aiFormatterProfileMatchPreview(draft)
        }
    }

    private var aiFormatterAppPicker: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            TextField("Search apps", text: $aiFormatterAppSearch)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if isLoadingAIFormatterInstalledApps, aiFormatterInstalledApps.isEmpty {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading apps...")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, DesignSystem.Spacing.md)
                    } else if filteredAIFormatterInstalledApps.isEmpty {
                        Text("No apps found.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, DesignSystem.Spacing.md)
                    } else {
                        ForEach(filteredAIFormatterInstalledApps) { app in
                            Button {
                                selectAIFormatterInstalledApp(app)
                            } label: {
                                HStack(spacing: DesignSystem.Spacing.sm) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                        .resizable()
                                        .frame(width: 22, height: 22)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(app.displayName)
                                            .font(DesignSystem.Typography.caption.weight(.medium))
                                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                                        Text(app.bundleIdentifier)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: DesignSystem.Spacing.sm)
                                    if viewModel.aiFormatterProfileDraft?.bundleIdentifier == app.bundleIdentifier {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(DesignSystem.Colors.accent)
                                    }
                                }
                                .padding(.horizontal, DesignSystem.Spacing.sm)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(height: 280)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(width: 380)
        .onAppear {
            loadAIFormatterInstalledAppsIfNeeded()
        }
    }

    private func aiFormatterProfileMatchPreview(
        _ draft: LLMSettingsViewModel.AIFormatterProfileDraft
    ) -> some View {
        let context = aiFormatterDraftContext(draft)
        let resolution = viewModel.aiFormatterPromptPreview(for: context, including: draft)

        return HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: draft.targetKind == .bundle ? "app" : smartDefaultIcon(for: draft.appCategory))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(DesignSystem.Colors.accent.opacity(0.10)))

            VStack(alignment: .leading, spacing: 2) {
                Text(aiFormatterDraftTargetText(draft))
                    .font(DesignSystem.Typography.caption.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                Text(aiFormatterResolutionSourceText(resolution))
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private func profileDraftBinding<Value>(
        _ keyPath: WritableKeyPath<LLMSettingsViewModel.AIFormatterProfileDraft, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { viewModel.aiFormatterProfileDraft?[keyPath: keyPath] ?? fallback },
            set: { viewModel.updateAIFormatterProfileDraft(keyPath, to: $0) }
        )
    }

    private var profileDraftCategoryBinding: Binding<TelemetryAppCategory> {
        Binding(
            get: { viewModel.aiFormatterProfileDraft?.appCategory ?? .messaging },
            set: { viewModel.applyAIFormatterProfileDraftCategory($0) }
        )
    }

    private var profileDraftTargetKindBinding: Binding<AIFormatterProfileTargetKind> {
        Binding(
            get: { viewModel.aiFormatterProfileDraft?.targetKind ?? .bundle },
            set: { viewModel.applyAIFormatterProfileDraftTargetKind($0) }
        )
    }

    private var filteredAIFormatterInstalledApps: [AIFormatterInstalledApp] {
        let query = aiFormatterAppSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return aiFormatterInstalledApps }
        return aiFormatterInstalledApps.filter { app in
            app.displayName.localizedCaseInsensitiveContains(query)
                || app.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    private func selectAIFormatterInstalledApp(_ app: AIFormatterInstalledApp) {
        viewModel.applyAIFormatterProfileDraftApp(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.displayName
        )
        showAIFormatterAppPicker = false
    }

    private func loadAIFormatterInstalledAppsIfNeeded() {
        guard aiFormatterInstalledApps.isEmpty, !isLoadingAIFormatterInstalledApps else { return }
        isLoadingAIFormatterInstalledApps = true
        Task { @MainActor in
            let apps = await Task.detached(priority: .userInitiated) {
                Self.discoverInstalledApps()
            }.value
            aiFormatterInstalledApps = apps
            isLoadingAIFormatterInstalledApps = false
        }
    }

    private func aiFormatterDraftContext(
        _ draft: LLMSettingsViewModel.AIFormatterProfileDraft
    ) -> AppPromptContext? {
        switch draft.targetKind {
        case .bundle:
            guard AppPromptContext.normalizedBundleIdentifier(draft.bundleIdentifier) != nil else {
                return nil
            }
            return AppPromptContext(
                bundleIdentifier: draft.bundleIdentifier,
                displayName: draft.appDisplayName,
                category: draft.appCategory
            )
        case .category:
            return AppPromptContext(
                bundleIdentifier: nil,
                displayName: categoryTitle(draft.appCategory),
                category: draft.appCategory
            )
        }
    }

    private func aiFormatterDraftTargetText(
        _ draft: LLMSettingsViewModel.AIFormatterProfileDraft
    ) -> String {
        switch draft.targetKind {
        case .bundle:
            let bundleIdentifier = draft.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = draft.appDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !displayName.isEmpty, !bundleIdentifier.isEmpty {
                return "\(displayName) · \(categoryTitle(draft.appCategory))"
            }
            if !bundleIdentifier.isEmpty {
                return "\(bundleIdentifier) · \(categoryTitle(draft.appCategory))"
            }
            return "No app selected"
        case .category:
            return categoryTitle(draft.appCategory)
        }
    }

    private func aiFormatterResolutionSourceText(_ resolution: AIFormatterPromptResolution) -> String {
        switch (resolution.matchKind, resolution.profileOrigin) {
        case (.exactApp, .some(.custom)):
            return "Custom app profile: \(resolution.profileName ?? "App")"
        case (.category, .some(.custom)):
            return "Custom category profile: \(resolution.profileName ?? "Category")"
        case (.category, .some(.template)):
            return "Smart default: \(resolution.profileName ?? "Category")"
        case (.global, _):
            return "Fallback prompt"
        default:
            return resolution.profileName ?? "Custom profile"
        }
    }

    nonisolated private static func discoverInstalledApps() -> [AIFormatterInstalledApp] {
        let fileManager = FileManager.default
        let userApplications = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let directories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            userApplications,
            userApplications.appendingPathComponent("Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        ]
        let selfBundleIdentifier = AppPromptContext.normalizedBundleIdentifier(Bundle.main.bundleIdentifier)
        var appsByBundleIdentifier: [String: AIFormatterInstalledApp] = [:]

        for directory in directories {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in urls where url.pathExtension == "app" {
                let plistURL = url
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Info.plist")
                guard let plistData = try? Data(contentsOf: plistURL),
                      let plistObject = try? PropertyListSerialization.propertyList(
                          from: plistData,
                          options: [],
                          format: nil
                      ),
                      let plist = plistObject as? [String: Any],
                      let rawBundleIdentifier = plist["CFBundleIdentifier"] as? String,
                      let bundleIdentifier = AppPromptContext.normalizedBundleIdentifier(rawBundleIdentifier),
                      bundleIdentifier != selfBundleIdentifier,
                      appsByBundleIdentifier[bundleIdentifier] == nil
                else { continue }

                let displayName = AppPromptContext.normalizedDisplayName(
                    plist["CFBundleDisplayName"] as? String
                        ?? plist["CFBundleName"] as? String
                        ?? url.deletingPathExtension().lastPathComponent
                ) ?? bundleIdentifier
                appsByBundleIdentifier[bundleIdentifier] = AIFormatterInstalledApp(
                    bundleIdentifier: bundleIdentifier,
                    displayName: displayName,
                    path: url.path
                )
            }
        }

        return appsByBundleIdentifier.values.sorted {
            let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return $0.bundleIdentifier < $1.bundleIdentifier
        }
    }

    private func profileTargetText(_ profile: AIFormatterProfile) -> String {
        switch profile.targetKind {
        case .bundle:
            let bundle = profile.bundleIdentifier ?? "Unknown bundle"
            if let displayName = profile.appDisplayName, !displayName.isEmpty {
                return "\(displayName) · \(bundle)"
            }
            return bundle
        case .category:
            return categoryTitle(profile.appCategory ?? .other)
        }
    }

    private func profilePromptModeText(_ profile: AIFormatterProfile) -> String {
        let promptTemplate = AIFormatter.normalizedPromptTemplate(profile.promptTemplate)
        if promptTemplate == AIFormatter.defaultPromptTemplate {
            return "Fallback prompt"
        }

        let category = profile.appCategory
            ?? profile.bundleIdentifier.map { TelemetryAppCategory(bundleIdentifier: $0) }
        if let category,
           let categoryDefault = AIFormatterSmartDefaults.categoryDefault(for: category),
           promptTemplate == AIFormatter.normalizedPromptTemplate(categoryDefault.promptTemplate) {
            return "Smart default"
        }

        return "Custom prompt"
    }

    private func categoryTitle(_ category: TelemetryAppCategory) -> String {
        switch category {
        case .messaging: return "Messaging"
        case .email: return "Email"
        case .browser: return "Browser"
        case .notes: return "Notes"
        case .docs: return "Documents"
        case .code: return "Code"
        case .terminal: return "Terminal"
        case .other: return "Other"
        }
    }

    private func smartDefaultIcon(for category: TelemetryAppCategory) -> String {
        switch category {
        case .messaging: return "bubble.left.and.bubble.right"
        case .email: return "envelope"
        case .browser: return "safari"
        case .notes: return "note.text"
        case .docs: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .terminal: return "terminal"
        case .other: return "sparkles"
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
                 ? "Transcript text is sent only to your local AI endpoint."
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

    private var configurationActionsRow: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Button("Save") {
                viewModel.saveConfiguration()
            }
            .parakeetAction(.primaryProminent)
            .disabled(!viewModel.canSave)

            if viewModel.isConfigured {
                Button("Clear", role: .destructive) {
                    viewModel.clearConfiguration()
                }
                .parakeetAction(.destructive)
            }

            saveStateIndicator

            Spacer()
        }
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
}
