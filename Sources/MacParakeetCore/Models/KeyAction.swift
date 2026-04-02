import Foundation

/// A keystroke action that can be simulated after dictation paste.
public enum KeyAction: String, Codable, Sendable, CaseIterable, Equatable {
    case returnKey = "return"

    /// The CGKeyCode for this action.
    public var keyCode: UInt16 {
        switch self {
        case .returnKey: return 0x24
        }
    }

    /// Human-readable label for the UI.
    public var label: String {
        switch self {
        case .returnKey: return "⏎ Return"
        }
    }
}
