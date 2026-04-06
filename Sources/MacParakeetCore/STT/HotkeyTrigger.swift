import Foundation

/// A hotkey trigger that supports both modifier keys and regular key codes.
/// Replaces the old `TriggerKey` enum with an extensible struct.
///
/// Only canonical identity (kind + modifierName/keyCode/modifierKeyCode) is persisted.
/// Display names are derived at runtime from `KeyCodeNames` / modifier lookup.
public struct HotkeyTrigger: Sendable {

    // MARK: - Kind

    public enum Kind: String, Codable, Sendable {
        case modifier
        case keyCode
        case chord
    }

    // MARK: - Validation

    public enum ValidationResult: Equatable, Sendable {
        case allowed
        case warned(String)
        case blocked(String)
    }

    // MARK: - Stored Properties (canonical identity only)

    public let kind: Kind
    /// Raw modifier name ("fn", "control", etc.) for `.modifier` kind. Nil for `.keyCode` and `.chord`.
    public let modifierName: String?
    /// CGKeyCode for `.keyCode` and `.chord` kinds. Nil for `.modifier`.
    public let keyCode: UInt16?
    /// Modifier names for `.chord` kind (e.g. `["command"]`, `["command","shift"]`). Nil for other kinds.
    public let chordModifiers: [String]?
    /// Physical keyCode for side-specific modifier triggers (e.g. 61 for right-option, 58 for left-option).
    /// When nil, either side of the modifier triggers the hotkey (backwards-compatible default).
    public let modifierKeyCode: UInt16?

    // MARK: - Computed Properties (derived at runtime)

    /// Human-readable name for UI display (e.g., "Fn", "End", "F13", "Command+9", "Right Option").
    public var displayName: String {
        switch kind {
        case .modifier:
            if let mkc = modifierKeyCode, let info = Self.modifierKeyCodeInfo[mkc],
               let base = Self.modifierDisplayNames[info.modifier] {
                return "\(info.side) \(base.displayName)"
            }
            return Self.modifierDisplayNames[modifierName ?? ""]?.displayName ?? modifierName ?? "Unknown"
        case .keyCode:
            guard let code = keyCode else { return "Unknown" }
            return KeyCodeNames.name(for: code).displayName
        case .chord:
            guard let code = keyCode else { return "Unknown" }
            let modifierNames = Self.sortedModifierDisplayNames(chordModifiers)
            let keyPart = KeyCodeNames.name(for: code).displayName
            if modifierNames.isEmpty { return keyPart }
            return modifierNames.joined(separator: "+") + "+\(keyPart)"
        }
    }

    /// Short symbol for compact display (e.g., "fn", "⌃", "End", "F13", "⌘9", "R⌥").
    public var shortSymbol: String {
        switch kind {
        case .modifier:
            if let mkc = modifierKeyCode, let info = Self.modifierKeyCodeInfo[mkc],
               let base = Self.modifierDisplayNames[info.modifier] {
                return "\(info.sideShort)\(base.shortSymbol)"
            }
            return Self.modifierDisplayNames[modifierName ?? ""]?.shortSymbol ?? modifierName ?? "?"
        case .keyCode:
            guard let code = keyCode else { return "?" }
            return KeyCodeNames.name(for: code).shortSymbol
        case .chord:
            guard let code = keyCode else { return "?" }
            let modifierPart = Self.sortedModifierSymbols(chordModifiers)
            let keyPart = KeyCodeNames.name(for: code).shortSymbol
            if modifierPart.isEmpty { return keyPart }
            return "\(modifierPart)\(keyPart)"
        }
    }

    /// Modifier name → (displayName, shortSymbol)
    private static let modifierDisplayNames: [String: (displayName: String, shortSymbol: String)] = [
        "fn": ("Fn", "fn"),
        "control": ("Control", "⌃"),
        "option": ("Option", "⌥"),
        "shift": ("Shift", "⇧"),
        "command": ("Command", "⌘"),
    ]

    /// Physical keyCode → (side label, short prefix, generic modifier name) for side-specific display.
    private static let modifierKeyCodeInfo: [UInt16: (side: String, sideShort: String, modifier: String)] = [
        56: ("Left", "L", "shift"),
        60: ("Right", "R", "shift"),
        59: ("Left", "L", "control"),
        62: ("Right", "R", "control"),
        58: ("Left", "L", "option"),
        61: ("Right", "R", "option"),
        55: ("Left", "L", "command"),
        54: ("Right", "R", "command"),
    ]

