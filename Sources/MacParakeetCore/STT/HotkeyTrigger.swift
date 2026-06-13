import Foundation

/// A hotkey trigger that supports both modifier keys and regular key codes.
/// Replaces the old `TriggerKey` enum with an extensible struct.
///
/// Only canonical identity (kind + modifierName/keyCode/modifierKeyCode) is persisted.
/// Display names are derived at runtime from `KeyCodeNames` / modifier lookup.
public struct HotkeyTrigger: Sendable {

    // MARK: - Kind

    public enum Kind: String, Codable, Sendable {
        case disabled
        case modifier
        case keyCode
        case chord
        case modifierChord
    }

    public struct ModifierComponent: Codable, Equatable, Sendable {
        public let modifierName: String
        public let keyCode: UInt16?

        public init(modifierName: String, keyCode: UInt16? = nil) {
            self.modifierName = modifierName
            self.keyCode = keyCode
        }
    }

    // MARK: - Validation

    public enum ValidationResult: Equatable, Sendable {
        case allowed
        case warned(String)
        case blocked(String)
    }

    public enum ConflictMode: Equatable, Sendable {
        case exclusive
        case bareModifierDictation
    }

    // MARK: - Stored Properties (canonical identity only)

    public let kind: Kind
    /// Raw modifier name ("fn", "control", etc.) for `.modifier` kind. Nil for key and chord kinds.
    public let modifierName: String?
    /// CGKeyCode for `.keyCode` and `.chord` kinds. Nil for modifier-only kinds.
    public let keyCode: UInt16?
    /// Modifier names for `.chord` kind (e.g. `["command"]`, `["command","shift"]`). Nil for other kinds.
    public let chordModifiers: [String]?
    /// Physical keyCode for side-specific modifier triggers (e.g. 61 for right-option, 58 for left-option).
    /// When nil, either side of the modifier triggers the hotkey (backwards-compatible default).
    public let modifierKeyCode: UInt16?
    /// Modifier components for `.modifierChord` kind. Nil for other kinds.
    public let modifierChordComponents: [ModifierComponent]?

    // MARK: - Computed Properties (derived at runtime)

    /// Whether this trigger is disabled (no hotkey assigned).
    public var isDisabled: Bool { kind == .disabled }

    /// Human-readable name for UI display (e.g., "Fn", "End", "F13", "Command+9", "Right Option").
    public var displayName: String {
        switch kind {
        case .disabled:
            return "Disabled"
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
        case .modifierChord:
            let modifierNames = Self.sortedModifierComponentDisplayNames(modifierChordComponents)
            if modifierNames.isEmpty { return "Unknown" }
            return modifierNames.joined(separator: "+")
        }
    }

    /// Presentation-ready label for Settings rows and reset menus.
    ///
    /// Combines `shortSymbol` and `displayName` only when they add information.
    /// Avoids duplicate output for keyCodes (e.g. "1 1") and the Fn modifier
    /// (whose short symbol "fn" and display name "Fn" are visually redundant —
    /// modern Macs use the 🌐 globe glyph instead).
    public var formattedLabel: String {
        switch kind {
        case .disabled:
            return "Disabled"
        case .modifier:
            // The Fn key has no canonical glyph on legacy keyboards; modern
            // Macs use the globe. Show it instead of duplicating "fn Fn".
            if modifierName == "fn" {
                return "🌐 Fn"
            }
            let glyph = shortSymbol
            let name = displayName
            if glyph == name { return name }
            return "\(glyph) \(name)"
        case .keyCode, .chord, .modifierChord:
            // Glyph form matches macOS menu/keyboard conventions
            // (e.g. "↑", "F13", "⇧⌘N").
            return shortSymbol
        }
    }

