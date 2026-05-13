import Foundation
import MacParakeetCore
import MacParakeetViewModels

extension TransformsHotkeyCollisionChecker: TransformShortcutCollisionChecking {
    public func checkForEditor(
        candidate: KeyboardShortcut,
        existing: [UUID: KeyboardShortcut],
        excludingPromptID: UUID?,
        reservedHotkeys: [TransformShortcutReservedHotkey]
    ) -> TransformShortcutCollision? {
        let result: TransformsHotkeyCollision? = self.check(
            candidate: candidate,
            existing: existing,
            excludingPromptID: excludingPromptID,
            reservedHotkeys: reservedHotkeys
        )
        switch result {
        case nil: return nil
        case .missingModifier: return .missingModifier
        case .macOSDeadKey: return .macOSDeadKey
        case .duplicateTransform(let id): return .duplicateTransform(otherPromptID: id)
        case .reservedHotkey(let name, let shortcut): return .reservedHotkey(name: name, shortcut: shortcut)
        }
    }
}
