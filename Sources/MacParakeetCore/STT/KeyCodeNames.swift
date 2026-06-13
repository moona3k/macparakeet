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

    /// Key codes for which macOS sets the `.function` NSEvent modifier flag /
    /// `NX_SECONDARYFNMASK` on the key's own events even when the physical
    /// Fn/globe key is not held: F1–F20, arrows, and the navigation cluster.
    /// Used to distinguish a genuinely held Fn modifier from this phantom bit.
    public static func isFunctionFamilyKeyCode(_ keyCode: UInt16) -> Bool {
        functionFamilyKeyCodes.contains(keyCode)
    }

    private static let functionFamilyKeyCodes: Set<UInt16> = [
        // F1–F20 (matches the function-key rows of `table` below)
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90,
        // Arrows
        123, 124, 125, 126,
        // Navigation: Home, Page Up, Forward Delete, End, Page Down
        115, 116, 117, 119, 121,
        // Help/Insert — sets the function flag too; intentionally absent from
        // the display-name table (falls back to "Key 114").
        114,
    ]

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
        51:  ("Delete", "⌫"),
        76:  ("Enter", "⌅"),       // Numpad enter

        // Letters (QWERTY layout)
        0:   ("A", "A"),
        11:  ("B", "B"),
        8:   ("C", "C"),
        2:   ("D", "D"),
        14:  ("E", "E"),
        3:   ("F", "F"),
        5:   ("G", "G"),
        4:   ("H", "H"),
        34:  ("I", "I"),
        38:  ("J", "J"),
        40:  ("K", "K"),
        37:  ("L", "L"),
        46:  ("M", "M"),
        45:  ("N", "N"),
        31:  ("O", "O"),
        35:  ("P", "P"),
        12:  ("Q", "Q"),
        15:  ("R", "R"),
        1:   ("S", "S"),
        17:  ("T", "T"),
        32:  ("U", "U"),
        9:   ("V", "V"),
        13:  ("W", "W"),
        7:   ("X", "X"),
        16:  ("Y", "Y"),
        6:   ("Z", "Z"),

        // Number row
        18:  ("1", "1"),
        19:  ("2", "2"),
        20:  ("3", "3"),
        21:  ("4", "4"),
        23:  ("5", "5"),
        22:  ("6", "6"),
        26:  ("7", "7"),
        28:  ("8", "8"),
        25:  ("9", "9"),
        29:  ("0", "0"),

        // Punctuation / symbols
        27:  ("-", "-"),
        24:  ("=", "="),
        33:  ("[", "["),
        30:  ("]", "]"),
        42:  ("\\", "\\"),
        41:  (";", ";"),
        39:  ("'", "'"),
        43:  (",", ","),
        47:  (".", "."),
        44:  ("/", "/"),
        50:  ("`", "`"),
    ]
}
