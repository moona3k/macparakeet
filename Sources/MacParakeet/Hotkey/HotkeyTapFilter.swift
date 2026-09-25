import CoreGraphics
import MacParakeetCore

/// Decides, on the event-tap thread, whether `HotkeyManager` consumes an event.
///
/// The decision depends only on the trigger and the event stream, never on
/// gesture state, so it can run without the main thread (#1142). Gesture
/// processing happens later on the main thread from a forwarded snapshot.
struct HotkeyTapFilter {
    private let trigger: HotkeyTrigger
    private let requiredChordFlags: UInt64
    /// Chord triggers: the trigger keyDown was consumed, so its keyUp is too.
    private var consumedChordKeyDown = false

    init(trigger: HotkeyTrigger) {
        self.trigger = trigger
        self.requiredChordFlags = trigger.chordEventFlags
    }

    /// `flags` are the event's raw flags; only the chord modifier bits matter.
    mutating func shouldSwallow(type: CGEventType, keyCode: UInt16, flags: UInt64) -> Bool {
        guard let triggerCode = trigger.keyCode, keyCode == triggerCode else { return false }
        switch trigger.kind {
        case .keyCode:
            // The trigger key belongs to MacParakeet, repeats included.
            return type == .keyDown || type == .keyUp
        case .chord:
            switch type {
            case .keyDown:
                // Superset match: tolerates the phantom Fn bit on F-keys.
                let matches = flags & HotkeyTrigger.relevantModifierBits & requiredChordFlags
                    == requiredChordFlags
                // An unconsumed keyDown reaches the app, so its keyUp must too.
                consumedChordKeyDown = matches
                return matches
            case .keyUp:
                defer { consumedChordKeyDown = false }
                return consumedChordKeyDown
            default:
                return false
            }
        case .modifier, .modifierChord, .disabled:
            return false
        }
    }

    /// Resync after macOS re-enables a disabled tap.
    mutating func tapReenabled(triggerKeyPressed: Bool) {
        consumedChordKeyDown = trigger.kind == .chord && triggerKeyPressed
    }
}
