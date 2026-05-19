import Foundation

/// A keyboard shortcut bound to a Transform (or any other surface that needs
/// a serializable hotkey binding).
///
/// Persisted on `Prompt` (category `.transform`) as a JSON-encoded string in
/// the `keyboardShortcut` column. NULL means "no shortcut bound" — a valid,
/// dormant state. Built-ins ship with a default binding; users can clear it.
///
/// The struct intentionally stores the *recorded* shortcut, not the
/// resolved-against-current-layout shortcut. The system event tap matches on
/// virtual keycode (`keyCode`), which is layout-agnostic, so a binding made
/// on QWERTY keeps working on Dvorak. The `keyLabel` is for display only —
/// it captures what the user saw on their keyboard when they bound it.
public struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    /// Carbon-style modifier flags. Bitwise OR of `ModifierFlag` raw values.
    public let modifiers: UInt
    /// Virtual keycode (`kVK_*`) — layout-agnostic.
    public let keyCode: UInt16
    /// Human-readable label of the bound key (e.g. "1", "P", "F13") as the
    /// user saw it when they bound the shortcut. Used for display only.
    public let keyLabel: String

    public init(modifiers: UInt, keyCode: UInt16, keyLabel: String) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.keyLabel = keyLabel
    }

    /// Standalone modifier flags — value matches NSEvent.ModifierFlags raw
    /// values for the Cocoa-side checks, intentionally compatible with the
    /// existing hotkey infrastructure.
    public enum ModifierFlag: UInt, CaseIterable, Sendable {
        case command  = 0x100000   // NSEvent.ModifierFlags.command
        case option   = 0x080000   // NSEvent.ModifierFlags.option
        case control  = 0x040000   // NSEvent.ModifierFlags.control
        case shift    = 0x020000   // NSEvent.ModifierFlags.shift

        public var displayGlyph: String {
            switch self {
            case .command: return "⌘"
            case .option:  return "⌥"
            case .control: return "⌃"
            case .shift:   return "⇧"
            }
        }

        public var displayName: String {
            switch self {
            case .command: return "Command"
            case .option:  return "Option"
            case .control: return "Control"
            case .shift:   return "Shift"
            }
        }

        fileprivate var hotkeyTriggerModifierName: String {
            switch self {
            case .command: return "command"
            case .option:  return "option"
            case .control: return "control"
            case .shift:   return "shift"
            }
        }
    }

    public var modifierFlags: Set<ModifierFlag> {
        Set(ModifierFlag.allCases.filter { (modifiers & $0.rawValue) != 0 })
    }

    public var hasModifier: Bool {
        !modifierFlags.isEmpty
    }

    /// Render modifiers in the canonical macOS order: ⌃ ⌥ ⇧ ⌘.
    public var displayString: String {
        let ordered: [ModifierFlag] = [.control, .option, .shift, .command]
        let glyphs = ordered
            .filter { (modifiers & $0.rawValue) != 0 }
            .map(\.displayGlyph)
            .joined()
        return glyphs + displayKeyLabel
    }

    public var displayKeyLabel: String {
        Self.displayKeyLabel(for: keyCode, fallback: keyLabel)
    }

    public static func displayKeyLabel(for keyCode: UInt16, fallback keyLabel: String) -> String {
        if let digit = digitKeyLabelsByKeyCode[keyCode] {
            return digit
        }
        if let named = namedKeyLabelsByKeyCode[keyCode] {
            return named
        }
        return keyLabel.uppercased()
    }

    // MARK: - String parsing (CLI input)

    /// Parse a human-readable shortcut string from the CLI, e.g. `"opt+1"`,
    /// `"cmd+shift+p"`, `"ctrl+opt+space"`. Order-insensitive among
    /// modifiers. Returns nil if the format is unrecognizable.
    ///
    /// Recognized modifier tokens (case-insensitive):
    /// `cmd`, `command`, `meta`, `⌘` → command
    /// `opt`, `option`, `alt`, `⌥` → option
    /// `ctrl`, `control`, `⌃` → control
    /// `shift`, `⇧` → shift
    public static func parse(_ raw: String) -> KeyboardShortcut? {
        let tokens = raw
            .split(whereSeparator: { "+- ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        var mods: UInt = 0
        var keyToken: String?
        for token in tokens {
            if let flag = parseModifier(token) {
                mods |= flag.rawValue
            } else {
                guard keyToken == nil else { return nil } // two non-modifier tokens
                keyToken = token
            }
        }
        guard let key = keyToken else { return nil }
        guard let (keyCode, label) = parseKey(key) else { return nil }

        return KeyboardShortcut(modifiers: mods, keyCode: keyCode, keyLabel: label)
    }

    private static func parseModifier(_ token: String) -> ModifierFlag? {
        switch token {
        case "cmd", "command", "meta", "⌘": return .command
        case "opt", "option", "alt", "⌥":   return .option
        case "ctrl", "control", "⌃":         return .control
        case "shift", "⇧":                   return .shift
        default: return nil
        }
    }

    /// Map a key token to (virtual keycode, display label). Covers the common
    /// surface used by Transform bindings — digits, letters, and a small
    /// set of named keys. Returns nil for unrecognized keys.
    private static func parseKey(_ token: String) -> (UInt16, String)? {
        if let digit = digitKeyCodes[token] {
            return (digit, token)
        }
        if token.count == 1, let letter = letterKeyCodes[token] {
            return (letter, token.uppercased())
        }
        if let named = namedKeyCodes[token] {
            return named
        }
        return nil
    }

    // Subset of Carbon's `kVK_*` virtual key codes. The values match
    // <Carbon/HIToolbox/Events.h>. We avoid importing Carbon at the model
    // layer to keep MacParakeetCore portable; the values are stable.
    private static let digitKeyCodes: [String: UInt16] = [
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17,
        "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
    ]

    private static let digitKeyLabelsByKeyCode: [UInt16: String] = [
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0",
    ]

    private static let letterKeyCodes: [String: UInt16] = [
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E,
        "f": 0x03, "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26,
        "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D, "o": 0x1F,
        "p": 0x23, "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
        "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07, "y": 0x10,
        "z": 0x06,
    ]

    private static let namedKeyCodes: [String: (UInt16, String)] = [
        "space":  (0x31, "Space"),
        "return": (0x24, "Return"),
        "enter":  (0x24, "Return"),
        "tab":    (0x30, "Tab"),
        "escape": (0x35, "Escape"),
        "esc":    (0x35, "Escape"),
    ]

    private static let namedKeyLabelsByKeyCode: [UInt16: String] = [
        0x24: "Return",
        0x30: "Tab",
        0x31: "Space",
        0x35: "Escape",
    ]

    // MARK: - Dead-key blocklist
    //
    // macOS Opt+letter combos that produce alt-characters and would be hostile
    // to steal. The collision detector flags these at bind time. Source:
    // Apple's "Special Characters" table — the most commonly typed dead keys.
    private static let optionDeadKeyLabels: Set<String> = [
        "E", "U", "I", "N", "`",
    ]

    /// True if this shortcut maps to a known macOS dead key combo (`Opt+e`,
    /// `Opt+u`, etc.). Bindings on these combos are rejected by the
    /// `TransformsHotkeyRegistry` collision rules.
    public var isMacOSDeadKey: Bool {
        let onlyOption = (modifiers == ModifierFlag.option.rawValue)
        return onlyOption && Self.optionDeadKeyLabels.contains(keyLabel.uppercased())
    }

    /// Equivalent `HotkeyTrigger` used for overlap checks against the app's
    /// existing dictation / meeting hotkey model.
    public var hotkeyTrigger: HotkeyTrigger {
        HotkeyTrigger.chord(
            modifiers: modifierFlags.map(\.hotkeyTriggerModifierName),
            keyCode: keyCode
        )
    }
}

// MARK: - Persistence helpers

extension KeyboardShortcut {
    /// Encode the shortcut to a JSON string suitable for the SQLite TEXT
    /// column. Returns nil if encoding fails (shouldn't happen with the
    /// fixed shape, but caller handles it defensively).
    public func encodedString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode a JSON-string-encoded shortcut from the DB column. Returns nil
    /// on bad input — the caller should treat that as "no shortcut bound"
    /// rather than crashing, since the persistence column is user-mutable
    /// only through this struct's round-trip.
    public static func decoded(from raw: String?) -> KeyboardShortcut? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
    }
}
