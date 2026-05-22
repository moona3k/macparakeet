import Foundation

public struct TransformShortcutReservedHotkey: Sendable, Equatable {
    public let name: String
    public let trigger: HotkeyTrigger
    public let conflictMode: HotkeyTrigger.ConflictMode

    public init(
        name: String,
        trigger: HotkeyTrigger,
        conflictMode: HotkeyTrigger.ConflictMode = .exclusive
    ) {
        self.name = name
        self.trigger = trigger
        self.conflictMode = conflictMode
    }
}
