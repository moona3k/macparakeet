import CoreGraphics
import MacParakeetCore
import SwiftUI

/// "Record a shortcut" UI for hotkey selection.
/// Normal state:    [ fn Fn              Change... ]
/// Recording state: [ Press any key...   Cancel    ]  (highlighted border)
/// With warning:    [ Space              Change... ]
///                    Warning text shown below.
struct HotkeyRecorderView: View {
    enum ModifierCaptureMode {
        case standard
        case generic
        case sideSpecific
    }

    @Binding var trigger: HotkeyTrigger
    var defaultTrigger: HotkeyTrigger = .fn
    var displayLabelOverride: String? = nil
    var defaultLabelOverride: String? = nil
    var additionalValidation: ((HotkeyTrigger) -> HotkeyTrigger.ValidationResult)? = nil
    /// Called with `true` when the user enters recording mode (just before
    /// the local NSEvent monitor is attached) and `false` when the matching
    /// recording session ends. Settings wires this to
    /// `AppHotkeyCoordinator.suspend` / `resume` so global CGEvent taps
    /// don't swallow the keyDown the user is trying to record.
    var onRecordingStateChanged: ((Bool) -> Void)? = nil
    @State private var isRecording = false
    @State private var validationMessage: String?
    @State private var validationIsBlocked = false
    @State private var eventMonitor: Any?
    /// Tracks held modifiers during recording for two-phase chord capture.
    @State private var pendingModifierComponents: [HotkeyTrigger.ModifierComponent] = []
    @State private var candidateModifierComponents: [HotkeyTrigger.ModifierComponent] = []
    @State private var modifierCaptureMode: ModifierCaptureMode = .standard

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if isRecording {
                recordingView
            } else {
                normalView
            }