    /// Short symbol for compact display (e.g., "fn", "⌃", "End", "F13", "⌘9", "R⌥").
    public var shortSymbol: String {
        switch kind {
        case .disabled:
            return "—"
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
            let modifierSymbols = Self.sortedModifierSymbols(chordModifiers)
            let keyPart = KeyCodeNames.name(for: code).shortSymbol
            if modifierSymbols.isEmpty { return keyPart }
            if modifierSymbols.contains("fn") {
                return (modifierSymbols + [keyPart]).joined(separator: "+")
            }
            return "\(modifierSymbols.joined())\(keyPart)"
        case .modifierChord:
            let modifierPart = Self.sortedModifierComponentSymbols(modifierChordComponents)
            return modifierPart.isEmpty ? "?" : modifierPart
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

    public static let canonicalFnKeyCode: UInt16 = 63
    public static let fnKeyCodes: Set<UInt16> = [canonicalFnKeyCode, 179]
    public static let sideSpecificModifierKeyCodes: [UInt16] = [59, 62, 58, 61, 56, 60, 55, 54]

    private static let modifierOppositeKeyCodes: [UInt16: UInt16] = [
        56: 60,
        60: 56,
        59: 62,
        62: 59,
        58: 61,
        61: 58,
        55: 54,
        54: 55,
    ]

    /// Standard macOS modifier ordering for modifier-only triggers: ⌃ ⌥ ⇧ ⌘.
    private static let modifierOrder: [String] = ["control", "option", "shift", "command"]
    private static let keyChordModifierOrder: [String] = ["fn", "control", "option", "shift", "command"]

    /// Returns sorted display names for chord modifiers (e.g. ["Control", "Command"]).
    private static func sortedModifierDisplayNames(_ modifiers: [String]?) -> [String] {
        guard let modifiers else { return [] }
        return keyChordModifierOrder.filter { modifiers.contains($0) }
            .compactMap { modifierDisplayNames[$0]?.displayName }
    }

    /// Returns concatenated short symbols for chord modifiers (e.g. "⌃⌘").
    private static func sortedModifierSymbols(_ modifiers: [String]?) -> [String] {
        guard let modifiers else { return [] }
        return keyChordModifierOrder.filter { modifiers.contains($0) }
            .compactMap { modifierDisplayNames[$0]?.shortSymbol }
    }

    private static func sortedModifierComponentDisplayNames(_ components: [ModifierComponent]?) -> [String] {
        (components ?? []).compactMap { component in
            if let keyCode = component.keyCode,
               let info = modifierKeyCodeInfo[keyCode],
               let base = modifierDisplayNames[info.modifier] {
                return "\(info.side) \(base.displayName)"
            }
            return modifierDisplayNames[component.modifierName]?.displayName
        }
    }

    private static func sortedModifierComponentSymbols(_ components: [ModifierComponent]?) -> String {
        (components ?? []).compactMap { component in
            if let keyCode = component.keyCode,
               let info = modifierKeyCodeInfo[keyCode],
               let base = modifierDisplayNames[info.modifier] {
                return "\(info.sideShort)\(base.shortSymbol)"
            }
            return modifierDisplayNames[component.modifierName]?.shortSymbol
        }
        .joined()
    }

    // CGEventFlags raw values (avoids CoreGraphics import in MacParakeetCore)
    private static let maskCommand: UInt64   = 0x00100000  // NX_COMMANDMASK
    private static let maskShift: UInt64     = 0x00020000  // NX_SHIFTMASK
    private static let maskControl: UInt64   = 0x00040000  // NX_CONTROLMASK
    private static let maskAlternate: UInt64 = 0x00080000  // NX_ALTERNATEMASK
    private static let maskSecondaryFn: UInt64 = 0x00800000 // NX_SECONDARYFNMASK

    /// All relevant modifier bits OR'd together.
    public static let relevantModifierBits: UInt64 = maskCommand | maskShift | maskControl | maskAlternate | maskSecondaryFn

    /// CGEventFlags raw value for chord modifiers, computed at runtime.
    /// Maps modifier names to their CGEventFlags mask bits and OR's them together.
    public var chordEventFlags: UInt64 {
        guard let modifiers = chordModifiers else { return 0 }
        return Self.eventFlags(for: modifiers)
    }

    /// Event-flag bits that exact-match chord consumers must ignore.
    /// Hardware function-family keys (F-keys, arrows, nav cluster) carry
    /// NX_SECONDARYFNMASK on their own events while synthetic events
    /// (Karabiner/QMK) often don't. For chords on those keys that don't
    /// themselves require fn, the bit is noise, not a held modifier.
    public var ignoredChordEventFlags: UInt64 {
        guard kind == .chord,
              let code = keyCode,
              KeyCodeNames.isFunctionFamilyKeyCode(code),
              !(chordModifiers?.contains("fn") ?? false) else {
            return 0
        }
        return Self.maskSecondaryFn
    }

    public var modifierChordEventFlags: UInt64 {
        Self.eventFlags(for: normalizedModifierChordComponents.map(\.modifierName))
    }

    public var normalizedModifierChordComponents: [ModifierComponent] {
        modifierChordComponents ?? []
    }

    public var modifierChordKeyCodes: [UInt16] {
        normalizedModifierChordComponents.compactMap(\.keyCode)
    }

    public func modifierChordRequiredComponentsArePressed(
        flags: UInt64,
        sideSpecificPressed: (UInt16) -> Bool
    ) -> Bool {
        guard kind == .modifierChord else { return false }
        let components = normalizedModifierChordComponents
        guard components.count >= 2 else { return false }
        guard flags & modifierChordEventFlags == modifierChordEventFlags else { return false }
        for component in components {
            if let keyCode = component.keyCode, !sideSpecificPressed(keyCode) {
                return false
            }
        }
        return true
    }

    public func modifierChordMatches(
        flags: UInt64,
        sideSpecificPressed: (UInt16) -> Bool
    ) -> Bool {
        guard modifierChordRequiredComponentsArePressed(
            flags: flags,
            sideSpecificPressed: sideSpecificPressed
        ) else {
            return false
        }
        guard flags & Self.relevantModifierBits == modifierChordEventFlags else { return false }

        let requiredKeyCodes = Set(modifierChordKeyCodes)
        for keyCode in requiredKeyCodes {
            guard let opposite = Self.oppositeModifierKeyCode(for: keyCode),
                  !requiredKeyCodes.contains(opposite) else {
                continue
            }
            if sideSpecificPressed(opposite) {
                return false
            }
        }
        return true
    }

    private static func eventFlags(for modifiers: [String]) -> UInt64 {
        var flags: UInt64 = 0
        for name in modifiers {
            switch name {
            case "fn": flags |= Self.maskSecondaryFn
            case "command": flags |= Self.maskCommand
            case "shift": flags |= Self.maskShift
            case "control": flags |= Self.maskControl
            case "option": flags |= Self.maskAlternate
            default: break
            }
        }
        return flags
    }

    public static func modifierName(forKeyCode keyCode: UInt16) -> String? {
        if isFnKeyCode(keyCode) { return "fn" }
        return modifierKeyCodeInfo[keyCode]?.modifier
    }

    public static func isFnKeyCode(_ keyCode: UInt16) -> Bool {
        fnKeyCodes.contains(keyCode)
    }

    public static func modifierComponent(forKeyCode keyCode: UInt16) -> ModifierComponent? {
        guard !isFnKeyCode(keyCode),
              let name = modifierName(forKeyCode: keyCode) else { return nil }
        return ModifierComponent(modifierName: name, keyCode: keyCode)
    }

    public static func oppositeModifierKeyCode(for keyCode: UInt16) -> UInt16? {
        modifierOppositeKeyCodes[keyCode]
    }

    // MARK: - Init

    public init(
        kind: Kind,
        modifierName: String?,
        keyCode: UInt16?,
        chordModifiers: [String]? = nil,
        modifierKeyCode: UInt16? = nil,
        modifierChordComponents: [ModifierComponent]? = nil
    ) {
        self.kind = kind
        self.modifierName = modifierName
        self.keyCode = keyCode
        self.chordModifiers = chordModifiers
        self.modifierKeyCode = modifierKeyCode
        self.modifierChordComponents = modifierChordComponents.map { Self.normalizedModifierComponents($0) }
    }

    // MARK: - Disabled Preset

    public static let disabled = HotkeyTrigger(kind: .disabled, modifierName: nil, keyCode: nil)

    // MARK: - Modifier Presets

    public static let fn = HotkeyTrigger(kind: .modifier, modifierName: "fn", keyCode: nil)
    public static let control = HotkeyTrigger(kind: .modifier, modifierName: "control", keyCode: nil)
    public static let option = HotkeyTrigger(kind: .modifier, modifierName: "option", keyCode: nil)
    public static let shift = HotkeyTrigger(kind: .modifier, modifierName: "shift", keyCode: nil)
    public static let command = HotkeyTrigger(kind: .modifier, modifierName: "command", keyCode: nil)

    /// All modifier presets for UI iteration.
    public static let modifierPresets: [HotkeyTrigger] = [.fn, .control, .option, .shift, .command]

    // MARK: - Default Triggers

    public static let fnSpace: HotkeyTrigger = .chord(modifiers: ["fn"], keyCode: 49)
    public static let defaultDictation: HotkeyTrigger = .fn
    public static let defaultPushToTalk: HotkeyTrigger = .fn
    public static let defaultMeetingRecording: HotkeyTrigger = .chord(modifiers: ["command", "shift"], keyCode: 46)

    public static func isDefaultDictationGesturePreset(
        handsFree: HotkeyTrigger,
        pushToTalk: HotkeyTrigger
    ) -> Bool {
        handsFree == .defaultDictation && pushToTalk == .defaultPushToTalk
    }

    public static func isSharedDictationGesture(
        handsFree: HotkeyTrigger,
        pushToTalk: HotkeyTrigger
    ) -> Bool {
        !handsFree.isDisabled && !pushToTalk.isDisabled && handsFree == pushToTalk
    }

    // MARK: - Factory

    /// Create a trigger from a CGKeyCode.
    public static func fromKeyCode(_ code: UInt16) -> HotkeyTrigger {
        HotkeyTrigger(kind: .keyCode, modifierName: nil, keyCode: code)
    }

    /// Create a chord trigger from modifier names and a CGKeyCode (e.g., `chord(modifiers: ["command"], keyCode: 25)` for Cmd+9).
    /// Modifier order is normalized to fn⌃⌥⇧⌘ regardless of input order.
    public static func chord(modifiers: [String], keyCode: UInt16) -> HotkeyTrigger {
        let sorted = keyChordModifierOrder.filter { modifiers.contains($0) }
        return HotkeyTrigger(kind: .chord, modifierName: nil, keyCode: keyCode, chordModifiers: sorted)
    }

    public static func modifierChord(modifiers: [String]) -> HotkeyTrigger {
        modifierChord(
            components: modifiers.map { ModifierComponent(modifierName: $0) }
        )
    }

    public static func modifierChord(components: [ModifierComponent]) -> HotkeyTrigger {
        HotkeyTrigger(
            kind: .modifierChord,
            modifierName: nil,
            keyCode: nil,
            modifierChordComponents: normalizedModifierComponents(components)
        )
    }

    private static func normalizedModifierComponents(_ components: [ModifierComponent]) -> [ModifierComponent] {
        var seen: Set<String> = []
        let canonical = components.compactMap { component -> ModifierComponent? in
            if let keyCode = component.keyCode,
               let modifierName = modifierKeyCodeInfo[keyCode]?.modifier {
                return ModifierComponent(modifierName: modifierName, keyCode: keyCode)
            }
            guard modifierOrder.contains(component.modifierName) else { return nil }
            return ModifierComponent(modifierName: component.modifierName)
        }
        .filter { component in
            let key = "\(component.modifierName):\(component.keyCode.map(String.init) ?? "*")"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        return canonical.sorted { lhs, rhs in
            let lhsOrder = modifierOrder.firstIndex(of: lhs.modifierName) ?? Int.max
            let rhsOrder = modifierOrder.firstIndex(of: rhs.modifierName) ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return (lhs.keyCode ?? 0) < (rhs.keyCode ?? 0)
        }
    }

    // MARK: - Validation

    public var validation: ValidationResult {
        switch kind {
        case .disabled:
            return .allowed
        case .modifier:
            return .allowed
        case .keyCode:
            return Self.validateKeyCode(keyCode)
        case .chord:
            return Self.validateChord(keyCode: keyCode, modifiers: chordModifiers)
        case .modifierChord:
            return Self.validateModifierChord(modifierChordComponents)
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
            // Only bare Cmd+M maps to the system Minimize command; multi-modifier
            // variants such as Cmd+Shift+M remain valid app-owned defaults.
            if code == 46 && Set(modifiers ?? []) != ["command"] {
                return .allowed
            }
            return .warned("Conflicts with a common system shortcut.")
        }

        return .allowed
    }

    private static func validateModifierChord(_ components: [ModifierComponent]?) -> ValidationResult {
        guard (components ?? []).count >= 2 else {
            return .blocked("Press at least two modifier keys.")
        }
        return .allowed
    }

    // MARK: - Conflict Detection

    public func overlaps(with other: HotkeyTrigger) -> Bool {
        guard !isDisabled, !other.isDisabled else { return false }
        if self == other { return true }

        switch (kind, other.kind) {
        case (.modifier, .modifier):
            return Self.modifierRequirement(for: self).flatMap { lhs in
                Self.modifierRequirement(for: other).map { Self.modifierRequirementsAreCompatible(lhs, $0) }
            } ?? false
        case (.modifier, .modifierChord):
            return Self.modifierRequirement(for: self).flatMap { lhs in
                Self.modifierRequirements(forModifierChord: other).contains { rhs in
                    Self.modifierRequirementsAreCompatible(lhs, rhs)
                }
            } ?? false
        case (.modifierChord, .modifier):
            return other.overlaps(with: self)
        case (.modifier, .chord):
            return Self.modifierRequirement(for: self).flatMap { lhs in
                Self.modifierRequirements(forChord: other).contains { rhs in
                    Self.modifierRequirementsAreCompatible(lhs, rhs)
                }
            } ?? false
        case (.chord, .modifier):
            return other.overlaps(with: self)
        case (.modifierChord, .modifierChord):
            let lhs = Self.modifierRequirements(forModifierChord: self)
            let rhs = Self.modifierRequirements(forModifierChord: other)
            guard lhs.count >= 2, rhs.count >= 2 else { return false }
            return Self.requirements(lhs, canBeSatisfiedBy: rhs)
                || Self.requirements(rhs, canBeSatisfiedBy: lhs)
        case (.modifierChord, .chord):
            let lhs = Self.modifierRequirements(forModifierChord: self)
            let rhs = Self.modifierRequirements(forChord: other)
            guard lhs.count >= 2, !rhs.isEmpty else { return false }
            return Self.requirements(lhs, canBeSatisfiedBy: rhs)
        case (.chord, .modifierChord):
            return other.overlaps(with: self)
        case (.keyCode, .keyCode):
            return keyCode != nil && keyCode == other.keyCode
        case (.keyCode, .chord):
            return keyCode != nil && keyCode == other.keyCode
        case (.chord, .keyCode):
            return other.overlaps(with: self)
        case (.chord, .chord):
            guard keyCode != nil, keyCode == other.keyCode else { return false }
            let lhs = Self.modifierRequirements(forChord: self)
            let rhs = Self.modifierRequirements(forChord: other)
            return Self.requirements(lhs, canBeSatisfiedBy: rhs)
                || Self.requirements(rhs, canBeSatisfiedBy: lhs)
        default:
            return false
        }
    }

    public func conflicts(
        with other: HotkeyTrigger,
        selfMode: ConflictMode = .exclusive,
        otherMode: ConflictMode = .exclusive
    ) -> Bool {
        guard overlaps(with: other) else { return false }
        if selfMode == .bareModifierDictation,
           Self.bareModifierDictationCanShare(self, with: other) {
            return false
        }
        if otherMode == .bareModifierDictation,
           Self.bareModifierDictationCanShare(other, with: self) {
            return false
        }
        return true
    }

    private static func bareModifierDictationCanShare(
        _ dictationTrigger: HotkeyTrigger,
        with other: HotkeyTrigger
    ) -> Bool {
        guard dictationTrigger.kind == .modifier,
              let lhs = modifierRequirement(for: dictationTrigger) else {
            return false
        }

        switch other.kind {
        case .chord:
            return modifierRequirements(forChord: other).contains {
                modifierRequirementsAreCompatible(lhs, $0)
            }
        case .modifierChord:
            return modifierRequirements(forModifierChord: other).contains {
                modifierRequirementsAreCompatible(lhs, $0)
            }
        default:
            return false
        }
    }

    private static func modifierRequirement(for trigger: HotkeyTrigger) -> ModifierComponent? {
        guard trigger.kind == .modifier, let name = trigger.modifierName else { return nil }
        if let keyCode = trigger.modifierKeyCode,
           let component = modifierComponent(forKeyCode: keyCode) {
            return component
        }
        guard name != "fn", modifierOrder.contains(name) else { return nil }
        return ModifierComponent(modifierName: name)
    }

    private static func modifierRequirements(forChord trigger: HotkeyTrigger) -> [ModifierComponent] {
        (trigger.chordModifiers ?? []).map { ModifierComponent(modifierName: $0) }
    }

    private static func modifierRequirements(forModifierChord trigger: HotkeyTrigger) -> [ModifierComponent] {
        trigger.normalizedModifierChordComponents
    }

    private static func requirements(
        _ requirements: [ModifierComponent],
        canBeSatisfiedBy candidates: [ModifierComponent]
    ) -> Bool {
        requirements.allSatisfy { requirement in
            candidates.contains { candidate in
                modifierRequirementsAreCompatible(requirement, candidate)
            }
        }
    }

    private static func modifierRequirementsAreCompatible(
        _ lhs: ModifierComponent,
        _ rhs: ModifierComponent
    ) -> Bool {
        guard lhs.modifierName == rhs.modifierName else { return false }
        if let lhsKeyCode = lhs.keyCode, let rhsKeyCode = rhs.keyCode {
            return lhsKeyCode == rhsKeyCode
        }
        return true
    }

    // MARK: - Persistence

    public static let defaultsKey = "hotkeyTrigger"
    public static let pushToTalkDefaultsKey = "pushToTalkHotkeyTrigger"
    public static let meetingDefaultsKey = "meetingHotkeyTrigger"
    public static let fileTranscriptionDefaultsKey = "fileTranscriptionHotkeyTrigger"
    public static let youtubeTranscriptionDefaultsKey = "youtubeTranscriptionHotkeyTrigger"

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
    /// Tries JSON decode first, falls back to legacy string, defaults to the hands-free shortcut.
    public static func current(
        defaults: UserDefaults = .standard,
        defaultsKey: String = defaultsKey,
        fallback: HotkeyTrigger = .defaultDictation
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

// MARK: - Telemetry payload

extension HotkeyTrigger {
    /// Maps `kind` to its telemetry counterpart. Kept inline here so callers
    /// don't have to translate by hand at every emit site.
    ///
    /// We deliberately stop at the kind boundary — `docs/telemetry.md`
    /// item 10 commits to "track boolean, not which key." Reading the
    /// specific modifier name or keyCode out of `self` for telemetry
    /// would cross that line.
    public var telemetryKind: TelemetryHotkeyKind {
        switch kind {
        case .disabled: return .disabled
        case .modifier: return .modifier
        case .keyCode:  return .keyCode
        case .chord:    return .chord
        case .modifierChord: return .chord
        }
    }

    /// Builds the `.hotkeyCustomized` event spec for this trigger. Pulled
    /// into a single helper so each settings call site stays a one-liner.
    public func customizedEvent(surface: TelemetryHotkeySurface) -> TelemetryEventSpec {
        .hotkeyCustomized(surface: surface, kind: telemetryKind)
    }
}

// MARK: - Equatable (canonical identity only)

extension HotkeyTrigger: Equatable {
    public static func == (lhs: HotkeyTrigger, rhs: HotkeyTrigger) -> Bool {
        lhs.kind == rhs.kind && lhs.modifierName == rhs.modifierName
            && lhs.keyCode == rhs.keyCode && lhs.chordModifiers == rhs.chordModifiers
            && lhs.modifierKeyCode == rhs.modifierKeyCode
            && lhs.modifierChordComponents == rhs.modifierChordComponents
    }
}

// MARK: - Codable (canonical identity only — no displayName/shortSymbol)

extension HotkeyTrigger: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, modifierName, keyCode, chordModifiers, modifierKeyCode, modifierChordComponents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        modifierName = try container.decodeIfPresent(String.self, forKey: .modifierName)
        keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
        chordModifiers = try container.decodeIfPresent([String].self, forKey: .chordModifiers)
        modifierKeyCode = try container.decodeIfPresent(UInt16.self, forKey: .modifierKeyCode)
        let components = try container.decodeIfPresent(
            [ModifierComponent].self,
            forKey: .modifierChordComponents
        )
        modifierChordComponents = components.map { Self.normalizedModifierComponents($0) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(modifierName, forKey: .modifierName)
        try container.encodeIfPresent(keyCode, forKey: .keyCode)
        try container.encodeIfPresent(chordModifiers, forKey: .chordModifiers)
        try container.encodeIfPresent(modifierKeyCode, forKey: .modifierKeyCode)
        try container.encodeIfPresent(modifierChordComponents, forKey: .modifierChordComponents)
    }
}
