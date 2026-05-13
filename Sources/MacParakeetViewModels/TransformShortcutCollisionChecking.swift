import Foundation
import MacParakeetCore

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
            return "This shortcut produces a special character on Mac (\u{2325} dead-key). Pick another combo."
        case .duplicateTransform:
            return "Another Transform already uses this shortcut."
        case .reservedHotkey(let name, let shortcut):
            return "This shortcut conflicts with \(name): \(shortcut)."
        }
    }
}