            if let message = validationMessage, !isRecording {
                HStack(spacing: 4) {
                    Image(systemName: validationIsBlocked ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(message)
                        .font(DesignSystem.Typography.micro)
                }
                .foregroundStyle(validationIsBlocked ? DesignSystem.Colors.errorRed : DesignSystem.Colors.warningAmber)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    // MARK: - Normal State

    private var normalView: some View {
        HStack(spacing: 8) {
            if trigger.isDisabled {
                Text("Disabled")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(.secondary)
            } else {
                Text(displayLabelOverride ?? trigger.formattedLabel)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(.primary)
            }

            Button(trigger.isDisabled ? "Set Hotkey..." : "Change...") {
                startRecording(modifierCaptureMode: .standard)
            }
            .parakeetAction(.secondary)

            Menu {
                if !trigger.isDisabled {
                    Button("Disable Hotkey") {
                        trigger = .disabled
                        validationMessage = nil
                        validationIsBlocked = false
                    }

                    Divider()
                }

                Button("Reset to Default (\(defaultLabelOverride ?? Self.resetLabel(for: defaultTrigger)))") {
                    resetToDefault()
                }
                .disabled(trigger == defaultTrigger)

                Divider()

                Button("Record Either-Side Modifier") {
                    startRecording(modifierCaptureMode: .generic)
                }

                Button("Record Specific-Side Modifier Chord") {
                    startRecording(modifierCaptureMode: .sideSpecific)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .help(trigger.isDisabled
                ? "Hotkey options, including restoring the default shortcut or recording a specific modifier key."
                : "Advanced hotkey options, including resetting to default or recording a specific modifier key.")
        }
    }

    // MARK: - Recording State

    private var recordingView: some View {
        HStack(spacing: 8) {
            if pendingModifierComponents.isEmpty {
                Text("Press any key...")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(.secondary)
            } else {
                Text(pendingModifierSymbols + "...")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(.primary)
            }

            Button("Cancel") {
                stopRecording()
            }
            .parakeetAction(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(DesignSystem.Colors.accent.opacity(0.5), lineWidth: 1.5)
        )
    }

    /// Symbols for currently held modifiers in standard macOS order (⌃⌥⇧⌘).
    private var pendingModifierSymbols: String {
        if modifierCaptureMode == .standard || modifierCaptureMode == .sideSpecific {
            if pendingModifierComponents.map(\.modifierName) == ["fn"] { return "fn" }
            return HotkeyTrigger.modifierChord(components: pendingModifierComponents).shortSymbol
        }

        let order = ["fn", "control", "option", "shift", "command"]
        let symbols: [String: String] = ["fn": "fn", "control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"]
        let names = pendingModifierComponents.map(\.modifierName)
        let parts = order.filter { names.contains($0) }
            .compactMap { symbols[$0] }
        return parts.joined(separator: names.contains("fn") ? "+" : "")
    }

    // MARK: - Recording Logic

    private func startRecording(modifierCaptureMode: ModifierCaptureMode = .standard) {
        // Guard against double-start leaking the existing monitor
        if eventMonitor != nil { stopRecording() }

        isRecording = true
        validationMessage = nil
        validationIsBlocked = false
        pendingModifierComponents = []
        candidateModifierComponents = []
        self.modifierCaptureMode = modifierCaptureMode

        // Suspend global hotkey taps BEFORE attaching our local monitor so
        // existing chord/key-code listeners can't swallow the very first
        // keyDown we're trying to capture.
        onRecordingStateChanged?(true)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [self] event in
            if event.type == .keyDown {
                let keyCode = event.keyCode

                // Escape cancels recording mode
                if keyCode == 53 {
                    stopRecording()
                    return nil
                }

                // Check if chord modifiers are held. Caps Lock remains excluded.
                let heldModifiers = Self.chordModifierNames(
                    flags: event.modifierFlags,
                    keyCode: keyCode,
                    pendingComponents: pendingModifierComponents
                )

                if !heldModifiers.isEmpty {
                    // Chord: modifier(s) + key
                    guard let candidate = Self.keyChordTrigger(
                        modifiers: heldModifiers,
                        keyCode: keyCode,
                        captureMode: modifierCaptureMode
                    ) else {
                        stopRecording()
                        validationMessage = Self.sideSpecificKeyChordMessage
                        validationIsBlocked = true
                        return nil
                    }
                    switch combinedValidation(for: candidate) {
                    case .blocked(let msg):
                        pendingModifierComponents = []
                        candidateModifierComponents = []
                        validationMessage = msg
                        validationIsBlocked = true
                        return nil
                    case .warned(let msg):
                        acceptTrigger(candidate, warning: msg)
                        return nil
                    case .allowed:
                        acceptTrigger(candidate, warning: nil)
                        return nil
                    }
                } else {
                    // Bare key (no modifiers held)
                    let candidate = HotkeyTrigger.fromKeyCode(keyCode)
                    switch combinedValidation(for: candidate) {
                    case .blocked(let msg):
                        validationMessage = msg
                        validationIsBlocked = true
                        return nil
                    case .warned(let msg):
                        acceptTrigger(candidate, warning: msg)
                        return nil
                    case .allowed:
                        acceptTrigger(candidate, warning: nil)
                        return nil
                    }
                }
            } else if event.type == .flagsChanged {
                // Identify which modifier key changed
                let modifierName = HotkeyTrigger.modifierName(forKeyCode: event.keyCode)

                if let name = modifierName {
                    if name == "fn" {
                        if event.modifierFlags.contains(.function) {
                            pendingModifierComponents = [.init(modifierName: "fn")]
                            candidateModifierComponents = pendingModifierComponents
                        } else if candidateModifierComponents.contains(.init(modifierName: "fn")) {
                            pendingModifierComponents = []
                            candidateModifierComponents = []
                            switch combinedValidation(for: .fn) {
                            case .blocked(let msg):
                                validationMessage = msg
                                validationIsBlocked = true
                                return event
                            case .warned(let msg):
                                acceptTrigger(.fn, warning: msg)
                                return event
                            case .allowed:
                                acceptTrigger(.fn, warning: nil)
                                return event
                            }
                        }
                    } else {
                        let currentHeld = modifierComponentsAfterFlagsChanged(event, modifierName: name)
                        if currentHeld.isEmpty {
                            let releasedComponents = candidateModifierComponents
                            pendingModifierComponents = []
                            candidateModifierComponents = []

                            if let candidate = Self.modifierChordTrigger(
                                components: releasedComponents,
                                captureMode: modifierCaptureMode
                            ) {
                                switch combinedValidation(for: candidate) {
                                case .blocked(let msg):
                                    validationMessage = msg
                                    validationIsBlocked = true
                                    return event
                                case .warned(let msg):
                                    acceptTrigger(candidate, warning: msg)
                                    return event
                                case .allowed:
                                    acceptTrigger(candidate, warning: nil)
                                    return event
                                }
                            }

                            if let candidate = Self.bareModifierTrigger(
                                for: name,
                                keyCode: event.keyCode,
                                captureMode: modifierCaptureMode
                            ) {
                                switch combinedValidation(for: candidate) {
                                case .blocked(let msg):
                                    validationMessage = msg
                                    validationIsBlocked = true
                                    return event
                                case .warned(let msg):
                                    acceptTrigger(candidate, warning: msg)
                                    return event
                                case .allowed:
                                    acceptTrigger(candidate, warning: nil)
                                    return event
                                }
                            }
                        } else {
                            pendingModifierComponents = currentHeld
                            candidateModifierComponents = Self.mergedModifierComponents(
                                candidateModifierComponents,
                                currentHeld
                            )
                        }
                    }
                }
            }
            return event
        }
    }

    /// Extract chord-eligible modifier names from NSEvent modifier flags.
    /// Caps Lock is intentionally excluded.
    private func chordModifiersFromFlags(_ flags: NSEvent.ModifierFlags, keyCode: UInt16) -> [String] {
        Self.chordModifierNames(flags: flags, keyCode: keyCode, pendingComponents: [])
    }

    static func chordModifierNames(
        flags: NSEvent.ModifierFlags,
        keyCode: UInt16,
        pendingComponents: [HotkeyTrigger.ModifierComponent]
    ) -> [String] {
        let order = ["fn", "control", "option", "shift", "command"]
        var names: Set<String> = []
        // macOS sets `.function` on every function-family key press (F-keys,
        // arrows, nav cluster) even when the physical Fn key is not held, so
        // deriving "fn" from flags there would pollute the chord (Ctrl+F19
        // would record as fn+⌃F19, and bare F19 could never reach the
        // bare-key path). A physically held Fn still arrives via
        // `pendingComponents` (flagsChanged keyCode 63/179), unioned below;
        // fn+letter chords keep flags-derived fn because letters are not
        // function-family.
        if flags.contains(.function), !KeyCodeNames.isFunctionFamilyKeyCode(keyCode) {
            names.insert("fn")
        }
        if flags.contains(.control) { names.insert("control") }
        if flags.contains(.option) { names.insert("option") }
        if flags.contains(.shift) { names.insert("shift") }
        if flags.contains(.command) { names.insert("command") }
        names.formUnion(pendingComponents.map(\.modifierName))
        return order.filter { names.contains($0) }
    }

    private func modifierComponentsAfterFlagsChanged(
        _ event: NSEvent,
        modifierName: String
    ) -> [HotkeyTrigger.ModifierComponent] {
        switch modifierCaptureMode {
        case .generic:
            return chordModifiersFromFlags(event.modifierFlags, keyCode: event.keyCode).map {
                HotkeyTrigger.ModifierComponent(modifierName: $0)
            }
        case .standard, .sideSpecific:
            return Self.sideSpecificModifierComponentsAfterFlagsChanged(
                pending: pendingModifierComponents,
                eventKeyCode: event.keyCode,
                modifierName: modifierName,
                flags: event.modifierFlags
            )
        }
    }

    static func sideSpecificModifierComponentsAfterFlagsChanged(
        pending: [HotkeyTrigger.ModifierComponent],
        eventKeyCode: UInt16,
        modifierName: String,
        flags: NSEvent.ModifierFlags
    ) -> [HotkeyTrigger.ModifierComponent] {
        let cgFlags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        let sideSpecificHeld: [HotkeyTrigger.ModifierComponent] = HotkeyTrigger.sideSpecificModifierKeyCodes.compactMap { keyCode in
            guard ModifierKeyMatcher.sideSpecificModifierIsPressed(flags: cgFlags, keyCode: keyCode) else {
                return nil
            }
            return HotkeyTrigger.modifierComponent(forKeyCode: keyCode)
        }
        if !sideSpecificHeld.isEmpty { return sideSpecificHeld }

        guard let changed = HotkeyTrigger.modifierComponent(forKeyCode: eventKeyCode) else {
            return pending
        }

        var current = pending
        if current.contains(changed) {
            current.removeAll { $0 == changed }
        } else if modifierFlagIsPressed(modifierName, in: flags) {
            current = mergedModifierComponents(current, [changed])
        }
        return current
    }

    private static func modifierFlagIsPressed(_ name: String, in flags: NSEvent.ModifierFlags) -> Bool {
        switch name {
        case "control": return flags.contains(.control)
        case "option": return flags.contains(.option)
        case "shift": return flags.contains(.shift)
        case "command": return flags.contains(.command)
        default: return false
        }
    }

    /// Map a modifier name + physical keyCode to a bare modifier trigger.
    /// Generic capture preserves the legacy "either side" behavior. Standard
    /// and side-specific capture record the physical left/right key used.
    static func bareModifierTrigger(
        for name: String,
        keyCode: UInt16,
        captureMode: ModifierCaptureMode
    ) -> HotkeyTrigger? {
        let genericNames: Set<String> = ["fn", "control", "option", "shift", "command"]
        guard genericNames.contains(name) else { return nil }
        if name == "fn" {
            return .fn
        }
        switch captureMode {
        case .generic:
            return HotkeyTrigger(kind: .modifier, modifierName: name, keyCode: nil)
        case .standard, .sideSpecific:
            return HotkeyTrigger(kind: .modifier, modifierName: name, keyCode: nil, modifierKeyCode: keyCode)
        }
    }

    static func modifierChordTrigger(
        components: [HotkeyTrigger.ModifierComponent],
        captureMode: ModifierCaptureMode
    ) -> HotkeyTrigger? {
        let trigger: HotkeyTrigger
        switch captureMode {
        case .generic:
            trigger = HotkeyTrigger.modifierChord(
                components: components.map {
                    HotkeyTrigger.ModifierComponent(modifierName: $0.modifierName)
                }
            )
        case .standard, .sideSpecific:
            trigger = HotkeyTrigger.modifierChord(components: components)
        }

        guard trigger.normalizedModifierChordComponents.count >= 2 else { return nil }
        return trigger
    }

    static let sideSpecificKeyChordMessage =
        "Specific-side recording only supports modifier-only shortcuts. Use Change... for modifier+key shortcuts."

    static func keyChordTrigger(
        modifiers: [String],
        keyCode: UInt16,
        captureMode: ModifierCaptureMode
    ) -> HotkeyTrigger? {
        guard captureMode == .standard || captureMode == .generic else { return nil }
        return HotkeyTrigger.chord(modifiers: modifiers, keyCode: keyCode)
    }

    static func mergedModifierComponents(
        _ lhs: [HotkeyTrigger.ModifierComponent],
        _ rhs: [HotkeyTrigger.ModifierComponent]
    ) -> [HotkeyTrigger.ModifierComponent] {
        HotkeyTrigger.modifierChord(components: lhs + rhs).normalizedModifierChordComponents
    }

    static func resetLabel(for trigger: HotkeyTrigger) -> String {
        // The reset menu reads as "Reset to Default (X)" — keep X compact and
        // English-y. The Settings row uses `HotkeyTrigger.formattedLabel` which
        // prefixes modifiers with their glyph, but that's noisier in a menu
        // parenthetical.
        if trigger == .fn { return "🌐 Fn" }
        if trigger.kind == .modifier { return trigger.displayName }
        return trigger.shortSymbol
    }

    private func stopRecording() {
        // Tracking against `isRecording` (the canonical UI state) keeps the
        // (true)/(false) pair balanced even if `addLocalMonitorForEvents`
        // returns nil — the start callback fired before the monitor was
        // attached, so the stop callback must mirror that fact, not the
        // monitor's presence. Also ensures spurious `onDisappear` calls
        // don't unbalance the coordinator's suspend refcount.
        let wasRecording = isRecording
        isRecording = false
        pendingModifierComponents = []
        candidateModifierComponents = []
        modifierCaptureMode = .standard
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if wasRecording {
            onRecordingStateChanged?(false)
        }
    }

    private func resetToDefault() {
        switch combinedValidation(for: defaultTrigger) {
        case .blocked(let msg):
            validationMessage = msg
            validationIsBlocked = true
        case .warned(let msg):
            trigger = defaultTrigger
            validationMessage = msg
            validationIsBlocked = false
        case .allowed:
            trigger = defaultTrigger
            validationMessage = nil
            validationIsBlocked = false
        }
    }

    private func acceptTrigger(_ candidate: HotkeyTrigger, warning: String?) {
        trigger = candidate
        validationMessage = warning
        validationIsBlocked = false
        stopRecording()
    }

    private func combinedValidation(for candidate: HotkeyTrigger) -> HotkeyTrigger.ValidationResult {
        let primary = candidate.validation
        let secondary = additionalValidation?(candidate) ?? .allowed

        switch (primary, secondary) {
        case (.blocked(let message), _):
            return .blocked(message)
        case (_, .blocked(let message)):
            return .blocked(message)
        case (.warned(let message), _):
            return .warned(message)
        case (_, .warned(let message)):
            return .warned(message)
        default:
            return .allowed
        }
    }
}
