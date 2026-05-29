import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Manage Ask tab quick prompts. Reachable from the sparkle popover footer in
/// `LiveAskPaneView`. Reuses Prompt Library design tokens for visual
/// consistency, but tighter — pills are micro-shortcuts, not heavyweight
/// result templates, so we drop auto-run / expand chrome.
///
/// One unified library, two visual zones:
/// - **PINNED · n** — prompts that surface as compact pills in the
///   after-response strip (horizontally scrollable with edge-fade overflow,
///   unbounded).
/// - **ALL PROMPTS** — everything else; surfaces in the empty Ask state and
///   the sparkle popover.
struct AskPromptsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: QuickPromptsViewModel

    @State private var hoveredID: UUID?
    @State private var pendingDelete: QuickPrompt?
    @State private var showingResetConfirm = false
    /// Tracks which row currently owns keyboard focus so we can mirror the
    /// hover-revealed icon brightening for keyboard-only users. Set by
    /// `.focused($focusedRowID, equals: prompt.id)` on each row's controls.
    @FocusState private var focusedRowID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: DesignSystem.Spacing.xxl) {
                    if let errorMessage = viewModel.errorMessage {
                        errorBanner(errorMessage)
                    }

                    zone(
                        title: "Pinned",
                        countSuffix: "\(viewModel.pinnedCount)",
                        subtitle: "Your most-used questions, shown as quick buttons during a live meeting. The order here is the order you'll see them in.",
                        rows: viewModel.allPinned,
                        pinned: true
                    )

                    zone(
                        title: "All prompts",
                        countSuffix: nil,
                        subtitle: "Your full question library. These appear when you open Ask and in the ✨ menu while you're chatting. Add a group label to keep related questions together (CATCH UP, CAPTURE, CHALLENGE).",
                        rows: viewModel.allUnpinned,
                        pinned: false
                    )

                    Button {
                        viewModel.startCreating()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Add a prompt")
                                .font(DesignSystem.Typography.body.weight(.medium))
                        }
                        .foregroundStyle(DesignSystem.Colors.accent)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(DesignSystem.Spacing.xl)
            }
        }
        .background(.thickMaterial)
        .frame(minWidth: 720, minHeight: 640)
        .alert(
            "Delete prompt?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let prompt = pendingDelete {
                    withAnimation { viewModel.delete(prompt) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This custom prompt will be removed from the Ask tab.")
        }
        .alert(
            "Reset built-ins?",
            isPresented: $showingResetConfirm
        ) {
            Button("Reset", role: .destructive) {
                withAnimation { viewModel.restoreAllBuiltInDefaults() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Built-in prompts return to their default labels, prompt text, group, and pin state. Your custom prompts stay untouched.")
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.editingPrompt != nil },
                set: { if !$0 { viewModel.editingPrompt = nil } }
            )
        ) {
            if let editing = viewModel.editingPrompt {
                EditPromptSheet(
                    prompt: editing,
                    onSave: { updated in
                        viewModel.saveEdit(updated)
                    },
                    onCancel: {
                        viewModel.editingPrompt = nil
                    },
                    onRestore: editing.isBuiltIn ? {
                        withAnimation { viewModel.restoreSingleDefault(editing) }
                        viewModel.editingPrompt = nil
                    } : nil
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.creating != nil },
                set: { if !$0 { viewModel.cancelCreating() } }
            )
        ) {
            if viewModel.creating != nil {
                CreatePromptSheet(viewModel: viewModel)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask Prompts")
                    .font(DesignSystem.Typography.heroTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Reusable questions for live meetings. Pin the ones you reach for most to keep them front and center — the rest stay in your library, ready when you need them.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()

            Menu {
                Button("Reset built-ins to defaults") {
                    showingResetConfirm = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 32)
            .polishedTooltip("More options")
            .accessibilityLabel("More options")

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(DesignSystem.Typography.body.weight(.semibold))
                    .padding(.horizontal, DesignSystem.Spacing.sm)
            }
            .parakeetAction(.primaryProminent)
            .controlSize(.large)
            // Esc dismisses (Apple HIG default for sheets). `.cancelAction`
            // is Esc + Cmd-. on macOS — both reach the close intent.
            .keyboardShortcut(.cancelAction)
        }
        .padding(DesignSystem.Spacing.xl)
        .background(DesignSystem.Colors.surface)
    }

    // MARK: - Zone

    private func zone(
        title: String,
        countSuffix: String?,
        subtitle: String,
        rows: [QuickPrompt],
        pinned: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                if let countSuffix {
                    Text("· \(countSuffix)")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
                Spacer()
            }

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .padding(.bottom, 2)
            }

            if rows.isEmpty {
                emptyZone(pinned: pinned)
            } else {
                cardGroup {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, prompt in
                        promptRow(prompt, rows: rows, index: index, pinned: pinned)
                        if index < rows.count - 1 { Divider().padding(.leading, 16) }
                    }
                }
            }
        }
    }

    private func emptyZone(pinned: Bool) -> some View {
        cardGroup {
            HStack(spacing: 10) {
                Image(systemName: pinned ? "pin.slash" : "tray")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
                Text(pinned ? "No pinned questions yet. Pin one below to keep it handy during meetings." : "No questions yet. Add one below.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Row

    private func promptRow(_ prompt: QuickPrompt, rows: [QuickPrompt], index: Int, pinned: Bool) -> some View {
        // Treat keyboard focus the same as hover so a Tab-only user gets the
        // same icon brightening + row highlight that a mouse user does.
        let isActive = hoveredID == prompt.id || focusedRowID == prompt.id

        return HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Button {
                withAnimation { viewModel.togglePin(prompt) }
            } label: {
                Image(systemName: prompt.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 13))
                    .foregroundStyle(prompt.isPinned
                                     ? DesignSystem.Colors.accent
                                     : (isActive ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textTertiary))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle()
                            .fill(prompt.isPinned
                                  ? DesignSystem.Colors.accent.opacity(0.12)
                                  : (isActive ? DesignSystem.Colors.rowHoverBackground : .clear))
                    )
            }
            .buttonStyle(.plain)
            .focused($focusedRowID, equals: prompt.id)
            .polishedTooltip(prompt.isPinned ? "Unpin from quick strip" : "Pin to quick strip")
            .accessibilityLabel(prompt.isPinned ? "Unpin \(prompt.label)" : "Pin \(prompt.label)")
            .padding(.top, 2)

            Toggle("", isOn: Binding(
                get: { prompt.isVisible },
                set: { _ in withAnimation { viewModel.toggleVisibility(prompt) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(DesignSystem.Colors.accent)
            .padding(.top, 2)
            .focused($focusedRowID, equals: prompt.id)
            .accessibilityLabel("Show \(prompt.label)")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(prompt.label)
                        .font(DesignSystem.Typography.bodyLarge.weight(.semibold))
                        .foregroundStyle(prompt.isVisible
                                         ? DesignSystem.Colors.textPrimary
                                         : DesignSystem.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let group = prompt.groupLabel, !group.isEmpty {
                        Text(group)
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                            )
                    }

                    if prompt.isBuiltIn {
                        Text("default")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
                            )
                    }

                    Spacer()
                }

                Text(prompt.prompt)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(prompt.isVisible
                                     ? DesignSystem.Colors.textSecondary
                                     : DesignSystem.Colors.textTertiary)
                    .lineLimit(2)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 4) {
                let isFirst = index == 0
                let isLast = index >= rows.count - 1

                Button {
                    movePrompt(prompt, by: -1, in: rows, pinned: pinned)
                } label: {
                    rowIcon("chevron.up", isHovered: isActive)
                }
                .buttonStyle(.plain)
                .disabled(isFirst)
                .opacity(isFirst ? 0.25 : 1)
                .focused($focusedRowID, equals: prompt.id)
                .polishedTooltip(isFirst ? "Already at the top" : "Move up")
                .accessibilityLabel("Move \(prompt.label) up")

                Button {
                    movePrompt(prompt, by: 1, in: rows, pinned: pinned)
                } label: {
                    rowIcon("chevron.down", isHovered: isActive)
                }
                .buttonStyle(.plain)
                .disabled(isLast)
                .opacity(isLast ? 0.25 : 1)
                .focused($focusedRowID, equals: prompt.id)
                .polishedTooltip(isLast ? "Already at the bottom" : "Move down")
                .accessibilityLabel("Move \(prompt.label) down")

                Button {
                    viewModel.editingPrompt = prompt
                } label: {
                    rowIcon("pencil", isHovered: isActive)
                }
                .buttonStyle(.plain)
                .focused($focusedRowID, equals: prompt.id)
                .polishedTooltip("Edit")
                .accessibilityLabel("Edit \(prompt.label)")

                // Built-ins no longer carry a row-level "restore default"
                // button — the action lives inside the Edit sheet (rare,
                // overwrites user edits, deserves a confirmation alert).
                if !prompt.isBuiltIn {
                    Button {
                        pendingDelete = prompt
                    } label: {
                        rowIcon("trash", isHovered: isActive, destructive: true)
                    }
                    .buttonStyle(.plain)
                    .focused($focusedRowID, equals: prompt.id)
                    .polishedTooltip("Delete")
                    .accessibilityLabel("Delete \(prompt.label)")
                }
            }
            .opacity(isActive ? 1.0 : 0.4)
            .animation(.easeInOut(duration: 0.18), value: isActive)
        }
        .padding(DesignSystem.Spacing.lg)
        .background(isActive ? DesignSystem.Colors.surfaceElevated.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hoveredID = hovering ? prompt.id : nil
            }
        }
    }

    private func movePrompt(_ prompt: QuickPrompt, by delta: Int, in rows: [QuickPrompt], pinned: Bool) {
        var ids = rows.map(\.id)
        guard let currentIndex = ids.firstIndex(of: prompt.id) else { return }
        let newIndex = currentIndex + delta
        guard ids.indices.contains(newIndex) else { return }
        ids.swapAt(currentIndex, newIndex)
        withAnimation { viewModel.reorder(ids: ids, pinned: pinned) }
    }

    private func rowIcon(_ system: String, isHovered: Bool, destructive: Bool = false) -> some View {
        let foreground: Color = {
            if destructive { return isHovered ? DesignSystem.Colors.errorRed : DesignSystem.Colors.textTertiary }
            return isHovered ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textTertiary
        }()
        let background: Color = {
            if destructive && isHovered { return DesignSystem.Colors.errorRed.opacity(0.1) }
            return isHovered ? DesignSystem.Colors.rowHoverBackground : .clear
        }()
        return Image(systemName: system)
            .font(.system(size: 13))
            .foregroundStyle(foreground)
            .frame(width: 26, height: 26)
            .background(background)
            .clipShape(Circle())
    }

    private func cardGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
            )
            .cardShadow(DesignSystem.Shadows.cardRest)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(DesignSystem.Typography.body.weight(.medium))
            Spacer()
        }
        .foregroundStyle(DesignSystem.Colors.errorRed)
        .padding()
        .background(DesignSystem.Colors.errorRed.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
    }
}

