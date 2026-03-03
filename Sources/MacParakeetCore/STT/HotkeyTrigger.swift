import Foundation

/// A hotkey trigger that supports both modifier keys and regular key codes.
/// Replaces the old `TriggerKey` enum with an extensible struct.
public struct HotkeyTrigger: Equatable, Sendable, Codable {

    // MARK: - Kind

    public enum Kind: String, Codable, Sendable {
        case modifier
        case keyCode
    }

    // MARK: - Validation

    public enum ValidationResult: Equatable, Sendable {
        case allowed
        case warned(String)
        case blocked(String)
    }

    // MARK: - Properties

    public let kind: Kind
    /// Raw modifier name ("fn", "control", etc.) for `.modifier` kind. Nil for `.keyCode`.
    public let modifierName: String?
    /// CGKeyCode for `.keyCode` kind. Nil for `.modifier`.
    public let keyCode: UInt16?
    /// Human-readable name for UI display (e.g., "Fn", "End", "F13").
    public let displayName: String
    /// Short symbol for compact display (e.g., "fn", "⌃", "End", "F13").
    public let shortSymbol: String

    // MARK: - Modifier Presets

    public static let fn = HotkeyTrigger(
        kind: .modifier, modifierName: "fn", keyCode: nil,
        displayName: "Fn", shortSymbol: "fn"
    )
    public static let control = HotkeyTrigger(
        kind: .modifier, modifierName: "control", keyCode: nil,
        displayName: "Control", shortSymbol: "⌃"
    )
    public static let option = HotkeyTrigger(
        kind: .modifier, modifierName: "option", keyCode: nil,
        displayName: "Option", shortSymbol: "⌥"
    )
    public static let shift = HotkeyTrigger(
        kind: .modifier, modifierName: "shift", keyCode: nil,
        displayName: "Shift", shortSymbol: "⇧"
    )
    public static let command = HotkeyTrigger(
        kind: .modifier, modifierName: "command", keyCode: nil,
        displayName: "Command", shortSymbol: "⌘"
    )

    /// All modifier presets for UI iteration.
    public static let modifierPresets: [HotkeyTrigger] = [.fn, .control, .option, .shift, .command]

    // MARK: - Factory

    /// Create a trigger from a CGKeyCode.
    public static func fromKeyCode(_ code: UInt16) -> HotkeyTrigger {
        let names = KeyCodeNames.name(for: code)
        return HotkeyTrigger(
            kind: .keyCode, modifierName: nil, keyCode: code,
            displayName: names.displayName, shortSymbol: names.shortSymbol
        )
    }

    // MARK: - Validation

    public var validation: ValidationResult {
        guard kind == .keyCode, let code = keyCode else { return .allowed }

        // Escape is permanently reserved for cancel-dictation
        if code == 53 {
            return .blocked("Escape is reserved for canceling dictation.")
        }

        // Space, Return, Tab — likely to interfere with typing
        if code == 49 || code == 36 || code == 48 {
            return .warned("May interfere with typing.")
        }

        // Arrow keys — may interfere with text editing
        if code == 126 || code == 125 || code == 123 || code == 124 {
            return .warned("May interfere with text editing.")
        }

        // Letter keys (A=0..Z, roughly keycodes 0-50 minus the special ones already handled)
        // Number keys (keycode 18-29 for 1-0)
        // Rather than enumerate all, warn for codes in the "typing" range that aren't
        // function/navigation/special keys. Function keys, nav keys, and F13+ are safe.
        let safeKeyCodes: Set<UInt16> = [
            // Function keys
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
            105, 107, 113, 106, 64, 79, 80, 90,
            // Navigation
            115, 119, 116, 121, 117,
            // Caps Lock
            57,
        ]
        if !safeKeyCodes.contains(code) {
            return .warned("May interfere with typing.")
        }

        return .allowed
    }

    // MARK: - Persistence

    private static let defaultsKey = "hotkeyTrigger"

    /// Legacy modifier names from the old TriggerKey enum.
    private static let legacyModifiers: [String: HotkeyTrigger] = [
        "fn": .fn, "control": .control, "option": .option,
        "shift": .shift, "command": .command,
    ]

    /// Resolve the configured trigger from the provided defaults store.
    /// Tries JSON decode first, falls back to legacy string, defaults to `.fn`.
    public static func current(defaults: UserDefaults = .standard) -> HotkeyTrigger {
        guard let stored = defaults.object(forKey: defaultsKey) else {
            return .fn
        }

        // Try JSON data first (new format)
        if let data = defaults.data(forKey: defaultsKey),
           let trigger = try? JSONDecoder().decode(HotkeyTrigger.self, from: data) {
            return trigger
        }

        // Fall back to legacy plain string ("fn", "control", etc.)
        if let raw = stored as? String, let trigger = legacyModifiers[raw] {
            return trigger
        }

        return .fn
    }

    /// Convenience accessor using standard user defaults.
    public static var current: HotkeyTrigger {
        current(defaults: .standard)
    }

    /// Persist this trigger to the given defaults store as JSON.
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
