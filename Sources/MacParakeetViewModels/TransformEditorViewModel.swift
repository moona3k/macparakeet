import Foundation
import MacParakeetCore

/// Drives the **Create your own** / **Edit Transform** sheet (ADR-022).
/// Owns the draft state of one Transform (name + shortcut + prompt body +
/// optional running label) plus the live validation that surfaces in the
/// editor card chrome.
///
/// Validation is deliberately strict — every field has a clear rule so the
/// user knows what's needed before they can save. Inline rules:
///
/// - Name: required, no leading/trailing whitespace, must be unique
///   case-insensitively across all Transforms (matches the existing
///   `idx_prompts_name` SQLite uniqueness index).
/// - Shortcut: optional in the draft (the editor pre-fills it), but if
///   present must include a modifier, not be a macOS dead-key, and not
///   collide with another Transform / dictation / meeting hotkey.
/// - Prompt body: required.
///
/// The view layer pairs this with a `TransformsHotkeyCollisionChecker`
/// instance (Sources/MacParakeet/Hotkey) for the shortcut-collision
/// branch. The collision results map directly to `shortcutError`.
@MainActor
@Observable
public final class TransformEditorViewModel {
    public enum Mode {
        case create
        case edit(Prompt)

        var initialPrompt: Prompt? {
            switch self {
            case .create: return nil
            case .edit(let prompt): return prompt
            }
        }

        public var isEditing: Bool {
            if case .edit = self { return true }
            return false
        }

        public var isCreating: Bool {
            if case .create = self { return true }
            return false
        }
    }

    public let mode: Mode

    public var name: String = "" {
        didSet { nameError = nil }
    }
    public var content: String = "" {
        didSet { contentError = nil }
    }
    public var runningLabel: String = ""
    public var shortcut: KeyboardShortcut? {
        didSet { shortcutError = nil }
    }

    // Per-field validation messages. Nil = valid (or not yet checked).
    public var nameError: String?
    public var contentError: String?
    public var shortcutError: String?

    /// True when every required field is valid. Save buttons gate on this.
    public var isValid: Bool {
        normalizedName.isEmpty == false
            && nameError == nil
            && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && contentError == nil
            && shortcutError == nil
    }

    public var isBuiltIn: Bool {
        guard case .edit(let prompt) = mode else { return false }
        return prompt.isBuiltIn
    }

    public init(mode: Mode) {
        self.mode = mode
        if let initial = mode.initialPrompt {
            name = initial.name
            content = initial.content
            runningLabel = initial.runningLabel ?? ""
            shortcut = initial.shortcut
        }
    }

    // MARK: - Validation

    /// Run all validation rules against the current draft + the surrounding
    /// state passed in by the view layer. The view layer is responsible
    /// for providing the *other* transforms' bindings, the user's dictation
    /// hotkey, and the meeting-toggle hotkey — they live outside the
    /// editor's awareness.
    public func validate(
        existingTransforms: [Prompt],
        reservedHotkeys: [TransformShortcutReservedHotkey],
        collisionChecker: TransformShortcutCollisionChecking
    ) {
        validateName(against: existingTransforms)
        validateContent()
        validateShortcut(
            existingTransforms: existingTransforms,
            reservedHotkeys: reservedHotkeys,
            collisionChecker: collisionChecker
        )
    }

    private func validateName(against existing: [Prompt]) {
        let trimmed = normalizedName
        if trimmed.isEmpty {
            nameError = "Give your Transform a name."
            return
        }
        let editingID: UUID? = mode.initialPrompt?.id
        let duplicate = existing.contains { other in
            other.id != editingID
                && other.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        nameError = duplicate ? "Another Transform already uses this name." : nil
    }

    private func validateContent() {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        contentError = trimmed.isEmpty ? "Give your Transform a prompt to run on the selected text." : nil
    }

    private func validateShortcut(
        existingTransforms: [Prompt],
        reservedHotkeys: [TransformShortcutReservedHotkey],
        collisionChecker: TransformShortcutCollisionChecking
    ) {
        guard let candidate = shortcut else {
            // A nil shortcut is a valid dormant state. Surface a friendly
            // hint (rather than an error) at the view layer; the VM keeps
            // shortcutError nil so save is unblocked.
            shortcutError = nil
            return
        }
        let editingID = mode.initialPrompt?.id
        let bindings: [UUID: KeyboardShortcut] = Dictionary(uniqueKeysWithValues:
            existingTransforms.compactMap { prompt in
                guard let s = prompt.shortcut else { return nil }
                return (prompt.id, s)
            }
        )
        let collision = collisionChecker.checkForEditor(
            candidate: candidate,
            existing: bindings,
            excludingPromptID: editingID,
            reservedHotkeys: reservedHotkeys
        )
        shortcutError = collision?.message
    }

    // MARK: - Build the persistable Prompt

    /// Returns the Prompt the view should persist on save. Returns nil if
    /// validation has flagged any blocking error.
    public func buildSavable() -> Prompt? {
        guard isValid else { return nil }
        let now = Date()
        let trimmedName = normalizedName
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLabel = runningLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedShortcut = shortcut?.encodedString()

        switch mode {
        case .create:
            return Prompt(
                id: UUID(),
                name: trimmedName,
                content: trimmedContent,
                category: .transform,
                isBuiltIn: false,
                isVisible: true,
                isAutoRun: false,
                sortOrder: 200,
                createdAt: now,
                updatedAt: now,
                keyboardShortcut: encodedShortcut,
                runningLabel: trimmedLabel.isEmpty ? nil : trimmedLabel
            )
        case .edit(let original):
            var updated = original
            updated.name = trimmedName
            updated.content = trimmedContent
            updated.keyboardShortcut = encodedShortcut
            updated.runningLabel = trimmedLabel.isEmpty ? nil : trimmedLabel
            updated.updatedAt = now
            return updated
        }
    }

    // MARK: - Helpers

    public var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Collision-checking abstraction
//
// `TransformsHotkeyCollisionChecker` itself lives in the MacParakeet GUI
// target (alongside the registry). The ViewModels target can't import
// MacParakeet, so we define a small protocol here that the GUI side
// retroactively conforms to. Tests can fake it without dragging in
// CGEvent infrastructure.

public protocol TransformShortcutCollisionChecking {
    /// Named distinctly from the GUI checker's `check(...)` so the adapter
    /// in MacParakeet doesn't introduce an ambiguity with the underlying
    /// type's own method of the same shape.
    func checkForEditor(
        candidate: KeyboardShortcut,
        existing: [UUID: KeyboardShortcut],
        excludingPromptID: UUID?,
        reservedHotkeys: [TransformShortcutReservedHotkey]
    ) -> TransformShortcutCollision?
}

/// Mirror of the GUI's `TransformsHotkeyCollision` for ViewModel-layer use.
/// The GUI's checker has a small adapter that maps between the two.
public enum TransformShortcutCollision: Equatable, Sendable {
    case missingModifier
    case macOSDeadKey
    case duplicateTransform(otherPromptID: UUID)
    case reservedHotkey(name: String, shortcut: String)

    public var message: String {
        switch self {
        case .missingModifier:
            return "Shortcut must include a modifier key (\u{2303}, \u{2325}, \u{21E7}, or \u{2318})."
        case .macOSDeadKey:
            return "This shortcut produces a special character on Mac. Pick another combo."
        case .duplicateTransform:
            return "Another Transform already uses this shortcut."
        case .reservedHotkey(let name, let shortcut):
            return "This shortcut conflicts with \(name): \(shortcut)."
        }
    }
}
