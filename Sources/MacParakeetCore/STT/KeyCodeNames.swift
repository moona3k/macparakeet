import Foundation

/// Static lookup table for CGKeyCode → human-readable names.
/// Covers function keys, navigation, arrows, and common special keys.
public enum KeyCodeNames {
    /// Human-readable display name and compact symbol for a given key code.
    /// Returns `("Key <code>", "Key <code>")` for unknown codes.
    public static func name(for keyCode: UInt16) -> (displayName: String, shortSymbol: String) {
        if let entry = table[keyCode] {
            return entry
        }
        let fallback = "Key \(keyCode)"
        return (fallback, fallback)
    }

    // MARK: - Lookup Table

    private static let table: [UInt16: (displayName: String, shortSymbol: String)] = [
        // Function keys
        122: ("F1", "F1"),
        120: ("F2", "F2"),
        99:  ("F3", "F3"),
        118: ("F4", "F4"),
        96:  ("F5", "F5"),
        97:  ("F6", "F6"),
        98:  ("F7", "F7"),
        100: ("F8", "F8"),
        101: ("F9", "F9"),
        109: ("F10", "F10"),
        103: ("F11", "F11"),
        111: ("F12", "F12"),
        105: ("F13", "F13"),
        107: ("F14", "F14"),
        113: ("F15", "F15"),
        106: ("F16", "F16"),
        64:  ("F17", "F17"),
        79:  ("F18", "F18"),
        80:  ("F19", "F19"),
        90:  ("F20", "F20"),

        // Navigation
        115: ("Home", "Home"),
        119: ("End", "End"),
        116: ("Page Up", "PgUp"),
        121: ("Page Down", "PgDn"),
        117: ("Forward Delete", "⌦"),

        // Arrows
        126: ("Up Arrow", "↑"),
        125: ("Down Arrow", "↓"),
        123: ("Left Arrow", "←"),
        124: ("Right Arrow", "→"),

        // Special keys
        48:  ("Tab", "⇥"),
        49:  ("Space", "Space"),
        36:  ("Return", "↩"),
        53:  ("Escape", "Esc"),
        57:  ("Caps Lock", "⇪"),
    ]
}
