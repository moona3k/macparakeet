import SwiftUI
import MacParakeetCore

/// "Record a shortcut" UI for hotkey selection.
/// Normal state:    [ fn Fn              Change... ]
/// Recording state: [ Press any key...   Cancel    ]  (highlighted border)
/// With warning:    [ Space              Change... ]
///                    Warning text shown below.
struct HotkeyRecorderView: View {
    @Binding var trigger: HotkeyTrigger
    var additionalValidation: ((HotkeyTrigger) -> HotkeyTrigger.ValidationResult)? = nil
    @State private var isRecording = false
    @State private var validationMessage: String?
    @State private var validationIsBlocked = false
    @State private var eventMonitor: Any?
    /// Tracks held modifiers during recording for two-phase chord capture.
    @State private var pendingModifiers: [String] = []

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
            Text("\(trigger.shortSymbol) \(trigger.displayName)")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.primary)

            Button("Change...") {
                startRecording()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Recording State

    private var recordingView: some View {
        HStack(spacing: 8) {
            if pendingModifiers.isEmpty {
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
            .buttonStyle(.bordered)
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
        let order = ["control", "option", "shift", "command"]
        let symbols: [String: String] = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"]
        return order.filter { pendingModifiers.contains($0) }
            .compactMap { symbols[$0] }
            .joined()
    }

    // MARK: - Recording Logic

    private func startRecording() {
        // Guard against double-start leaking the existing monitor
        if eventMonitor != nil { stopRecording() }

        isRecording = true
        validationMessage = nil
        validationIsBlocked = false
        pendingModifiers = []

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
                    let candidate = HotkeyTrigger.chord(modifiers: heldModifiers, keyCode: keyCode)
                    switch combinedValidation(for: candidate) {
                    case .blocked(let msg):
                        pendingModifiers = []
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
                let modifierName: String? = switch event.keyCode {
                case 63, 179:  "fn"       // Fn/Globe
                case 59, 62:   "control"  // Left/Right Control
                case 58, 61:   "option"   // Left/Right Option
                case 56, 60:   "shift"    // Left/Right Shift
                case 55, 54:   "command"  // Left/Right Command
                default:       nil
                }

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
                        // Track held chord modifiers for preview
                        let currentHeld = chordModifiersFromFlags(event.modifierFlags)
                        pendingModifiers = currentHeld

                        // If all chord-eligible modifiers released, accept as bare modifier
                        if currentHeld.isEmpty {
                            if let candidate = bareModifierTrigger(for: name) {
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

    /// Map a modifier name to its bare modifier trigger.
    private func bareModifierTrigger(for name: String) -> HotkeyTrigger? {
        switch name {
        case "control": return .control
        case "option": return .option
        case "shift": return .shift
        case "command": return .command
        default: return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
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
