import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct PromptLibraryView: View {
    private enum ContentMode: String, CaseIterable {
        case edit = "Edit"
        case preview = "Preview"
    }

    private enum PromptKindFilter: String, CaseIterable {
        case all = "All prompts"
        case results = "Results"
        case transforms = "Transforms"
    }

    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: PromptsViewModel
    var showsDismissButton = true
    @State private var editName: String = ""
    @State private var editContent: String = ""
    @State private var newContentMode: ContentMode = .edit
    @State private var editContentMode: ContentMode = .edit
    @State private var searchText = ""
    @State private var diffFromVersionID: UUID?
    @State private var diffToVersionID: UUID?
    @State private var versionDiff = PromptVersionDiffViewModel()
    @State private var collectionFilterID: UUID?
    @State private var promptKindFilter: PromptKindFilter = .all
    @State private var collectionDraftNames: [UUID: String] = [:]
    @State private var hoveredPromptId: UUID?
    @State private var expandedPromptIds: Set<UUID> = []
    @State private var showingDiscardConfirm = false
    @State private var pendingRestoreVersion: PromptVersion?
    /// Tracks which row currently owns keyboard focus so a Tab-only user
    /// gets the same icon brightening + AutoRunBadge reveal that a mouse
    /// user gets on hover.
    @FocusState private var focusedPromptId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt Manager")
                        .font(DesignSystem.Typography.heroTitle)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Manage the templates used for generating prompt results and custom outputs.")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Spacer()
                Picker("Prompt kind", selection: $promptKindFilter) {
                    ForEach(PromptKindFilter.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .frame(width: 135)
                if !viewModel.collections.isEmpty {
                    Picker("Collection", selection: $collectionFilterID) {
                        Text("All collections").tag(Optional<UUID>.none)
                        Divider()
                        ForEach(viewModel.collections) { collection in
                            Text(collection.name).tag(Optional(collection.id))
                        }
                    }
                    .frame(width: 170)
                }
                TextField("Search prompts", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .accessibilityLabel("Search prompts")
                if showsDismissButton {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(DesignSystem.Typography.body.weight(.semibold))
                            .padding(.horizontal, DesignSystem.Spacing.sm)
                    }
                    .parakeetAction(.primaryProminent)
                    .controlSize(.large)
                    // Esc dismisses (Apple HIG default for sheets).
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(DesignSystem.Spacing.xl)
            .background(DesignSystem.Colors.surface)

            Divider()

            // MARK: - Content
            ScrollView {
                VStack(spacing: DesignSystem.Spacing.xxl) {

                    // Error Banner
                    if let errorMessage = viewModel.errorMessage {
                        errorBanner(errorMessage)
                    }

                    collectionManager

                    // Built-In Prompts Section
                    sectionContainer(
                        title: "Built-In Prompts",
                        subtitle:
                            "Built-in prompts can be edited, configured, or removed just like your own prompts."
                    ) {
                        cardGroup {
                            let builtIns = filteredPrompts.filter(\.isBuiltIn)
                            ForEach(Array(builtIns.enumerated()), id: \.element.id) { index, prompt in
                                promptRow(prompt)
                                if index < builtIns.count - 1 { Divider().padding(.leading, 16) }
                            }
                        }
                    }

                    if !viewModel.deletedPrompts.isEmpty {
                        trashSection
                    }

                    // Custom Prompts Section
                    sectionContainer(
                        title: "My Prompts",
                        subtitle: "Custom prompts you've created. Edit, reorder, or remove anytime."
                    ) {
                        let customPrompts = filteredPrompts.filter { !$0.isBuiltIn }
                        if customPrompts.isEmpty {
                            emptyStateView
                        } else {
                            cardGroup {
                                ForEach(Array(customPrompts.enumerated()), id: \.element.id) { index, prompt in
                                    promptRow(prompt)
                                    if index < customPrompts.count - 1 { Divider().padding(.leading, 16) }
                                }
                            }
                        }
                    }

                    // Add Prompt Section
                    sectionContainer(
                        title: "Create New",
                        subtitle: "Design a new prompt tailored to your needs."
                    ) {
                        addPromptCard
                    }
                }
                .padding(DesignSystem.Spacing.xl)
            }
        }
        .background {
            ZStack {
                Rectangle().fill(.thickMaterial)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        MerkabaShape()
                            .stroke(DesignSystem.Colors.textTertiary.opacity(0.08), lineWidth: 1.5)
                            .frame(width: 400, height: 400)
                            .offset(x: 100, y: 100)
                            .rotationEffect(.degrees(15))
                    }
                }
            }
            .ignoresSafeArea()
        }
        .frame(minWidth: 720, minHeight: 700)
        .onAppear { viewModel.refresh() }
        .alert(
            "Delete Prompt?",
            isPresented: Binding(
                get: { viewModel.pendingDeletePrompt != nil },
                set: { if !$0 { viewModel.pendingDeletePrompt = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                withAnimation { viewModel.confirmDelete() }
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingDeletePrompt = nil
            }
        } message: {
            Text("This prompt will be removed from the library. Its version history is preserved.")
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.editingPrompt != nil },
                set: { if !$0 { viewModel.editingPrompt = nil } }
            ),
            onDismiss: {
                editName = ""
                editContent = ""
                editContentMode = .edit
                viewModel.cancelEditing()
            }
        ) {
            if let prompt = viewModel.editingPrompt {
                editSheet(prompt: prompt)
                    .alert("Discard changes?", isPresented: $showingDiscardConfirm) {
                        Button("Discard", role: .destructive) {
                            viewModel.cancelEditing()
                        }
                        Button("Keep editing", role: .cancel) {}
                    } message: {
                        Text("Your edits to '\(prompt.name)' will be lost.")
                    }
                    .confirmationDialog(
                        "Restore this version?",
                        isPresented: Binding(
                            get: { pendingRestoreVersion != nil },
                            set: { if !$0 { pendingRestoreVersion = nil } }
                        ),
                        titleVisibility: .visible
                    ) {
                        Button("Create restored version") {
                            if let version = pendingRestoreVersion {
                                restoreVersion(version)
                            }
                            pendingRestoreVersion = nil
                        }
                        Button("Cancel", role: .cancel) { pendingRestoreVersion = nil }
                    } message: {
                        Text(
                            "Restoring writes a new version immediately. Your current unsaved content and settings will be replaced."
                        )
                    }
            }
        }
    }

    /// Cancel button in the edit sheet. Confirms before throwing away typed
    /// work; silent dismiss when nothing changed (Mail-compose pattern).
    private func attemptCancelEdit(prompt: Prompt) {
        if viewModel.hasEditingChanges(prompt: prompt, name: editName, content: editContent) {
            showingDiscardConfirm = true
        } else {
            viewModel.cancelEditing()
        }
    }

    // MARK: - Components

    private var filteredPrompts: [Prompt] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.managedPrompts.filter {
            let matchesCollection = collectionFilterID == nil || $0.collectionId == collectionFilterID
            let matchesKind: Bool
            switch promptKindFilter {
            case .all: matchesKind = true
            case .results: matchesKind = $0.category == .result
            case .transforms: matchesKind = $0.category == .transform
            }
            let matchesQuery =
                query.isEmpty
                || $0.name.localizedCaseInsensitiveContains(query)
                || $0.content.localizedCaseInsensitiveContains(query)
            return matchesCollection && matchesKind && matchesQuery
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(DesignSystem.Typography.body.weight(.medium))
            Spacer()
        }
        .foregroundStyle(DesignSystem.Colors.errorRed)
        .padding()
        .background(DesignSystem.Colors.errorRed.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
    }

    private var collectionManager: some View {
        sectionContainer(
            title: "Collections",
            subtitle: "Organize result prompts and Transforms without changing their version history."
        ) {
            cardGroup {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.collections.enumerated()), id: \.element.id) { index, collection in
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            TextField(collection.name, text: collectionNameBinding(collection))
                                .textFieldStyle(.roundedBorder)
                            Button("Save") {
                                viewModel.renameCollection(
                                    collection,
                                    name: collectionDraftNames[collection.id] ?? collection.name
                                )
                            }
                            .parakeetAction(.secondary)
                            Button {
                                viewModel.moveCollection(collection, by: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.plain)
                            .disabled(index == 0)
                            Button {
                                viewModel.moveCollection(collection, by: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.plain)
                            .disabled(index == viewModel.collections.count - 1)
                            Button(role: .destructive) {
                                viewModel.deleteCollection(collection)
                                collectionDraftNames[collection.id] = nil
                                if collectionFilterID == collection.id { collectionFilterID = nil }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Delete collection")
                        }
                        .padding(DesignSystem.Spacing.md)
                        if index < viewModel.collections.count - 1 { Divider() }
                    }

                    if !viewModel.collections.isEmpty { Divider() }
                    HStack {
                        TextField("New collection", text: $viewModel.newCollectionName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { viewModel.createCollection() }
                        Button("Create") { viewModel.createCollection() }
                            .parakeetAction(.primaryProminent)
                            .disabled(
                                viewModel.newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(DesignSystem.Spacing.md)
                }
            }
        }
    }

    private func collectionNameBinding(_ collection: PromptCollection) -> Binding<String> {
        Binding(
            get: { collectionDraftNames[collection.id] ?? collection.name },
            set: { collectionDraftNames[collection.id] = $0 }
        )
    }

    private var trashSection: some View {
        sectionContainer(
            title: "Trash",
            subtitle: "Restore removed built-in or custom prompts with their complete version history."
        ) {
            cardGroup {
                ForEach(Array(viewModel.deletedPrompts.enumerated()), id: \.element.id) { index, prompt in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(prompt.name)
                                .font(DesignSystem.Typography.body.weight(.semibold))
                            Text(prompt.category == .transform ? "Transform" : "Result prompt")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        Spacer()
                        if prompt.isBuiltIn {
                            Text("Built-in")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        Button("Restore") { viewModel.restoreDeletedPrompt(prompt) }
                            .parakeetAction(.secondary)
                    }
                    .padding(DesignSystem.Spacing.md)
                    if index < viewModel.deletedPrompts.count - 1 { Divider() }
                }
            }
        }
    }

    private func sectionContainer<Header: View, Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder headerTrailing: () -> Header = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignSystem.Typography.sectionTitle)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(subtitle)
                        .font(DesignSystem.Typography.bodySmall)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Spacer()
                headerTrailing()
            }
            content()
        }
    }

    private func cardGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
        )
        .cardShadow(DesignSystem.Shadows.cardRest)
    }

    private func promptRow(_ prompt: Prompt) -> some View {
        // Treat keyboard focus the same as hover so a Tab-only user gets
        // identical icon brightening + AutoRunBadge reveal.
        let isActive = hoveredPromptId == prompt.id || focusedPromptId == prompt.id
        let isAutoRun = prompt.isAutoRun
        let isExpanded = expandedPromptIds.contains(prompt.id)

        return HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            // Status toggle
            Toggle(
                "",
                isOn: Binding(
                    get: { prompt.isVisible },
                    set: { _ in withAnimation { viewModel.toggleVisibility(prompt) } }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(DesignSystem.Colors.accent)
            .padding(.top, 2)
            .focused($focusedPromptId, equals: prompt.id)
            .accessibilityLabel("Show \(prompt.name)")
            .accessibilityHint(isAutoRun ? "Auto-runs on new transcripts" : "")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(prompt.name)
                        .font(DesignSystem.Typography.bodyLarge.weight(.semibold))
                        .foregroundStyle(
                            prompt.isVisible ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textTertiary
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if prompt.isBuiltIn {
                        Text("Built-in")
                            .font(DesignSystem.Typography.caption.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(DesignSystem.Colors.surfaceElevated)
                            .clipShape(Capsule())
                    }

                    Text(prompt.category == .transform ? "Transform" : "Result")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(DesignSystem.Colors.surfaceElevated)
                        .clipShape(Capsule())

                    if prompt.inferenceSettings?.normalized != nil || prompt.modelOverride != nil {
                        Text("Custom settings")
                            .font(DesignSystem.Typography.caption.weight(.semibold))
                            .foregroundStyle(DesignSystem.Colors.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(DesignSystem.Colors.accent.opacity(0.08))
                            .clipShape(Capsule())
                    }

                    if let collection = viewModel.collections.first(where: { $0.id == prompt.collectionId }) {
                        Text(collection.name)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(DesignSystem.Colors.accent.opacity(0.08))
                            .clipShape(Capsule())
                    }

                    if prompt.category == .result, isAutoRun {
                        AutoRunBadge(isAutoRun: true) {
                            withAnimation { viewModel.toggleAutoRun(prompt) }
                        }
                        .focused($focusedPromptId, equals: prompt.id)
                        .accessibilityLabel("Auto-Run")
                        .accessibilityValue("on")
                        .accessibilityHint("Toggles whether \(prompt.name) auto-runs on new transcripts")
                    } else if prompt.category == .result, isActive {
                        AutoRunBadge(isAutoRun: false) {
                            withAnimation { viewModel.toggleAutoRun(prompt) }
                        }
                        .focused($focusedPromptId, equals: prompt.id)
                        .accessibilityLabel("Auto-Run")
                        .accessibilityValue("off")
                        .accessibilityHint("Toggles whether \(prompt.name) auto-runs on new transcripts")
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }

                    Spacer()
                }

                if isExpanded {
                    MarkdownContentView(prompt.content)
                        .opacity(prompt.isVisible ? 1 : 0.65)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(prompt.content)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(
                            prompt.isVisible ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textTertiary
                        )
                        .lineLimit(2)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                HStack(spacing: DesignSystem.Spacing.sm) {
                    if let summary = PromptsViewModel.compactInferenceSummary(prompt.inferenceSettings) {
                        Label(summary, systemImage: "slider.horizontal.3")
                            .lineLimit(2)
                    }
                    if prompt.includeMeetingNotes {
                        Label("Meeting notes", systemImage: "note.text")
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(DesignSystem.Colors.surfaceElevated)
                            .clipShape(Capsule())
                            .accessibilityLabel("Uses meeting notes as context")
                    }
                    let targetLabels = viewModel.targetLabels(for: prompt)
                    if !targetLabels.isEmpty {
                        ForEach(Array(targetLabels.prefix(3).enumerated()), id: \.element.id) { index, label in
                            Label(label.name, systemImage: "tag.fill")
                                .foregroundStyle(
                                    MeetingClassificationTint.color(
                                        for: label.colorToken,
                                        fallback: index + 1
                                    )
                                )
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    MeetingClassificationTint.color(
                                        for: label.colorToken,
                                        fallback: index + 1
                                    ).opacity(0.1)
                                )
                                .clipShape(Capsule())
                        }
                        if targetLabels.count > 3 {
                            Text("+\(targetLabels.count - 3)")
                        }
                    }
                }
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

                if isExpanded {
                    meetingNotesContextToggle(
                        isOn: Binding(
                            get: { prompt.includeMeetingNotes },
                            set: { viewModel.setIncludeMeetingNotes(prompt, enabled: $0) }
                        )
                    )
                    .padding(.top, DesignSystem.Spacing.xs)
                }

                if let modelOverride = prompt.modelOverride {
                    Label(modelOverride, systemImage: "cpu")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    viewModel.beginEditing(prompt)
                    editName = prompt.name
                    editContent = prompt.content
                    editContentMode = .edit
                    diffFromVersionID = nil
                    diffToVersionID = nil
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(isActive ? DesignSystem.Colors.rowHoverBackground : .clear)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .focused($focusedPromptId, equals: prompt.id)
                .help("Edit prompt")
                .accessibilityLabel("Edit \(prompt.name)")

                Button {
                    viewModel.pendingDeletePrompt = prompt
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(isActive ? DesignSystem.Colors.errorRed : DesignSystem.Colors.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(isActive ? DesignSystem.Colors.errorRed.opacity(0.1) : .clear)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .focused($focusedPromptId, equals: prompt.id)
                .help("Delete prompt")
                .accessibilityLabel("Delete \(prompt.name)")
            }
            .opacity(isActive ? 1.0 : 0.4)
            .animation(.easeInOut(duration: 0.2), value: isActive)

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedPromptIds.remove(prompt.id)
                    } else {
                        expandedPromptIds.insert(prompt.id)
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .foregroundStyle(isActive ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(isActive ? DesignSystem.Colors.rowHoverBackground : .clear)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .focused($focusedPromptId, equals: prompt.id)
            .padding(.top, 2)
            .help(isExpanded ? "Collapse" : "Expand")
            .accessibilityLabel(isExpanded ? "Collapse \(prompt.name)" : "Expand \(prompt.name)")
        }
        .padding(DesignSystem.Spacing.lg)
        .background(isActive ? DesignSystem.Colors.surfaceElevated.opacity(0.5) : Color.clear)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hoveredPromptId = hovering ? prompt.id : nil
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            MeditativeMerkabaView(size: 40, revolutionDuration: 12.0, tintColor: DesignSystem.Colors.accent)
            Text("No custom prompts yet")
                .font(DesignSystem.Typography.bodyLarge.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .padding(.top, DesignSystem.Spacing.xs)
            Text("Create specific instructions for how you want your transcripts processed.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.xxl)
        }
        .padding(.vertical, DesignSystem.Spacing.xxl)
        .frame(maxWidth: .infinity)
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [6]))
                .foregroundStyle(DesignSystem.Colors.border)
        )
    }

    private var addPromptCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Type")
                        .font(DesignSystem.Typography.caption.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Picker("Type", selection: $viewModel.newPromptCategory) {
                        Text("Result prompt").tag(Prompt.Category.result)
                        Text("Transform").tag(Prompt.Category.transform)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Name")
                        .font(DesignSystem.Typography.caption.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    TextField("e.g. Daily Standup", text: $viewModel.newName)
                        .textFieldStyle(.plain)
                        .font(DesignSystem.Typography.bodyLarge)
                        .padding(10)
                        .background(DesignSystem.Colors.background)
                        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
                        )
                }

                markdownEditor(
                    text: $viewModel.newContent,
                    mode: $newContentMode,
                    placeholder: "Extract action items and format as a bulleted list...",
                    minHeight: 160
                )

                collectionPicker(selection: $viewModel.newCollectionID)

                if viewModel.newPromptCategory == .result {
                    promptLabelTargeting(selection: $viewModel.newTargetLabelIDs)
                }

                GenerationSettingsEditor(
                    draft: $viewModel.newInferenceSettings,
                    modelOverride: $viewModel.newModelOverride,
                    errors: viewModel.newInferenceValidationErrors,
                    onReset: {
                        viewModel.resetNewInferenceSettings()
                        viewModel.newModelOverride = ""
                    }
                )

                meetingNotesContextToggle(isOn: $viewModel.newIncludeMeetingNotes)
            }
            .padding(DesignSystem.Spacing.lg)

            Divider()

            HStack {
                Spacer()
                Button {
                    withAnimation { viewModel.addPrompt() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text("Save Prompt")
                            .font(DesignSystem.Typography.body.weight(.semibold))
                    }
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                }
                .parakeetAction(.primaryProminent)
                .controlSize(.large)
                .disabled(
                    viewModel.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || viewModel.newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(DesignSystem.Spacing.md)
            .background(DesignSystem.Colors.surfaceElevated.opacity(0.3))
        }
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
        )
        .cardShadow(DesignSystem.Shadows.cardRest)
    }

    private func editSheet(prompt: Prompt) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Edit Prompt")
                    .font(DesignSystem.Typography.pageTitle)
                Spacer()
            }
            .padding(DesignSystem.Spacing.xl)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Name")
                            .font(DesignSystem.Typography.caption.weight(.medium))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        TextField("Name", text: $editName)
                            .textFieldStyle(.plain)
                            .font(DesignSystem.Typography.bodyLarge)
                            .padding(10)
                            .background(DesignSystem.Colors.background)
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                    .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
                            )
                    }

                    markdownEditor(
                        text: $editContent,
                        mode: $editContentMode,
                        placeholder: "Instructions...",
                        minHeight: 220
                    )

                    collectionPicker(selection: $viewModel.editingCollectionID)

                    if prompt.category == .result {
                        promptLabelTargeting(selection: $viewModel.editingTargetLabelIDs)
                    }

                    GenerationSettingsEditor(
                        draft: $viewModel.editingInferenceSettings,
                        modelOverride: $viewModel.editingModelOverride,
                        errors: viewModel.editingInferenceValidationErrors,
                        onReset: {
                            viewModel.resetEditingInferenceSettings()
                            viewModel.editingModelOverride = ""
                        }
                    )

                    meetingNotesContextToggle(isOn: $viewModel.editingIncludeMeetingNotes)
                    versionHistory(prompt: prompt)
                }
                .padding(DesignSystem.Spacing.xl)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Cancel") {
                    attemptCancelEdit(prompt: prompt)
                }
                .parakeetAction(.secondary)
                .controlSize(.large)
                // Esc cancels (HIG default). hasChanges check inside
                // attemptCancelEdit decides whether to confirm or dismiss.
                .keyboardShortcut(.cancelAction)

                Button("Save Changes") {
                    viewModel.updatePrompt(prompt, name: editName, content: editContent)
                }
                .parakeetAction(.primaryProminent)
                .controlSize(.large)
                // Cmd+Return (not bare Return) because the Instructions
                // TextEditor below treats Return as a literal newline; bare
                // Return would steal that.
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(
                    editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || editContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(DesignSystem.Spacing.xl)
            .background(DesignSystem.Colors.surfaceElevated.opacity(0.3))
        }
        .frame(width: 680, height: 620)
        .background(.thickMaterial)
    }

    private func meetingNotesContextToggle(isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Include meeting notes as context", isOn: isOn)
                .toggleStyle(.checkbox)
                .font(DesignSystem.Typography.body.weight(.medium))
                .accessibilityHint(
                    "Adds user-authored notes when this prompt runs on a meeting."
                )
            Text(
                "When this prompt runs on a meeting with notes, use those notes as additional context. "
                    + "The transcript remains the source of truth."
            )
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 20)
        }
        .foregroundStyle(DesignSystem.Colors.textPrimary)
    }

    private func promptLabelTargeting(selection: Binding<Set<UUID>>) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Available for")
                .font(DesignSystem.Typography.caption.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Text("Choose labels to show this prompt only on matching transcriptions.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textTertiary)

            FlowLayout(spacing: 7) {
                Button {
                    selection.wrappedValue = []
                } label: {
                    HStack(spacing: 5) {
                        if selection.wrappedValue.isEmpty {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        Text("All transcriptions")
                    }
                    .font(DesignSystem.Typography.caption.weight(.medium))
                    .foregroundStyle(
                        selection.wrappedValue.isEmpty
                            ? DesignSystem.Colors.accent
                            : DesignSystem.Colors.textSecondary
                    )
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(
                            selection.wrappedValue.isEmpty
                                ? DesignSystem.Colors.accent.opacity(0.14)
                                : DesignSystem.Colors.surfaceElevated
                        )
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            selection.wrappedValue.isEmpty
                                ? DesignSystem.Colors.accent.opacity(0.55)
                                : DesignSystem.Colors.border,
                            lineWidth: 0.7
                        )
                    )
                }
                .buttonStyle(.plain)

                ForEach(Array(promptTargetingLabels(selection: selection).enumerated()), id: \.element.id) {
                    index, label in
                    let selected = selection.wrappedValue.contains(label.id)
                    let tint = MeetingClassificationTint.color(for: label.colorToken, fallback: index + 1)
                    Button {
                        if selected {
                            selection.wrappedValue.remove(label.id)
                        } else {
                            selection.wrappedValue.insert(label.id)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: selected ? "checkmark" : "tag.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(label.name)
                            if label.isArchived {
                                Text("Archived")
                                    .font(DesignSystem.Typography.micro)
                            }
                        }
                        .font(DesignSystem.Typography.caption.weight(.medium))
                        .foregroundStyle(selected ? tint : DesignSystem.Colors.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(tint.opacity(selected ? 0.16 : 0.07)))
                        .overlay(
                            Capsule().strokeBorder(
                                tint.opacity(selected ? 0.55 : 0.24),
                                lineWidth: selected ? 1 : 0.6
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(label.isArchived && !selected)
                }
            }
        }
    }

    private func promptTargetingLabels(selection: Binding<Set<UUID>>) -> [MeetingLabel] {
        viewModel.availableLabels.filter { !$0.isArchived || selection.wrappedValue.contains($0.id) }
    }

    private func markdownEditor(
        text: Binding<String>,
        mode: Binding<ContentMode>,
        placeholder: String,
        minHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Instructions")
                        .font(DesignSystem.Typography.caption.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text("Markdown supported")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
                Spacer()
                Picker("Content mode", selection: mode) {
                    ForEach(ContentMode.allCases, id: \.self) { contentMode in
                        Text(contentMode.rawValue).tag(contentMode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

            Group {
                switch mode.wrappedValue {
                case .edit:
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: text)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)

                        if text.wrappedValue.isEmpty {
                            Text(placeholder)
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textTertiary)
                                .padding(.top, 8)
                                .padding(.leading, 10)
                                .allowsHitTesting(false)
                        }
                    }
                case .preview:
                    ScrollView {
                        if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Nothing to preview yet.")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            MarkdownContentView(text.wrappedValue)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
            }
            .frame(minHeight: minHeight, maxHeight: minHeight)
            .background(DesignSystem.Colors.background)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func collectionPicker(selection: Binding<UUID?>) -> some View {
        if !viewModel.collections.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Collection")
                    .font(DesignSystem.Typography.caption.weight(.medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Picker("Collection", selection: selection) {
                    Text("Unfiled").tag(Optional<UUID>.none)
                    ForEach(viewModel.collections) { collection in
                        Text(collection.name).tag(Optional(collection.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func versionHistory(prompt: Prompt) -> some View {
        if !viewModel.promptVersions.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    ForEach(viewModel.promptVersions) { version in
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Version \(version.versionNumber)")
                                        .font(DesignSystem.Typography.body.weight(.semibold))
                                    if version.id == prompt.activeVersionId {
                                        Text("Current")
                                            .font(DesignSystem.Typography.caption.weight(.semibold))
                                            .foregroundStyle(DesignSystem.Colors.accent)
                                    }
                                }
                                Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                            }
                            Spacer()
                            Text(version.origin.rawValue)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            Button("Restore") {
                                pendingRestoreVersion = version
                            }
                            .parakeetAction(.secondary)
                            .disabled(version.id == prompt.activeVersionId)
                        }
                        if version.id != viewModel.promptVersions.last?.id { Divider() }
                    }

                    Divider()

                    HStack {
                        Picker("From", selection: $diffFromVersionID) {
                            ForEach(viewModel.promptVersions) { version in
                                Text("Version \(version.versionNumber)").tag(Optional(version.id))
                            }
                        }
                        Picker("To", selection: $diffToVersionID) {
                            ForEach(viewModel.promptVersions) { version in
                                Text("Version \(version.versionNumber)").tag(Optional(version.id))
                            }
                        }
                    }

                    if let from = selectedVersion(diffFromVersionID),
                        let to = selectedVersion(diffToVersionID)
                    {
                        let selection = PromptVersionDiffViewModel.Selection(from: from, to: to)
                        Group {
                            if versionDiff.selection == selection, let diff = versionDiff.diff {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(diff.markdown.lines.enumerated()), id: \.offset) { _, line in
                                        diffLine(line)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                                        .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
                                )

                                versionSettingsComparison(diff: diff)
                            } else {
                                ProgressView("Comparing versions…")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .task(id: selection) {
                            await versionDiff.load(from: from, to: to)
                        }
                    }
                }
                .padding(.top, DesignSystem.Spacing.md)
            } label: {
                Label(
                    "Version history (\(viewModel.promptVersions.count))",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(DesignSystem.Typography.body.weight(.semibold))
            }
            .onAppear(perform: selectDefaultDiffVersions)
            .onChange(of: viewModel.promptVersions.map(\.id)) { _, _ in
                selectDefaultDiffVersions()
            }
        }
    }

    private func selectedVersion(_ id: UUID?) -> PromptVersion? {
        guard let id else { return nil }
        return viewModel.promptVersions.first { $0.id == id }
    }

    private func restoreVersion(_ version: PromptVersion) {
        if let restored = viewModel.restoreVersion(version) {
            editContent = restored.content
            viewModel.editingModelOverride = restored.modelOverride ?? ""
            diffToVersionID = restored.activeVersionId
        }
    }

    private func selectDefaultDiffVersions() {
        guard let newest = viewModel.promptVersions.first else { return }
        if !viewModel.promptVersions.contains(where: { $0.id == diffToVersionID }) {
            diffToVersionID = newest.id
        }
        if !viewModel.promptVersions.contains(where: { $0.id == diffFromVersionID }) {
            diffFromVersionID = viewModel.promptVersions.dropFirst().first?.id ?? newest.id
        }
    }

    @ViewBuilder
    private func versionSettingsComparison(diff: PromptVersionDiff) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LLM settings")
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            if diff.inferenceSettings.isEmpty, diff.modelOverride == nil {
                Text("No LLM setting changes")
            } else {
                ForEach(Array(diff.inferenceSettings.enumerated()), id: \.offset) { _, change in
                    Text(
                        "\(PromptsViewModel.displayName(for: change.field)): "
                            + "\(settingValue(change.oldValue)) → \(settingValue(change.newValue))"
                    )
                }
                if let model = diff.modelOverride {
                    Text("Model: \(model.oldValue ?? "Provider default") → \(model.newValue ?? "Provider default")")
                }
            }
        }
        .font(DesignSystem.Typography.caption)
        .foregroundStyle(DesignSystem.Colors.textSecondary)
    }

    @ViewBuilder
    private func diffLine(_ line: PromptMarkdownLineDiff) -> some View {
        switch line.kind {
        case .modified:
            diffTextRow(text: line.oldText ?? "", segments: line.oldSegments, kind: .removed)
            diffTextRow(text: line.newText ?? "", segments: line.newSegments, kind: .added)
        case .unchanged:
            diffTextRow(text: line.newText ?? "", segments: line.newSegments, kind: .unchanged)
        case .removed:
            diffTextRow(text: line.oldText ?? "", segments: line.oldSegments, kind: .removed)
        case .added:
            diffTextRow(text: line.newText ?? "", segments: line.newSegments, kind: .added)
        }
    }

    private func diffTextRow(
        text: String,
        segments: [PromptDiffTextSegment],
        kind: PromptDiffLineKind
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(diffMarker(for: kind))
                .foregroundStyle(diffColor(for: kind))
                .frame(width: 12)
            diffSegmentText(segments, fallback: text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(diffBackground(for: kind))
    }

    private func diffSegmentText(_ segments: [PromptDiffTextSegment], fallback: String) -> Text {
        guard !segments.isEmpty else { return Text(fallback.isEmpty ? " " : fallback) }
        return segments.reduce(Text("")) { partial, segment in
            let text = Text(segment.text.isEmpty ? " " : segment.text)
            switch segment.kind {
            case .unchanged:
                return partial + text
            case .removed:
                return partial + text.foregroundColor(DesignSystem.Colors.errorRed).bold()
            case .added:
                return partial + text.foregroundColor(DesignSystem.Colors.successGreen).bold()
            }
        }
    }

    private func diffMarker(for kind: PromptDiffLineKind) -> String {
        switch kind {
        case .unchanged: return " "
        case .removed: return "−"
        case .added: return "+"
        case .modified: return "±"
        }
    }

    private func settingValue(_ value: PromptInferenceSettingValue?) -> String {
        guard let value else { return "Default" }
        switch value {
        case .decimal(let value): return String(value)
        case .integer(let value): return String(value)
        case .thinkingMode(let value): return value.rawValue
        case .reasoningEffort(let value): return PromptsViewModel.displayName(for: value)
        }
    }

    private func diffColor(for kind: PromptDiffLineKind) -> Color {
        switch kind {
        case .unchanged: return DesignSystem.Colors.textTertiary
        case .removed: return DesignSystem.Colors.errorRed
        case .added: return DesignSystem.Colors.successGreen
        case .modified: return DesignSystem.Colors.accent
        }
    }

    private func diffBackground(for kind: PromptDiffLineKind) -> Color {
        switch kind {
        case .unchanged: return .clear
        case .removed: return DesignSystem.Colors.errorRed.opacity(0.08)
        case .added: return DesignSystem.Colors.successGreen.opacity(0.08)
        case .modified: return DesignSystem.Colors.accent.opacity(0.08)
        }
    }
}

private struct GenerationSettingsEditor: View {
    @Binding var draft: PromptsViewModel.InferenceSettingsDraft
    @Binding var modelOverride: String
    let errors: PromptsViewModel.InferenceValidationErrors
    let onReset: () -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("Blank fields inherit MacParakeet's current defaults for the selected provider and model.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Model override")
                        .font(DesignSystem.Typography.caption.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    TextField("Current provider model", text: $modelOverride)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Model override")
                    Text("Use a model identifier supported by the active provider, or leave blank to inherit it.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: DesignSystem.Spacing.md),
                        GridItem(.flexible(), spacing: DesignSystem.Spacing.md),
                    ],
                    alignment: .leading,
                    spacing: DesignSystem.Spacing.md
                ) {
                    numberField(
                        title: "Temperature",
                        placeholder: "Default (0–2)",
                        text: $draft.temperature,
                        field: .temperature
                    )
                    numberField(
                        title: "Top P",
                        placeholder: "Default (0–1)",
                        text: $draft.topP,
                        field: .topP
                    )
                    numberField(
                        title: "Top K",
                        placeholder: "Default (0–1000)",
                        text: $draft.topK,
                        field: .topK
                    )
                    numberField(
                        title: "Maximum output tokens",
                        placeholder: "Default (1–131072)",
                        text: $draft.maxTokens,
                        field: .maxTokens
                    )
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Thinking")
                            .font(DesignSystem.Typography.caption.weight(.medium))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                        Picker("Thinking", selection: $draft.thinkingMode) {
                            Text("Default").tag(PromptInferenceSettings.ThinkingMode.providerDefault)
                            Text("Enabled").tag(PromptInferenceSettings.ThinkingMode.enabled)
                            Text("Disabled").tag(PromptInferenceSettings.ThinkingMode.disabled)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: draft.thinkingMode) { _, mode in
                            if mode != .enabled {
                                draft.reasoningEffort = nil
                            }
                        }
                    }

                    if draft.thinkingMode == .enabled {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Reasoning effort")
                                .font(DesignSystem.Typography.caption.weight(.medium))
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                            Picker("Reasoning effort", selection: $draft.reasoningEffort) {
                                Text("Default").tag(PromptInferenceSettings.ReasoningEffort?.none)
                                ForEach(PromptInferenceSettings.ReasoningEffort.allCases, id: \.self) { effort in
                                    Text(PromptsViewModel.displayName(for: effort)).tag(Optional(effort))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Available levels depend on the endpoint and model template.")
                                .font(DesignSystem.Typography.micro)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack {
                    if let summary = draftSummary {
                        Text(summary)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Reset to defaults", action: onReset)
                        .buttonStyle(.plain)
                        .font(DesignSystem.Typography.caption.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.accent)
                        .disabled(
                            !PromptsViewModel.hasCustomGenerationSettings(
                                draft: draft,
                                modelOverride: modelOverride
                            )
                        )
                }
            }
            .padding(.top, DesignSystem.Spacing.md)
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Label("Generation settings", systemImage: "slider.horizontal.3")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                Spacer()
                if PromptsViewModel.hasCustomGenerationSettings(
                    draft: draft,
                    modelOverride: modelOverride
                ) {
                    Text("Custom")
                        .font(DesignSystem.Typography.micro.weight(.bold))
                        .foregroundStyle(DesignSystem.Colors.accentDark)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(DesignSystem.Colors.accentLight)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
        .onChange(of: errors) { _, newErrors in
            if !newErrors.isEmpty {
                isExpanded = true
            }
        }
    }

    private func numberField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        field: PromptInferenceSettings.Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(DesignSystem.Typography.caption.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
            if let error = errors[field] {
                Text(error)
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var draftSummary: String? {
        let settings = PromptInferenceSettings(
            temperature: Double(draft.temperature.trimmingCharacters(in: .whitespacesAndNewlines)),
            topP: Double(draft.topP.trimmingCharacters(in: .whitespacesAndNewlines)),
            topK: Int(draft.topK.trimmingCharacters(in: .whitespacesAndNewlines)),
            maxTokens: Int(draft.maxTokens.trimmingCharacters(in: .whitespacesAndNewlines)),
            thinkingMode: draft.thinkingMode,
            reasoningEffort: draft.reasoningEffort
        )
        return PromptsViewModel.compactInferenceSummary(settings)
    }
}

struct AutoRunBadge: View {
    let isAutoRun: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isAutoRun ? "bolt.fill" : "bolt")
                    .font(.system(size: 10, weight: .bold))
                Text("Auto-Run")
                    .font(DesignSystem.Typography.micro.weight(.bold))
            }
            .foregroundStyle(isAutoRun ? DesignSystem.Colors.accentDark : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isAutoRun ? DesignSystem.Colors.accentLight : DesignSystem.Colors.surfaceElevated)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(isAutoRun ? Color.clear : DesignSystem.Colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // Use a tiny delay so it doesn't flash if you just mouse over quickly
            if hovering {
                withAnimation(.easeOut(duration: 0.15).delay(0.2)) {
                    isHovered = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.1)) {
                    isHovered = false
                }
            }
        }
        .overlay(alignment: .leading) {
            if isHovered {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(DesignSystem.Colors.accent)
                    Text("Runs automatically on new transcripts")
                        .fixedSize()
                }
                .font(DesignSystem.Typography.caption.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(DesignSystem.Colors.surfaceElevated)
                        .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                )
                .overlay(
                    Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
                )
                .offset(x: 80)  // Place tooltip nicely to the right of the button
                .zIndex(100)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }
}
