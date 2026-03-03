import SwiftUI
import MacParakeetCore

/// "Record a shortcut" UI for hotkey selection.
/// Normal state:    [ fn Fn              Change... ]
/// Recording state: [ Press any key...   Cancel    ]  (highlighted border)
/// With warning:    [ Space              Change... ]
///                    Warning text shown below.
struct HotkeyRecorderView: View {
    @Binding var trigger: HotkeyTrigger
    @State private var isRecording = false
    @State private var validationMessage: String?
    @State private var validationIsBlocked = false
    @State private var eventMonitor: Any?

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
            Text("Press any key...")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.secondary)

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

    // MARK: - Recording Logic

    private func startRecording() {
        isRecording = true
        validationMessage = nil
        validationIsBlocked = false

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [self] event in
            if event.type == .keyDown {
                let keyCode = event.keyCode

                // Escape cancels recording mode
                if keyCode == 53 {
                    stopRecording()
                    return nil
                }

                let candidate = HotkeyTrigger.fromKeyCode(keyCode)
                switch candidate.validation {
                case .blocked(let msg):
                    validationMessage = msg
                    validationIsBlocked = true
                    // Stay in recording mode
                    return nil
                case .warned(let msg):
                    acceptTrigger(candidate, warning: msg)
                    return nil
                case .allowed:
                    acceptTrigger(candidate, warning: nil)
                    return nil
                }
            } else if event.type == .flagsChanged {
                // Detect which modifier was pressed by comparing flags
                let flags = event.modifierFlags
                let candidate: HotkeyTrigger?

                if flags.contains(.function) {
                    candidate = .fn
                } else if flags.contains(.control) {
                    candidate = .control
                } else if flags.contains(.option) {
                    candidate = .option
                } else if flags.contains(.shift) {
                    candidate = .shift
                } else if flags.contains(.command) {
                    candidate = .command
                } else {
                    candidate = nil
                }

                if let candidate {
                    acceptTrigger(candidate, warning: nil)
                    return event // Pass modifier through
                }
            }
            return event
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
}
