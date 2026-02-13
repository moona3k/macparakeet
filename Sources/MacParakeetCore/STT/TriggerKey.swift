import Foundation

/// Supported trigger keys for dictation hotkey.
/// The state machine behavior (double-tap / hold) is identical for all keys.
public enum TriggerKey: String, CaseIterable, Codable, Sendable {
    case fn = "fn"
    case control = "control"
    case option = "option"
    case shift = "shift"
    case command = "command"

    /// Human-readable name for UI display (e.g., "Fn", "Control").
    public var displayName: String {
        switch self {
        case .fn: return "Fn"
        case .control: return "Control"
        case .option: return "Option"
        case .shift: return "Shift"
        case .command: return "Command"
        }
    }

    /// Short symbol for compact display (e.g., "fn", "⌃").
    public var shortSymbol: String {
        switch self {
        case .fn: return "fn"
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }

    /// Resolve the configured trigger key from the provided defaults store.
    /// Defaults to `.fn` if not set or invalid.
    public static func current(defaults: UserDefaults = .standard) -> TriggerKey {
        guard let raw = defaults.string(forKey: "hotkeyTrigger"),
              let key = TriggerKey(rawValue: raw) else {
            return .fn
        }
        return key
    }

    /// The currently configured trigger key from standard user defaults.
    public static var current: TriggerKey {
        current(defaults: .standard)
    }
}
