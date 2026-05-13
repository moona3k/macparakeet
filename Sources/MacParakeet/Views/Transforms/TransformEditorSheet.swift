import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Modal sheet for Create-your-own and Edit-Transform flows (ADR-022).
///
/// Two-column layout: framing copy on the left (~32% width), three stacked
/// field cards on the right (Name → Keyboard shortcut → Customize prompt
/// → optional Running label). Footer: *Autosave On* indicator on builtins,
/// Cancel + Save on the right.
///
/// Validation is reactive — fires on every field change after the first
/// interaction, surfacing per-card error rows. Save button gates on
/// `viewModel.isValid`.
struct TransformEditorSheet: View {
    @Bindable var viewModel: TransformEditorViewModel
    let existingTransforms: [Prompt]
    let reservedHotkeys: [TransformShortcutReservedHotkey]
    let onShortcutRecordingStateChanged: (Bool) -> Void
    let onSave: (Prompt) -> Void
    let onCancel: () -> Void
    let onReset: (() -> Void)?

    @State private var isRecordingShortcut = false
    private let collisionChecker = TransformsHotkeyCollisionChecker()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                leftRail
                    .frame(width: 280)
                    .padding(DesignSystem.Spacing.xl)

                Divider()

                ScrollView {
                    VStack(spacing: DesignSystem.Spacing.lg) {
                        nameCard
                        shortcutCard
                        contentCard
                        runningLabelCard
                    }
                    .padding(DesignSystem.Spacing.xl)
                }
                .frame(maxWidth: .infinity)
                .background(DesignSystem.Colors.surfaceElevated.opacity(0.3))
            }
            .frame(maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 880, minHeight: 540, idealHeight: 620)
        .background(DesignSystem.Colors.surface)
    }

    // MARK: - Sections

    @ViewBuilder
    private var leftRail: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text(viewModel.mode.isCreating ? "Create your own" : "Edit Transform")
                .font(DesignSystem.Typography.heroTitle)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Set up a keyboard shortcut and a prompt. MacParakeet runs the prompt against your selected text every time you press the shortcut.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Spacer(minLength: 0)

            if viewModel.isBuiltIn {
                Label("Built-in Transform — you can edit it freely. Your changes survive app launches.", systemImage: "checkmark.seal")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var nameCard: some View {
        EditorCard(title: "Name your Transform shortcut") {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                TextField("Boss Mode", text: $viewModel.name)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.bodyLarge)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.sm + 2)
                    .background(DesignSystem.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                    }
                    .onChange(of: viewModel.name) { _, _ in revalidate() }

                if let error = viewModel.nameError {
                    ValidationRow(message: error)
                }
            }
        }
    }

    @ViewBuilder
    private var shortcutCard: some View {
        EditorCard(title: "Choose a keyboard shortcut") {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                ShortcutRecorderField(
                    shortcut: $viewModel.shortcut,
                    isRecording: $isRecordingShortcut,
                    onRecordingStateChanged: onShortcutRecordingStateChanged
                )
                .onChange(of: viewModel.shortcut) { _, _ in revalidate() }

                if let error = viewModel.shortcutError {
                    ValidationRow(message: error)
                } else if viewModel.shortcut == nil {
                    Text("Optional — leave empty to keep this Transform dormant.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var contentCard: some View {
        EditorCard(title: "Customize prompt") {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                TextEditor(text: $viewModel.content)
                    .font(DesignSystem.Typography.body)
                    .scrollContentBackground(.hidden)
                    .padding(DesignSystem.Spacing.sm)
                    .frame(minHeight: 180)
                    .background(DesignSystem.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                    }
                    .onChange(of: viewModel.content) { _, _ in revalidate() }

                if let error = viewModel.contentError {
                    ValidationRow(message: error)
                } else {
                    Text("Tell the LLM how to change the selected text. Be specific — the prompt runs verbatim on every press.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var runningLabelCard: some View {
        EditorCard(title: "Running label (optional)") {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                TextField("Polishing\u{2026}", text: $viewModel.runningLabel)
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
                Text("Shown in the floating pill while this Transform runs. Defaults to “\(viewModel.normalizedName.isEmpty ? "Transforming\u{2026}" : "\(viewModel.normalizedName)ing\u{2026}")”.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            if let onReset, viewModel.isBuiltIn {
                Button("Reset to default", action: onReset)
                    .parakeetAction(.subtle)
            }

            Spacer()

            Button("Cancel", action: onCancel)
                .parakeetAction(.secondary)
                .keyboardShortcut(.cancelAction)

            Button(viewModel.mode.isCreating ? "Create Transform" : "Save Changes") {
                guard let prompt = viewModel.buildSavable() else { return }
                onSave(prompt)
            }
            .parakeetAction(.primary)
            .disabled(!viewModel.isValid)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.md)
        .background(DesignSystem.Colors.surface)
    }

    // MARK: - Validation hook

    private func revalidate() {
        viewModel.validate(
            existingTransforms: existingTransforms,
            reservedHotkeys: reservedHotkeys,
            collisionChecker: collisionChecker
        )
    }
}

// MARK: - Editor card chrome

private struct EditorCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(title)
                .font(DesignSystem.Typography.sectionTitle)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            content
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
        }
    }
}

private struct ValidationRow: View {
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
        .padding(.top, 2)
    }
}

// MARK: - Shortcut recorder field
//
// Lightweight recorder that listens for the next key chord while focused.
// Keeps the AppKit-level NSEvent monitor scoped to its focused state, so
// the surrounding sheet keeps normal text-field behaviour.

struct ShortcutRecorderField: View {
    @Binding var shortcut: TransformShortcut?
    @Binding var isRecording: Bool
    let onRecordingStateChanged: (Bool) -> Void
    @State private var localMonitor: Any?
    @State private var notifiedRecordingActive = false

    var body: some View {
        HStack {
            Group {
                if let shortcut {
                    HStack(spacing: 6) {
                        KeycapBadge(shortcut: shortcut)
                        Text(shortcut.keyLabel.uppercased())
                            .font(DesignSystem.Typography.bodySmall.monospacedDigit())
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                            .accessibilityHidden(true)
                    }
                } else {
                    Text(isRecording ? "Press a keyboard combo\u{2026}" : "Click to add a shortcut")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(isRecording ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
                }
            }
            Spacer()
            Button(action: { isRecording.toggle() }) {
                Image(systemName: isRecording ? "stop.circle" : "pencil")
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            if shortcut != nil {
                Button(action: { shortcut = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm + 2)
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isRecording ? DesignSystem.Colors.accent : DesignSystem.Colors.border,
                    lineWidth: isRecording ? 1.0 : 0.5
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isRecording.toggle()
        }
        .onChange(of: isRecording) { _, recording in
            if recording {
                notifyRecordingState(true)
                installMonitor()
            } else {
                removeMonitor()
                notifyRecordingState(false)
            }
        }
        .onDisappear { stopRecordingIfNeeded() }
    }

    private func installMonitor() {
        removeMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let modifierBits = UInt(event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue)
            let keyCode = event.keyCode
            let label = labelForKey(event: event)
            shortcut = TransformShortcut(
                modifiers: modifierBits,
                keyCode: keyCode,
                keyLabel: label
            )
            isRecording = false
            return nil // swallow the event
        }
    }

    private func removeMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func stopRecordingIfNeeded() {
        if isRecording {
            isRecording = false
        }
        removeMonitor()
        notifyRecordingState(false)
    }

    private func notifyRecordingState(_ active: Bool) {
        guard notifiedRecordingActive != active else { return }
        notifiedRecordingActive = active
        onRecordingStateChanged(active)
    }

    private func labelForKey(event: NSEvent) -> String {
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            let scalar = chars.first!
            // Map common control codes to display names.
            switch event.keyCode {
            case 0x24: return "Return"
            case 0x30: return "Tab"
            case 0x31: return "Space"
            case 0x35: return "Escape"
            default:
                if scalar.isLetter || scalar.isNumber {
                    return String(scalar).uppercased()
                }
                if scalar.asciiValue.map({ $0 >= 32 }) ?? false {
                    return String(scalar)
                }
            }
        }
        return "Key \(event.keyCode)"
    }
}
