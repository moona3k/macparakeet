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
    /// Chord triggers: this physical press already made its swallow decision.
    private var chordPressSettled = false
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
                // One decision per physical press. Repeats keep an accepted
                // swallow while the required modifiers remain, so adding Shift
                // does not deliver the held key. A rejected press stays
                // rejected until key-up, so releasing Shift cannot start it.
                // Losing a required modifier stops swallowing; that keyUp
                // reaches the app.
                if chordPressSettled {
                    let relevant = flags & HotkeyTrigger.relevantModifierBits
                    let requiredStillHeld = relevant & requiredChordFlags == requiredChordFlags
                    if consumedChordKeyDown, requiredStillHeld {
                        return true
                    }
                    consumedChordKeyDown = false
                    return false
                }
                let matches = trigger.chordEventMatches(flags: flags)
                chordPressSettled = true
                consumedChordKeyDown = matches
                return matches
            case .keyUp:
                let swallow = consumedChordKeyDown
                consumedChordKeyDown = false
                chordPressSettled = false
                return swallow
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
        chordPressSettled = false
    }
}