    /// Standard macOS modifier ordering: ⌃ ⌥ ⇧ ⌘
    private static let modifierOrder: [String] = ["control", "option", "shift", "command"]

    /// Returns sorted display names for chord modifiers (e.g. ["Control", "Command"]).
    private static func sortedModifierDisplayNames(_ modifiers: [String]?) -> [String] {
        guard let modifiers else { return [] }
        return modifierOrder.filter { modifiers.contains($0) }
            .compactMap { modifierDisplayNames[$0]?.displayName }
    }

    /// Returns concatenated short symbols for chord modifiers (e.g. "⌃⌘").
    private static func sortedModifierSymbols(_ modifiers: [String]?) -> String {
        guard let modifiers else { return "" }
        return modifierOrder.filter { modifiers.contains($0) }
            .compactMap { modifierDisplayNames[$0]?.shortSymbol }
            .joined()
    }

    // CGEventFlags raw values (avoids CoreGraphics import in MacParakeetCore)
    private static let maskCommand: UInt64   = 0x00100000  // NX_COMMANDMASK
    private static let maskShift: UInt64     = 0x00020000  // NX_SHIFTMASK
    private static let maskControl: UInt64   = 0x00040000  // NX_CONTROLMASK
    private static let maskAlternate: UInt64 = 0x00080000  // NX_ALTERNATEMASK

    /// All 4 relevant modifier bits OR'd together.
    public static let relevantModifierBits: UInt64 = maskCommand | maskShift | maskControl | maskAlternate

    /// CGEventFlags raw value for chord modifiers, computed at runtime.
    /// Maps modifier names to their CGEventFlags mask bits and OR's them together.
    public var chordEventFlags: UInt64 {
        guard let modifiers = chordModifiers else { return 0 }
        var flags: UInt64 = 0
        for name in modifiers {
            switch name {
            case "command": flags |= Self.maskCommand
            case "shift": flags |= Self.maskShift
            case "control": flags |= Self.maskControl
            case "option": flags |= Self.maskAlternate
            default: break
            }
        }
        return flags
    }

    // MARK: - Init

    public init(kind: Kind, modifierName: String?, keyCode: UInt16?, chordModifiers: [String]? = nil, modifierKeyCode: UInt16? = nil) {
        self.kind = kind
        self.modifierName = modifierName
        self.keyCode = keyCode
        self.chordModifiers = chordModifiers
        self.modifierKeyCode = modifierKeyCode
    }

    // MARK: - Modifier Presets

