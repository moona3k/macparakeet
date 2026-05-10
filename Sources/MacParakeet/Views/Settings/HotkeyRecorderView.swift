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
        case generic
        case sideSpecific
    }

    @Binding var trigger: HotkeyTrigger
    var defaultTrigger: HotkeyTrigger = .fn
    var additionalValidation: ((HotkeyTrigger) -> HotkeyTrigger.ValidationResult)? = nil
    @State private var isRecording = false
    @State private var validationMessage: String?
    @State private var validationIsBlocked = false
    @State private var eventMonitor: Any?
    /// Tracks held modifiers during recording for two-phase chord capture.
    @State private var pendingModifierComponents: [HotkeyTrigger.ModifierComponent] = []
    @State private var candidateModifierComponents: [HotkeyTrigger.ModifierComponent] = []
    @State private var modifierCaptureMode: ModifierCaptureMode = .generic

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
                Text("\(trigger.shortSymbol) \(trigger.displayName)")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(.primary)
            }

            Button(trigger.isDisabled ? "Set Hotkey..." : "Change...") {
                startRecording(modifierCaptureMode: .generic)
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

                Button("Reset to Default (\(Self.resetLabel(for: defaultTrigger)))") {
                    resetToDefault()
                }
                .disabled(trigger == defaultTrigger)

                Divider()

                Button("Record Specific Modifier Side") {
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
        if modifierCaptureMode == .sideSpecific {
            return HotkeyTrigger.modifierChord(components: pendingModifierComponents).shortSymbol
        }

        let order = ["control", "option", "shift", "command"]
        let symbols: [String: String] = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"]
        let names = pendingModifierComponents.map(\.modifierName)
        return order.filter { names.contains($0) }
            .compactMap { symbols[$0] }
            .joined()
    }

    // MARK: - Recording Logic

    private func startRecording(modifierCaptureMode: ModifierCaptureMode = .generic) {
        // Guard against double-start leaking the existing monitor
        if eventMonitor != nil { stopRecording() }

        isRecording = true
        validationMessage = nil
        validationIsBlocked = false
        pendingModifierComponents = []
        candidateModifierComponents = []
        self.modifierCaptureMode = modifierCaptureMode

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [self] event in
            if event.type == .keyDown {
                let keyCode = event.keyCode

                // Escape cancels recording mode
                if keyCode == 53 {
                    stopRecording()
                    return nil
                }

                // Check if chord modifiers are held (Cmd, Ctrl, Option, Shift — excluding Fn/Caps Lock)
                let heldModifiers = chordModifiersFromFlags(event.modifierFlags)

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
                        // Fn is bare modifier only — accept immediately on key-down
                        if event.modifierFlags.contains(.function) {
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
    /// Excludes Fn (bare modifier only per plan).
    private func chordModifiersFromFlags(_ flags: NSEvent.ModifierFlags) -> [String] {
        var modifiers: [String] = []
        if flags.contains(.control) { modifiers.append("control") }
        if flags.contains(.option) { modifiers.append("option") }
        if flags.contains(.shift) { modifiers.append("shift") }
        if flags.contains(.command) { modifiers.append("command") }
        return modifiers
    }

    private func modifierComponentsAfterFlagsChanged(
        _ event: NSEvent,
        modifierName: String
    ) -> [HotkeyTrigger.ModifierComponent] {
        switch modifierCaptureMode {
        case .generic:
            return chordModifiersFromFlags(event.modifierFlags).map {
                HotkeyTrigger.ModifierComponent(modifierName: $0)
            }
        case .sideSpecific:
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
    /// Generic capture preserves the legacy "either side" behavior. Side-specific capture
    /// records the physical left/right key that was used during recording.
    static func bareModifierTrigger(
        for name: String,
        keyCode: UInt16,
        captureMode: ModifierCaptureMode
    ) -> HotkeyTrigger? {
        let genericNames: Set<String> = ["control", "option", "shift", "command"]
        guard genericNames.contains(name) else { return nil }
        switch captureMode {
        case .generic:
            return HotkeyTrigger(kind: .modifier, modifierName: name, keyCode: nil)
        case .sideSpecific:
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
        case .sideSpecific:
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
        guard captureMode == .generic else { return nil }
        return HotkeyTrigger.chord(modifiers: modifiers, keyCode: keyCode)
    }

    static func mergedModifierComponents(
        _ lhs: [HotkeyTrigger.ModifierComponent],
        _ rhs: [HotkeyTrigger.ModifierComponent]
    ) -> [HotkeyTrigger.ModifierComponent] {
        HotkeyTrigger.modifierChord(components: lhs + rhs).normalizedModifierChordComponents
    }

    static func resetLabel(for trigger: HotkeyTrigger) -> String {
        if trigger == .fn { return "🌐 Fn" }
        if trigger.kind == .modifier { return trigger.displayName }
        return trigger.shortSymbol
    }

    private func stopRecording() {
        isRecording = false
        pendingModifierComponents = []
        candidateModifierComponents = []
        modifierCaptureMode = .generic
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
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