// MARK: - Edit / Create

/// Edit-in-place sheet. Built-ins are editable here too — that is the
/// intentional divergence from Prompt Library (where built-ins are read-only).
private struct EditPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initial: QuickPrompt
    let onSave: (QuickPrompt) -> Bool
    let onCancel: () -> Void
    /// Optional restore-default action. Only invoked for built-ins (the sheet
    /// renders the restore affordance when this is non-nil and `initial.isBuiltIn`).
    /// Caller is responsible for performing the restore — the sheet only
    /// gathers user confirmation before firing.
    let onRestore: (() -> Void)?

    @State private var label: String
    @State private var promptBody: String
    @State private var groupLabel: String
    @State private var showingDiscardConfirm = false
    @State private var showingRestoreConfirm = false

    init(
        prompt: QuickPrompt,
        onSave: @escaping (QuickPrompt) -> Bool,
        onCancel: @escaping () -> Void,
        onRestore: (() -> Void)? = nil
    ) {
        self.initial = prompt
        self.onSave = onSave
        self.onCancel = onCancel
        self.onRestore = onRestore
        self._label = State(initialValue: prompt.label)
        self._promptBody = State(initialValue: prompt.prompt)
        self._groupLabel = State(initialValue: prompt.groupLabel ?? "")
    }

    /// True when the form's user-visible content differs from the row that was
    /// opened. Drives the discard-confirm prompt: a no-op Cancel is silent;
    /// a Cancel after real edits asks before throwing the work away (Apple's
    /// document-close pattern). Trim the group string before comparing so a
    /// trailing space added to "CATCH UP" doesn't trigger a phantom prompt.
    private var hasChanges: Bool {
        let normalizedGroup = groupLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialGroup = initial.groupLabel ?? ""
        return label != initial.label
            || promptBody != initial.prompt
            || normalizedGroup != initialGroup
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSystem.Spacing.md) {
                Text("Edit prompt")
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                if let onRestore, initial.isBuiltIn {
                    restoreButton(onRestore: onRestore)
                }
                Spacer()
                Button("Cancel") { attemptCancel() }
                    .parakeetAction(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .parakeetAction(.primaryProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DesignSystem.Spacing.lg)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    field(title: "Label (shown on the pill)", text: $label, placeholder: "Tell me more")
                    field(
                        title: "Group (optional — e.g. CATCH UP, CAPTURE, CHALLENGE)",
                        text: $groupLabel,
                        placeholder: "Leave blank for ungrouped"
                    )
                    promptField
                }
                .padding(DesignSystem.Spacing.xl)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(.thickMaterial)
        .alert("Discard changes?", isPresented: $showingDiscardConfirm) {
            Button("Discard", role: .destructive) {
                onCancel()
                dismiss()
            }
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text("Your edits to '\(initial.label)' will be lost.")
        }
        .alert("Restore '\(initial.label)' to default?", isPresented: $showingRestoreConfirm) {
            Button("Restore", role: .destructive) {
                onRestore?()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Returns to its original label, prompt, group, sort order, and pin state (when the pinned cap allows). Visibility is kept. Any unsaved edits in this sheet will also be discarded.")
        }
    }

    private func restoreButton(onRestore: @escaping () -> Void) -> some View {
        Button {
            showingRestoreConfirm = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .medium))
                Text("Restore default")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Restore '\(initial.label)' to default")
    }

    private func attemptCancel() {
        if hasChanges {
            showingDiscardConfirm = true
        } else {
            onCancel()
            dismiss()
        }
    }

    private func field(title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(title)
                .font(DesignSystem.Typography.caption.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.bodyLarge)
                .padding(10)
                .background(DesignSystem.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
                )
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Prompt sent to the LLM")
                .font(DesignSystem.Typography.caption.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $promptBody)
                    .font(DesignSystem.Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if promptBody.isEmpty {
                    Text("Expand on your previous response with concrete detail from the meeting…")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .padding(.top, 8)
                        .padding(.leading, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 180)
            .background(DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
            )
        }
    }

    private func commit() {
        var updated = initial
        updated.label = label
        updated.prompt = promptBody
        let trimmed = groupLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.groupLabel = trimmed.isEmpty ? nil : trimmed
        if onSave(updated) {
            dismiss()
        }
    }
}