    public static let fn = HotkeyTrigger(kind: .modifier, modifierName: "fn", keyCode: nil)
    public static let control = HotkeyTrigger(kind: .modifier, modifierName: "control", keyCode: nil)
    public static let option = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil)
    public static let shift = HotkeyTrigger(kind: .modifier, modifierName: "shift", keyCode: nil)
    public static let command = HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil)

    /// All modifier presets for UI iteration.
    public static let modifierPresets: [HotkeyTrigger] = [.fn, .control, .option, .shift, .command]

    // MARK: - Factory

    /// Create a trigger from a CGKeyCode.
    public static func fromKeyCode(_ code: UInt16) -> HotkeyTrigger {
        HotkeyTrigger(kind: .keyCode, modifierName: nil, keyCode: code)
    }

    /// Create a chord trigger from modifier names and a CGKeyCode (e.g., `chord(modifiers: ["command"], keyCode: 25)` for Cmd+9).
    /// Modifier order is normalized to ⌃⌥⇧⌘ regardless of input order.
    public static func chord(modifiers: [String], keyCode: UInt16) -> HotkeyTrigger {
        let sorted = modifierOrder.filter { modifiers.contains($0) }
        return HotkeyTrigger(kind: .chord, modifierName: nil, keyCode: keyCode, chordModifiers: sorted)
    }

    // MARK: - Validation

    public var validation: ValidationResult {
        switch kind {
        case .modifier:
            return .allowed
        case .keyCode:
            return Self.validateKeyCode(keyCode)
        case .chord:
            return Self.validateChord(keyCode: keyCode, modifiers: chordModifiers)
        }
    }

    private static func validateKeyCode(_ keyCode: UInt16?) -> ValidationResult {
        guard let code = keyCode else { return .allowed }

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

        // Function keys, nav keys, and F13+ are safe. Warn everything else.
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

    private static func validateChord(keyCode: UInt16?, modifiers: [String]?) -> ValidationResult {
        guard let code = keyCode else { return .allowed }

        // Escape blocked even in chords
        if code == 53 {
            return .blocked("Escape is reserved for canceling dictation.")
        }

        let hasCommand = modifiers?.contains("command") ?? false

        // Cmd+Tab (keyCode 48) — system shortcut
        if code == 48 && hasCommand {
            return .warned("May not work \u{2014} system shortcut.")
        }

        // Cmd+Space (keyCode 49) — system shortcut
        if code == 49 && hasCommand {
            return .warned("May not work \u{2014} system shortcut.")
        }

        // Common destructive Cmd shortcuts — Cmd+Q (quit), Cmd+W (close window),
        // Cmd+H (hide), Cmd+M (minimize)
        let destructiveCmdKeys: Set<UInt16> = [
            12,  // Q
            13,  // W
            4,   // H
            46,  // M
        ]
        if hasCommand && destructiveCmdKeys.contains(code) {
            return .warned("Conflicts with a common system shortcut.")
        }

        return .allowed
    }

    // MARK: - Persistence

    public static let defaultsKey = "hotkeyTrigger"
    public static let meetingDefaultsKey = "meetingHotkeyTrigger"

    /// Legacy modifier names from the old TriggerKey enum.
    private static let legacyModifiers: [String: HotkeyTrigger] = [
        "fn": .fn, "control": .control, "option": .option,
        "shift": .shift, "command": .command,
        "left_shift": HotkeyTrigger(kind: .modifier, modifierName: "shift", keyCode: nil, modifierKeyCode: 56),
        "right_shift": HotkeyTrigger(kind: .modifier, modifierName: "shift", keyCode: nil, modifierKeyCode: 60),
        "left_control": HotkeyTrigger(kind: .modifier, modifierName: "control", keyCode: nil, modifierKeyCode: 59),
        "right_control": HotkeyTrigger(kind: .modifier, modifierName: "control", keyCode: nil, modifierKeyCode: 62),
        "left_option": HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 58),
        "right_option": HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61),
        "left_command": HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 55),
        "right_command": HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 54),
    ]

    /// Resolve the configured trigger from the provided defaults store.
    /// Tries JSON decode first, falls back to legacy string, defaults to `.fn`.
    public static func current(
        defaults: UserDefaults = .standard,
        defaultsKey: String = defaultsKey,
        fallback: HotkeyTrigger = .fn
    ) -> HotkeyTrigger {
        guard let stored = defaults.object(forKey: defaultsKey) else {
            return fallback
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

        return fallback
    }

    /// Convenience accessor using standard user defaults.
    public static var current: HotkeyTrigger {
        current(defaults: .standard, defaultsKey: defaultsKey)
    }

    /// Persist this trigger to the given defaults store as JSON.
    public func save(
        to defaults: UserDefaults = .standard,
        defaultsKey: String = Self.defaultsKey
    ) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - Equatable (canonical identity only)

extension HotkeyTrigger: Equatable {
    public static func == (lhs: HotkeyTrigger, rhs: HotkeyTrigger) -> Bool {
        lhs.kind == rhs.kind && lhs.modifierName == rhs.modifierName
            && lhs.keyCode == rhs.keyCode && lhs.chordModifiers == rhs.chordModifiers
            && lhs.modifierKeyCode == rhs.modifierKeyCode
    }
}

// MARK: - Codable (canonical identity only — no displayName/shortSymbol)

extension HotkeyTrigger: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, modifierName, keyCode, chordModifiers, modifierKeyCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        modifierName = try container.decodeIfPresent(String.self, forKey: .modifierName)
        keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
        chordModifiers = try container.decodeIfPresent([String].self, forKey: .chordModifiers)
        modifierKeyCode = try container.decodeIfPresent(UInt16.self, forKey: .modifierKeyCode)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(modifierName, forKey: .modifierName)
        try container.encodeIfPresent(keyCode, forKey: .keyCode)
        try container.encodeIfPresent(chordModifiers, forKey: .chordModifiers)
        try container.encodeIfPresent(modifierKeyCode, forKey: .modifierKeyCode)
    }
}
