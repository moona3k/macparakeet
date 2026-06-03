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

            if AppFeatures.aiFormatterProfilesEnabled {
                Divider()

                aiFormatterProfilesSection
                    .id("ai.formatter")
            }
        }
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
                    Text("Override the global formatter prompt for specific app bundle IDs or broad app categories.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Exact app profiles take precedence over category profiles; the global prompt remains the fallback.")
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
                    Picker("Profile type", selection: profileDraftBinding(\.targetKind, fallback: .bundle)) {
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
            } else {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Category")
                        .font(DesignSystem.Typography.caption.weight(.medium))
                    Picker("Category", selection: profileDraftBinding(\.appCategory, fallback: .messaging)) {
                        ForEach(TelemetryAppCategory.allCases, id: \.self) { category in
                            Text(categoryTitle(category)).tag(category)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Text("Prompt")
                        .font(DesignSystem.Typography.caption.weight(.medium))
                    Spacer()
                    Button("Use Global Prompt") {
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

    private func profileDraftBinding<Value>(
        _ keyPath: WritableKeyPath<LLMSettingsViewModel.AIFormatterProfileDraft, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { viewModel.aiFormatterProfileDraft?[keyPath: keyPath] ?? fallback },
            set: { viewModel.updateAIFormatterProfileDraft(keyPath, to: $0) }
        )
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
        profile.promptTemplate == AIFormatter.defaultPromptTemplate
            ? "Default prompt"
            : "Custom prompt"
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
        if !isEnabled { return DesignSystem.Colors.textTertiary.opacity(0.55) }
        return isOn ? DesignSystem.Colors.onAccent : DesignSystem.Colors.textSecondary
    }
}
