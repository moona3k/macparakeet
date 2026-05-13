import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Native Transform Workbench: select a Transform, tune its shortcut/rules,
/// attach writing samples, and review local run history in one persistent
/// workspace.
struct TransformsView: View {
    @Bindable var viewModel: TransformsViewModel
    let llmConfiguredAction: () -> Void
    let reservedHotkeys: [TransformShortcutReservedHotkey]
    let onShortcutRecordingStateChanged: (Bool) -> Void
    let onBindingsChanged: () -> Void

    @State private var isRecordingShortcut = false
    @State private var showBuiltInPrompt = false
    @State private var pendingDraftNavigation: PendingDraftNavigation?
    private let collisionChecker = TransformsHotkeyCollisionChecker()

    private enum PendingDraftNavigation {
        case select(Prompt)
        case create
        case cancelCreate
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 292)
                .background(DesignSystem.Colors.surface)

            Divider()

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignSystem.Colors.background)
        }
        .onAppear {
            viewModel.load()
            viewModel.loadProfiles()
            viewModel.loadWritingSamples()
            Task {
                await viewModel.loadHistory()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .transformHistoryChanged)) { _ in
            Task {
                await viewModel.loadHistory()
            }
        }
        .alert(
            "Delete this Transform?",
            isPresented: Binding(
                get: { viewModel.pendingDeleteTransform != nil },
                set: { if !$0 { viewModel.pendingDeleteTransform = nil } }
            ),
            presenting: viewModel.pendingDeleteTransform
        ) { _ in
            Button("Delete", role: .destructive) {
                viewModel.confirmPendingDelete()
                onBindingsChanged()
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingDeleteTransform = nil
            }
        } message: { transform in
            Text("“\(transform.name)” and its local run history will be removed.")
        }
        .alert(
            "Delete history item?",
            isPresented: Binding(
                get: { viewModel.pendingDeleteHistoryEntry != nil },
                set: { if !$0 { viewModel.pendingDeleteHistoryEntry = nil } }
            ),
            presenting: viewModel.pendingDeleteHistoryEntry
        ) { entry in
            Button("Delete", role: .destructive) {
                viewModel.pendingDeleteHistoryEntry = nil
                Task {
                    await viewModel.deleteHistoryEntry(entry)
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingDeleteHistoryEntry = nil
            }
        } message: { entry in
            Text("The saved “\(entry.transformName)” input and output will be removed from local history.")
        }
        .alert(
            "Delete writing sample?",
            isPresented: Binding(
                get: { viewModel.pendingDeleteWritingSample != nil },
                set: { if !$0 { viewModel.pendingDeleteWritingSample = nil } }
            ),
            presenting: viewModel.pendingDeleteWritingSample
        ) { _ in
            Button("Delete", role: .destructive) {
                viewModel.confirmPendingWritingSampleDelete()
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingDeleteWritingSample = nil
            }
        } message: { sample in
            Text("“\(sample.title)” will no longer be used as a voice reference.")
        }
        .alert("Clear this Transform's history?", isPresented: $viewModel.isConfirmingClearHistory) {
            Button("Clear Runs", role: .destructive) {
                Task {
                    await viewModel.clearSelectedHistory()
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.isConfirmingClearHistory = false
            }
        } message: {
            Text("This removes the saved inputs and outputs for the selected Transform from this Mac.")
        }
        .alert(
            "Discard unsaved changes?",
            isPresented: Binding(
                get: { pendingDraftNavigation != nil },
                set: { if !$0 { pendingDraftNavigation = nil } }
            )
        ) {
            Button("Discard Changes", role: .destructive) {
                performPendingDraftNavigation()
            }
            Button("Cancel", role: .cancel) {
                pendingDraftNavigation = nil
            }
        } message: {
            Text("Your current Transform edits have not been saved.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Transforms")
                    .font(DesignSystem.Typography.heroTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Rewrite selected text anywhere on your Mac with a hotkey.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(.top, DesignSystem.Spacing.lg)

            if !viewModel.hasLLMProvider {
                noProviderBanner
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    transformGroup(title: "Built in", transforms: viewModel.builtInTransforms)
                    if !viewModel.customTransforms.isEmpty {
                        transformGroup(title: "Custom", transforms: viewModel.customTransforms)
                    }

                    Button {
                        requestDraftNavigation(.create)
                    } label: {
                        Label("Create Transform", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .parakeetAction(.primary)
                    .padding(.top, DesignSystem.Spacing.sm)
                }
                .padding(.bottom, DesignSystem.Spacing.lg)
            }

            Spacer(minLength: 0)

            Button {
                viewModel.reseedMissingBuiltIns()
                onBindingsChanged()
            } label: {
                Label("Restore missing defaults", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .parakeetAction(.subtle)
            .controlSize(.small)
            .help("Recreate any built-in Transforms that are missing")
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.bottom, DesignSystem.Spacing.lg)
    }

    private var noProviderBanner: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label("LLM provider needed", systemImage: "wand.and.stars")
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("Transforms call your configured provider when you press a shortcut.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Button("Open Settings", action: llmConfiguredAction)
                .parakeetAction(.primary)
                .controlSize(.small)
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.accentLight)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .stroke(DesignSystem.Colors.accent.opacity(0.25), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func transformGroup(title: String, transforms: [Prompt]) -> some View {
        if !transforms.isEmpty {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(title.uppercased())
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                    .padding(.horizontal, 2)
                ForEach(transforms) { transform in
                    TransformListRow(
                        transform: transform,
                        isSelected: viewModel.selectedTransformID == transform.id && !viewModel.isCreatingDraft,
                        historyCount: viewModel.historyCountsByTransformID[transform.id] ?? 0,
                        action: {
                            requestDraftNavigation(.select(transform))
                        }
                    )
                }
            }
        }
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                headerSection

                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error)
                }

                shortcutSection
                rulesSection
                writingSamplesSection
                promptSection
                historySection
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    TextField("Name this Transform", text: $viewModel.draftName)
                        .textFieldStyle(.plain)
                        .font(DesignSystem.Typography.heroTitle)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .onChange(of: viewModel.draftName) { _, _ in revalidate() }

                    Text(viewModel.selectedTransform?.transformPurpose ?? "Create a reusable text rewrite and bind it to a shortcut.")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(maxWidth: 560, alignment: .leading)

                    if let error = viewModel.nameError {
                        InlineValidation(message: error)
                    }

                    runningLabelField
                }

                Spacer(minLength: DesignSystem.Spacing.lg)

                VStack(alignment: .trailing, spacing: DesignSystem.Spacing.sm) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        if viewModel.isCreatingDraft {
                            Button("Cancel") {
                                requestDraftNavigation(.cancelCreate)
                            }
                            .parakeetAction(.secondary)
                        } else if let selected = viewModel.selectedTransform {
                            if selected.isBuiltIn {
                                Button {
                                    if viewModel.resetBuiltIn(selected) {
                                        revalidate()
                                        onBindingsChanged()
                                    }
                                } label: {
                                    Label("Reset", systemImage: "arrow.counterclockwise")
                                }
                                .parakeetAction(.subtle)
                            } else {
                                Button(role: .destructive) {
                                    viewModel.pendingDeleteTransform = selected
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .parakeetAction(.destructive)
                            }
                        }

                        Button(viewModel.isCreatingDraft ? "Create" : "Save") {
                            if viewModel.saveDraft(
                                reservedHotkeys: activeReservedHotkeys,
                                collisionChecker: collisionChecker
                            ) {
                                onBindingsChanged()
                            }
                        }
                        .parakeetAction(.primaryProminent)
                        .disabled(!canSaveDraft)
                    }

                    Text(draftStatusText)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(viewModel.isDraftDirty ? DesignSystem.Colors.warningAmber : DesignSystem.Colors.textTertiary)
                }
            }
        }
        .padding(.bottom, DesignSystem.Spacing.sm)
    }

    private var shortcutSection: some View {
        WorkbenchSection(title: "Keyboard shortcut", subtitle: "Press this after selecting text in any app.") {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                ShortcutRecorderField(
                    shortcut: $viewModel.draftShortcut,
                    isRecording: $isRecordingShortcut,
                    onRecordingStateChanged: onShortcutRecordingStateChanged
                )
                .onChange(of: viewModel.draftShortcut) { _, _ in revalidate() }

                if let error = viewModel.shortcutError {
                    InlineValidation(message: error)
                } else if viewModel.draftShortcut == nil {
                    Text("Leave empty to keep this Transform dormant.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
            }
        }
    }

    private var runningLabelField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Progress label")
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(DesignSystem.Colors.textTertiary)
            TextField("Transforming...", text: $viewModel.draftRunningLabel)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(DesignSystem.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                }
                .accessibilityLabel("Transform progress label")
            Text("Shown in the floating pill while this Transform runs.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(.top, DesignSystem.Spacing.sm)
    }

    private var rulesSection: some View {
        WorkbenchSection(title: "Rules", subtitle: "Shape the behavior without editing the full prompt.") {
            VStack(spacing: 0) {
                ForEach(viewModel.activeRules) { rule in
                    RuleToggleRow(
                        rule: rule,
                        isOn: Binding(
                            get: { viewModel.draftEnabledRuleIDs.contains(rule.id) },
                            set: { enabled in
                                if enabled {
                                    viewModel.draftEnabledRuleIDs.insert(rule.id)
                                } else {
                                    viewModel.draftEnabledRuleIDs.remove(rule.id)
                                }
                            }
                        )
                    )
                    if rule.id != viewModel.activeRules.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var writingSamplesSection: some View {
        WorkbenchSection(title: "Writing samples", subtitle: "Optional local examples for matching your voice.") {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Toggle(isOn: Binding(
                    get: { viewModel.draftUseWritingSamples && viewModel.canUseWritingSamples },
                    set: { viewModel.setDraftUseWritingSamples($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Match my writing style")
                            .font(DesignSystem.Typography.body.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        Text("When enabled, samples are included only in Transform prompts sent to your configured LLM provider.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
                .toggleStyle(.switch)

                if viewModel.writingSamples.isEmpty && !viewModel.isAddingWritingSample {
                    WritingSamplesEmptyState {
                        viewModel.isAddingWritingSample = true
                    }
                } else {
                    VStack(spacing: DesignSystem.Spacing.sm) {
                        ForEach(viewModel.writingSamples) { sample in
                            WritingSampleRow(sample: sample) {
                                viewModel.pendingDeleteWritingSample = sample
                            }
                        }
                    }

                    Button {
                        viewModel.isAddingWritingSample = true
                    } label: {
                        Label("Add Sample", systemImage: "plus")
                    }
                    .parakeetAction(.subtle)
                    .controlSize(.small)
                }

                if viewModel.isAddingWritingSample {
                    WritingSampleEditor(viewModel: viewModel)
                }

                if let error = viewModel.writingSampleErrorMessage {
                    InlineValidation(message: error)
                }
            }
        }
    }

    @ViewBuilder
    private var promptSection: some View {
        if viewModel.isCreatingDraft || viewModel.selectedTransform?.isBuiltIn == false {
            promptEditorSection(title: "Instructions", subtitle: "Describe exactly how this Transform should rewrite selected text.")
        } else {
            DisclosureGroup(isExpanded: $showBuiltInPrompt) {
                promptEditorBody
                    .padding(.top, DesignSystem.Spacing.md)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced prompt")
                        .font(DesignSystem.Typography.sectionTitle)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("The built-in prompt remains editable, but most tuning belongs in rules above.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
            .padding(DesignSystem.Spacing.lg)
            .background(DesignSystem.Colors.surfaceElevated.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .stroke(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
            }
        }
    }

    private func promptEditorSection(title: String, subtitle: String) -> some View {
        WorkbenchSection(title: title, subtitle: subtitle) {
            promptEditorBody
        }
    }

    private var promptEditorBody: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            TextEditor(text: $viewModel.draftContent)
                .font(DesignSystem.Typography.body)
                .scrollContentBackground(.hidden)
                .padding(DesignSystem.Spacing.sm)
                .frame(minHeight: 168)
                .background(DesignSystem.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                }
                .accessibilityLabel("Transform prompt instructions")
                .onChange(of: viewModel.draftContent) { _, _ in revalidate() }

            TextEditor(text: $viewModel.draftCustomInstructions)
                .font(DesignSystem.Typography.body)
                .scrollContentBackground(.hidden)
                .padding(DesignSystem.Spacing.sm)
                .frame(minHeight: 86)
                .background(DesignSystem.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if viewModel.draftCustomInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Optional extra instructions")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                            .padding(.horizontal, DesignSystem.Spacing.md + 1)
                            .padding(.vertical, DesignSystem.Spacing.md)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                }
                .accessibilityLabel("Optional extra instructions")

            if let error = viewModel.contentError {
                InlineValidation(message: error)
            }
        }
    }

    private var historySection: some View {
        WorkbenchSection(
            title: "Recent runs",
            subtitle: viewModel.selectedTransform == nil ? "Create the Transform to start saving local runs." : "Local input and output history for this Transform."
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                if let historyError = viewModel.historyErrorMessage {
                    ErrorBanner(message: historyError)
                } else if viewModel.selectedHistory.isEmpty {
                    TransformHistoryEmptyState()
                } else {
                    HStack {
                        Text("\(viewModel.selectedHistoryTotalCount) saved")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Spacer()
                        Button(role: .destructive) {
                            viewModel.isConfirmingClearHistory = true
                        } label: {
                            Label("Clear Runs", systemImage: "trash")
                        }
                        .parakeetAction(.subtle)
                        .controlSize(.small)
                    }

                    LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        ForEach(viewModel.selectedHistory.prefix(8)) { entry in
                            TransformHistoryRow(
                                entry: entry,
                                isCopied: viewModel.copiedHistoryEntryID == entry.id,
                                onCopy: {
                                    Task {
                                        await viewModel.copyOutputToClipboard(entry)
                                    }
                                },
                                onDelete: { viewModel.pendingDeleteHistoryEntry = entry }
                            )
                        }
                    }
                }
            }
        }
    }

    private var activeReservedHotkeys: [TransformShortcutReservedHotkey] {
        reservedHotkeys.filter { !$0.trigger.isDisabled }
    }

    private var canSaveDraft: Bool {
        viewModel.normalizedDraftName.isEmpty == false
            && viewModel.draftContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && viewModel.nameError == nil
            && viewModel.contentError == nil
            && viewModel.shortcutError == nil
    }

    private var draftStatusText: String {
        if viewModel.isCreatingDraft {
            return "Not saved yet"
        }
        return viewModel.isDraftDirty ? "Unsaved changes" : "Saved locally"
    }

    private func revalidate() {
        viewModel.validateDraft(
            reservedHotkeys: activeReservedHotkeys,
            collisionChecker: collisionChecker
        )
    }

    private func requestDraftNavigation(_ navigation: PendingDraftNavigation) {
        if case .select(let prompt) = navigation,
           viewModel.selectedTransformID == prompt.id,
           !viewModel.isCreatingDraft {
            return
        }
        guard viewModel.hasUnsavedDraft else {
            performDraftNavigation(navigation)
            return
        }
        pendingDraftNavigation = navigation
    }

    private func performPendingDraftNavigation() {
        guard let navigation = pendingDraftNavigation else { return }
        pendingDraftNavigation = nil
        performDraftNavigation(navigation)
    }

    private func performDraftNavigation(_ navigation: PendingDraftNavigation) {
        switch navigation {
        case .select(let prompt):
            showBuiltInPrompt = false
            viewModel.selectTransform(prompt)
        case .create:
            showBuiltInPrompt = true
            viewModel.startCreatingTransform()
        case .cancelCreate:
            viewModel.cancelCreate()
        }
    }
}

private struct TransformListRow: View {
    let transform: Prompt
    let isSelected: Bool
    let historyCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(transform.name)
                            .font(DesignSystem.Typography.body.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                        if transform.isBuiltIn {
                            Text("Built in")
                                .font(DesignSystem.Typography.micro)
                                .foregroundStyle(DesignSystem.Colors.textTertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                        }
                    }

                    HStack(spacing: DesignSystem.Spacing.xs) {
                        if let shortcut = transform.shortcut {
                            KeycapBadge(shortcut: shortcut)
                        } else {
                            Text("No shortcut")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textTertiary)
                        }
                        if historyCount > 0 {
                            Text("\(historyCount)")
                                .font(DesignSystem.Typography.micro)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.7)))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(isSelected ? DesignSystem.Colors.accentLight : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? DesignSystem.Colors.accent.opacity(0.35) : Color.clear, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct WorkbenchSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            content
        }
        .padding(DesignSystem.Spacing.lg)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .stroke(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        }
    }
}

private struct RuleToggleRow: View {
    let rule: TransformRule
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.title)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(rule.detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, DesignSystem.Spacing.md)
    }
}

private struct WritingSamplesEmptyState: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(DesignSystem.Colors.surface))
            VStack(alignment: .leading, spacing: 3) {
                Text("No writing samples yet")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Add one sample of 50+ words to unlock voice matching.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()
            Button("Add Sample", action: action)
                .parakeetAction(.primary)
                .controlSize(.small)
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct WritingSampleRow: View {
    let sample: WritingSample
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(sample.title)
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                Text("\(sample.wordCount) words")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .help("Delete writing sample")
            .accessibilityLabel("Delete writing sample \(sample.title)")
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct WritingSampleEditor: View {
    @Bindable var viewModel: TransformsViewModel

    private var wordCount: Int {
        WritingSample.countWords(in: viewModel.writingSampleText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            TextField("Sample title", text: $viewModel.writingSampleTitle)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(DesignSystem.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                }

            TextEditor(text: $viewModel.writingSampleText)
                .font(DesignSystem.Typography.body)
                .scrollContentBackground(.hidden)
                .padding(DesignSystem.Spacing.sm)
                .frame(minHeight: 150)
                .background(DesignSystem.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if viewModel.writingSampleText.isEmpty {
                        Text("Paste a real email, message, document excerpt, or note that sounds like you.")
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                            .padding(.horizontal, DesignSystem.Spacing.md + 1)
                            .padding(.vertical, DesignSystem.Spacing.md)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                }
                .accessibilityLabel("Writing sample text")

            HStack {
                Text("\(wordCount)/\(TransformsViewModel.minimumWritingSampleWords) words")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(wordCount >= TransformsViewModel.minimumWritingSampleWords ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textTertiary)
                Spacer()
                Button("Cancel") {
                    viewModel.isAddingWritingSample = false
                    viewModel.writingSampleTitle = ""
                    viewModel.writingSampleText = ""
                    viewModel.writingSampleErrorMessage = nil
                }
                .parakeetAction(.secondary)
                Button("Save Sample") {
                    _ = viewModel.saveWritingSample()
                }
                .parakeetAction(.primary)
                .disabled(wordCount < TransformsViewModel.minimumWritingSampleWords)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TransformHistoryEmptyState: View {
    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textTertiary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(DesignSystem.Colors.surface))

            VStack(alignment: .leading, spacing: 3) {
                Text("No saved runs yet")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Completed edits for this Transform will appear here.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TransformHistoryRow: View {
    let entry: TransformHistoryEntry
    let isCopied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text(entry.sourceAppDisplayName)
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                Text(formatTime(entry.createdAt))
                    .font(DesignSystem.Typography.timestamp)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                if isCopied {
                    Text("Copied")
                        .font(DesignSystem.Typography.micro)
                        .foregroundStyle(DesignSystem.Colors.successGreen)
                }
                Button(action: onCopy) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .help("Copy transformed text")
                .accessibilityLabel("Copy \(entry.transformName) output from \(entry.sourceAppDisplayName)")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .help("Delete history item")
                .accessibilityLabel("Delete \(entry.transformName) history item from \(entry.sourceAppDisplayName)")
            }

            Text(entry.outputText)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.inputText)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(2)
                .padding(.leading, DesignSystem.Spacing.md)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(DesignSystem.Colors.border)
                        .frame(width: 2)
                }
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        return formatter.string(from: date)
    }
}

private struct InlineValidation: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.warningAmber)
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.warningAmber)
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
        }
        .padding(DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
    }
}

struct KeycapBadge: View {
    let shortcut: TransformShortcut

    var body: some View {
        HStack(spacing: 4) {
            ForEach(orderedModifierGlyphs, id: \.self) { glyph in
                Text(glyph)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, 6)
                    .background(DesignSystem.Colors.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                    }
            }
            Text(shortcut.keyLabel.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .frame(minWidth: 22, minHeight: 22)
                .padding(.horizontal, 6)
                .background(DesignSystem.Colors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                }
        }
    }

    private var orderedModifierGlyphs: [String] {
        let ordered: [TransformShortcut.ModifierFlag] = [.control, .option, .shift, .command]
        return ordered
            .filter { (shortcut.modifiers & $0.rawValue) != 0 }
            .map(\.displayGlyph)
    }
}
