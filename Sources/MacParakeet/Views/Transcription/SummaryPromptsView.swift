import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct SummaryPromptsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: PromptsViewModel
    @State private var editName: String = ""
    @State private var editContent: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack {
                Text("Manage Summary Prompts")
                    .font(DesignSystem.Typography.pageTitle)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    builtInSection
                    customSection
                    addPromptSection
                }
                .padding(.vertical, 4)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 720, minHeight: 620)
        .alert(
            "Delete Prompt?",
            isPresented: Binding(
                get: { viewModel.pendingDeletePrompt != nil },
                set: { if !$0 { viewModel.pendingDeletePrompt = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                viewModel.confirmDelete()
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

    private var builtInSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack {
                Text("Built-In")
                    .font(DesignSystem.Typography.sectionTitle)
                Spacer()
                Button("Restore Defaults") {
                    viewModel.restoreDefaults()
                }
                .buttonStyle(.bordered)
            }

            VStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(viewModel.prompts.filter(\.isBuiltIn)) { prompt in
                    promptRow(prompt, allowEdit: false)
                }
            }
        }
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Custom")
                .font(DesignSystem.Typography.sectionTitle)

            if viewModel.prompts.contains(where: { !$0.isBuiltIn }) {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(viewModel.prompts.filter { !$0.isBuiltIn }) { prompt in
                        promptRow(prompt, allowEdit: true)
                    }
                }
            } else {
                Text("No custom prompts yet.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
    }

    private var addPromptSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Add Prompt")
                .font(DesignSystem.Typography.sectionTitle)

            TextField("Prompt name", text: $viewModel.newName)
                .textFieldStyle(.roundedBorder)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.newContent)
                    .font(DesignSystem.Typography.body)
                    .scrollContentBackground(.hidden)
                if viewModel.newContent.isEmpty {
                    Text("Write your prompt instructions...")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .padding(.top, 7)
                        .padding(.leading, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 140)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
            )

            HStack {
                Spacer()
                Button {
                    viewModel.addPrompt()
                } label: {
                    Label("Add Prompt", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .tint(DesignSystem.Colors.accent)
            }
        }
    }

    private func promptRow(_ prompt: Prompt, allowEdit: Bool) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Toggle(
                isOn: Binding(
                    get: { prompt.isVisible },
                    set: { _ in viewModel.toggleVisibility(prompt) }
                )
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.name)
                        .font(DesignSystem.Typography.body.weight(.semibold))
                    Text(prompt.content)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(3)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(prompt.isBuiltIn && prompt.name == Prompt.defaultSummaryPrompt.name)

            Spacer()

            if allowEdit {
                Button("Edit") {
                    viewModel.editingPrompt = prompt
                    editName = prompt.name
                    editContent = prompt.content
                }
                .buttonStyle(.bordered)

                Button("Delete", role: .destructive) {
                    viewModel.pendingDeletePrompt = prompt
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surface.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }

    private func editSheet(prompt: Prompt) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Edit Prompt")
                .font(DesignSystem.Typography.pageTitle)

            TextField("Prompt name", text: $editName)
                .textFieldStyle(.roundedBorder)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $editContent)
                    .font(DesignSystem.Typography.body)
                    .scrollContentBackground(.hidden)
                if editContent.isEmpty {
                    Text("Write your prompt instructions...")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .padding(.top, 7)
                        .padding(.leading, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 220)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .fill(DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
            )

            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.editingPrompt = nil
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    viewModel.updatePrompt(prompt, name: editName, content: editContent)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(minWidth: 620, minHeight: 420)
    }
}