private struct CreatePromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: QuickPromptsViewModel

    @State private var showingDiscardConfirm = false

    /// True when any draft field has content. A clean Cancel from a blank
    /// form is silent; otherwise we prompt before throwing the work away.
    private var hasContent: Bool {
        guard let draft = viewModel.creating else { return false }
        return !draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.groupLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New prompt")
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Button("Cancel") { attemptCancel() }
                    .parakeetAction(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if viewModel.commitCreating() {
                        dismiss()
                    }
                }
                .parakeetAction(.primaryProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(DesignSystem.Spacing.lg)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    if viewModel.creating != nil {
                        field(
                            title: "Label (shown on the pill)",
                            binding: Binding(
                                get: { viewModel.creating?.label ?? "" },
                                set: { viewModel.creating?.label = $0 }
                            ),
                            placeholder: "ELI5"
                        )
                        field(
                            title: "Group (optional)",
                            binding: Binding(
                                get: { viewModel.creating?.groupLabel ?? "" },
                                set: { viewModel.creating?.groupLabel = $0 }
                            ),
                            placeholder: "CATCH UP / CAPTURE / CHALLENGE"
                        )
                        promptField
                        Text("New prompts start unpinned. Click the pin icon in the list to keep one handy during meetings.")
                            .font(DesignSystem.Typography.bodySmall)
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    }
                }
                .padding(DesignSystem.Spacing.xl)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(.thickMaterial)
        .alert("Discard new prompt?", isPresented: $showingDiscardConfirm) {
            Button("Discard", role: .destructive) {
                viewModel.cancelCreating()
                dismiss()
            }
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text("Your draft will be lost.")
        }
    }

    private func attemptCancel() {
        if hasContent {
            showingDiscardConfirm = true
        } else {
            viewModel.cancelCreating()
            dismiss()
        }
    }

    private func field(title: String, binding: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(title)
                .font(DesignSystem.Typography.caption.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            TextField(placeholder, text: binding)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.bodyLarge)
                .padding(10)
                .background(DesignSystem.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
                )
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Prompt sent to the LLM")
                .font(DesignSystem.Typography.caption.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(
                    get: { viewModel.creating?.prompt ?? "" },
                    set: { viewModel.creating?.prompt = $0 }
                ))
                .font(DesignSystem.Typography.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                if (viewModel.creating?.prompt ?? "").isEmpty {
                    Text("Explain your previous response like I'm five…")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                        .padding(.top, 8)
                        .padding(.leading, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 180)
            .background(DesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                    .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
            )
        }
    }
}
