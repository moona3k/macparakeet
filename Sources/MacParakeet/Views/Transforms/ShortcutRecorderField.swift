import AppKit
import SwiftUI

struct ShortcutRecorderField: View {
    @Binding var shortcut: TransformShortcut?
    @Binding var isRecording: Bool
    let onRecordingStateChanged: (Bool) -> Void

    @State private var localMonitor: Any?
    @State private var notifiedRecordingActive = false

    var body: some View {
        HStack {
            Group {
                if let shortcut {
                    KeycapBadge(shortcut: shortcut)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Shortcut \(shortcut.displayString)")
                } else {
                    Text(isRecording ? "Press a keyboard combo..." : "Click to add a shortcut")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(isRecording ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
                }
            }
            Spacer()
            Button(action: { isRecording.toggle() }) {
                Image(systemName: isRecording ? "stop.circle" : "pencil")
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecording ? "Stop recording shortcut" : "Record shortcut")

            if shortcut != nil {
                Button(action: { shortcut = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
                .accessibilityLabel("Clear shortcut")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm + 2)
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isRecording ? DesignSystem.Colors.accent : DesignSystem.Colors.border,
                    lineWidth: isRecording ? 1.0 : 0.5
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isRecording.toggle()
        }
        .onChange(of: isRecording) { _, recording in
            if recording {
                notifyRecordingState(true)
                installMonitor()
            } else {
                removeMonitor()
                notifyRecordingState(false)
            }
        }
        .onDisappear { stopRecordingIfNeeded() }
    }

    private func installMonitor() {
        removeMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if Self.shouldCancelRecording(event) {
                isRecording = false
                return nil
            }
            let modifierBits = UInt(event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue)
            let keyCode = event.keyCode
            let label = labelForKey(event: event)
            shortcut = TransformShortcut(
                modifiers: modifierBits,
                keyCode: keyCode,
                keyLabel: label
            )
            isRecording = false
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func stopRecordingIfNeeded() {
        if isRecording {
            isRecording = false
        }
        removeMonitor()
        notifyRecordingState(false)
    }

    private func notifyRecordingState(_ active: Bool) {
        guard notifiedRecordingActive != active else { return }
        notifiedRecordingActive = active
        onRecordingStateChanged(active)
    }

    private func labelForKey(event: NSEvent) -> String {
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            let scalar = chars.first!
            switch event.keyCode {
            case 0x24: return "Return"
            case 0x30: return "Tab"
            case 0x31: return "Space"
            case 0x35: return "Escape"
            default:
                if scalar.isLetter || scalar.isNumber {
                    return String(scalar).uppercased()
                }
                if scalar.asciiValue.map({ $0 >= 32 }) ?? false {
                    return String(scalar)
                }
            }
        }
        return "Key \(event.keyCode)"
    }

    static func shouldCancelRecording(_ event: NSEvent) -> Bool {
        event.keyCode == 0x35
    }
}
