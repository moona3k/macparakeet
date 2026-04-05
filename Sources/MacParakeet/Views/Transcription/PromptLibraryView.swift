import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct PromptLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: PromptsViewModel
    @State private var editName: String = ""
    @State private var editContent: String = ""
    @State private var hoveredPromptId: UUID?
    @State private var expandedPromptIds: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt Library")
                        .font(DesignSystem.Typography.heroTitle)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Manage the templates used for generating prompt results and custom outputs.")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(DesignSystem.Typography.body.weight(.semibold))
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
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

                    // Built-In Prompts Section
                    sectionContainer(
                        title: "Built-In Prompts",
                        subtitle: "Toggle visibility or enable Auto-Run to generate results automatically after transcription."
                    ) {
                        cardGroup {
                            let builtIns = viewModel.prompts.filter(\.isBuiltIn)
                            ForEach(Array(builtIns.enumerated()), id: \.element.id) { index, prompt in
                                promptRow(prompt, allowEdit: false)
                                if index < builtIns.count - 1 { Divider().padding(.leading, 16) }
                            }
                        }
                    }

                    // Custom Prompts Section
                    sectionContainer(
                        title: "My Prompts",
                        subtitle: "Custom prompts you've created. Edit, reorder, or remove anytime."
                    ) {
                        let customPrompts = viewModel.prompts.filter { !$0.isBuiltIn }
                        if customPrompts.isEmpty {
                            emptyStateView
                        } else {
                            cardGroup {
                                ForEach(Array(customPrompts.enumerated()), id: \.element.id) { index, prompt in
                                    promptRow(prompt, allowEdit: true)
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
                DesignSystem.Colors.background
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
            Text("This custom prompt will be removed permanently.")
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.editingPrompt != nil },
                set: { if !$0 { viewModel.editingPrompt = nil } }
            ),
            onDismiss: {
                editName = ""
                editContent = ""
            }
        ) {
            if let prompt = viewModel.editingPrompt {
                editSheet(prompt: prompt)
            }
        }
    }

    // MARK: - Components

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

    private func promptRow(_ prompt: Prompt, allowEdit: Bool) -> some View {
        let isHovered = hoveredPromptId == prompt.id
        let isAutoRun = prompt.isAutoRun
        let isExpanded = expandedPromptIds.contains(prompt.id)

        return HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            // Status toggle
            Toggle("", isOn: Binding(
                get: { prompt.isVisible },
                set: { _ in withAnimation { viewModel.toggleVisibility(prompt) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(DesignSystem.Colors.accent)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(prompt.name)
                        .font(DesignSystem.Typography.bodyLarge.weight(.semibold))
                        .foregroundStyle(prompt.isVisible ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textTertiary)

                    if isAutoRun {
                        AutoRunBadge(isAutoRun: true) {
                            withAnimation { viewModel.toggleAutoRun(prompt) }
                        }
                    } else if isHovered {
                        AutoRunBadge(isAutoRun: false) {
                            withAnimation { viewModel.toggleAutoRun(prompt) }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }

                    Spacer()
                }

                // Workaround for macOS SwiftUI bug: NSTextView (.textSelection(.enabled)) 
                // does not animate height bounds correctly when lineLimit changes, and expands to full height.
                // We use an invisible SwiftUI Text to drive the layout container's smooth animation,
                // and place the selectable text in an overlay that is strictly clipped to those bounds.
                Text(prompt.content)
                    .font(DesignSystem.Typography.body)
                    .lineLimit(isExpanded ? nil : 2)
                    .lineSpacing(2)
                    .opacity(0)
                    .accessibilityHidden(true)
                    .overlay(alignment: .topLeading) {
                        Text(prompt.content)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(prompt.isVisible ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textTertiary)
                            .lineLimit(isExpanded ? nil : 2)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .clipped()
            }

            if allowEdit {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button {
                        viewModel.editingPrompt = prompt
                        editName = prompt.name
                        editContent = prompt.content
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(isHovered ? DesignSystem.Colors.rowHoverBackground : .clear)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit prompt")

                    Button {
                        viewModel.pendingDeletePrompt = prompt
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(isHovered ? DesignSystem.Colors.errorRed : DesignSystem.Colors.textTertiary)
                            .frame(width: 28, height: 28)
                            .background(isHovered ? DesignSystem.Colors.errorRed.opacity(0.1) : .clear)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete prompt")
                }
                .opacity(isHovered ? 1.0 : 0.4)
                .animation(.easeInOut(duration: 0.2), value: isHovered)
            }

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
                    .foregroundStyle(isHovered ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(isHovered ? DesignSystem.Colors.rowHoverBackground : .clear)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .help(isExpanded ? "Collapse" : "Expand")
        }
        .padding(DesignSystem.Spacing.lg)
        .background(isHovered ? DesignSystem.Colors.surfaceElevated.opacity(0.5) : Color.clear)
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

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Instructions")
                        .font(DesignSystem.Typography.caption.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $viewModel.newContent)
                            .font(DesignSystem.Typography.body)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                        
                        if viewModel.newContent.isEmpty {
                            Text("Extract action items and format as a bulleted list...")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textTertiary)
                                .padding(.top, 8)
                                .padding(.leading, 10)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 120)
                    .background(DesignSystem.Colors.background)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
                    )
                }
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
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(DesignSystem.Colors.accent)
                .disabled(viewModel.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.newContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Instructions")
                        .font(DesignSystem.Typography.caption.weight(.medium))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $editContent)
                            .font(DesignSystem.Typography.body)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                        
                        if editContent.isEmpty {
                            Text("Instructions...")
                                .font(DesignSystem.Typography.body)
                                .foregroundStyle(DesignSystem.Colors.textTertiary)
                                .padding(.top, 8)
                                .padding(.leading, 10)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 160)
                    .background(DesignSystem.Colors.background)
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
                    )
                }
            }
            .padding(DesignSystem.Spacing.xl)
            
            Spacer()
            Divider()
            
            // Footer
            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.editingPrompt = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Save Changes") {
                    viewModel.updatePrompt(prompt, name: editName, content: editContent)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(DesignSystem.Colors.accent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(DesignSystem.Spacing.xl)
            .background(DesignSystem.Colors.surfaceElevated.opacity(0.3))
        }
        .frame(width: 540, height: 500)
        .background(DesignSystem.Colors.surface)
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
                .offset(x: 80) // Place tooltip nicely to the right of the button
                .zIndex(100)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }
}
