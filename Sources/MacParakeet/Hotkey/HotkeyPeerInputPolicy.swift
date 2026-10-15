import CoreGraphics
import MacParakeetCore

/// Physical input that belongs to the other accepted dictation shortcuts.
///
/// Every dictation `HotkeyManager` sees the same global event stream with
/// combined modifier flags. While one manager owns a held take, pressing a peer
/// shortcut looks like typing to it. A manager asks this policy which inputs are
/// peer-owned and skips only those interruptions.
///
/// Matching follows how a peer recognizes itself: its modifier identity
/// (including side), its chord modifiers being held, and its exact terminal
/// key. It never uses `HotkeyTrigger.overlaps`, which compares configurations
/// rather than physical events.
struct HotkeyPeerInputPolicy: Equatable {
    static let none = HotkeyPeerInputPolicy(peers: [])

    /// Modifier keys the peers use. A nil `keyCode` accepts either side.
    private let modifierComponents: [HotkeyTrigger.ModifierComponent]
    /// Peers completed by an ordinary key: key triggers and chords.
    private let keyTriggers: [HotkeyTrigger]

    init(peers: [HotkeyTrigger]) {
        var components: [HotkeyTrigger.ModifierComponent] = []
        var keyTriggers: [HotkeyTrigger] = []
        for peer in peers {
            switch peer.kind {
            case .disabled:
                break
            case .modifier:
                if let name = peer.modifierName {
                    components.append(.init(modifierName: name, keyCode: peer.modifierKeyCode))
                }
            case .keyCode:
                keyTriggers.append(peer)
            case .chord:
                // The modifiers are a prefix: pressing them alone is part of the chord.
                components += (peer.chordModifiers ?? []).map { .init(modifierName: $0) }
                keyTriggers.append(peer)
            case .modifierChord:
                components += peer.normalizedModifierChordComponents
            }
        }
        self.modifierComponents = components
        self.keyTriggers = keyTriggers
    }

    /// True when a key release can matter, so the owner's tap must see keyUp.
    var claimsKeys: Bool { !keyTriggers.isEmpty }

    /// `keyCode` is the pressed side, or nil when the event does not say. Without
    /// a side nothing rules a side-specific peer out, so the generic flag falls
    /// back to it, as side-specific triggers match when macOS reports only that.
    func claimsModifier(named name: String, keyCode: UInt16?) -> Bool {
        modifierComponents.contains {
            $0.modifierName == name && (keyCode == nil || $0.keyCode == nil || $0.keyCode == keyCode)
        }
    }

    func claimsModifierKeyCode(_ keyCode: UInt16) -> Bool {
        guard let name = HotkeyTrigger.modifierName(forKeyCode: keyCode) else { return false }
        return claimsModifier(named: name, keyCode: keyCode)
    }

    /// A key event that belongs to a peer: its key trigger, its chord's
    /// terminal key with the chord modifiers held in `flags`, or the Fn key
    /// macOS reports as a key when Fn is a peer. A terminal key without its
    /// chord modifiers is ordinary typing and is not claimed.
    func claimsKey(_ keyCode: UInt16, flags: UInt64) -> Bool {
        if HotkeyTrigger.isFnKeyCode(keyCode) {
            return claimsModifier(named: "fn", keyCode: nil)
        }
        return keyTriggers.contains { trigger in
            guard trigger.keyCode == keyCode else { return false }
            guard trigger.kind == .chord else { return true }
            return flags & HotkeyTrigger.relevantModifierBits & trigger.chordEventFlags
                == trigger.chordEventFlags
        }
    }

    /// The tracked modifier bits in `flags` that only peers are holding, judged
    /// per side when the event carries side bits. `own` is never claimed: a
    /// peer chord may share a modifier with the owner's trigger.
    func claimedModifierFlags(in flags: CGEventFlags, excluding own: CGEventFlags) -> CGEventFlags {
        var claimed: CGEventFlags = []
        for name in Set(modifierComponents.map(\.modifierName)) {
            guard let mask = ModifierKeyMatcher.mask(for: name),
                flags.contains(mask), !own.contains(mask)
            else { continue }
            let pressedSides = HotkeyTrigger.sideSpecificModifierKeyCodes.filter {
                HotkeyTrigger.modifierName(forKeyCode: $0) == name
                    && ModifierKeyMatcher.sideSpecificModifierIsPressed(flags: flags, keyCode: $0)
            }
            let sides: [UInt16?] = pressedSides.isEmpty ? [nil] : pressedSides
            if sides.allSatisfy({ claimsModifier(named: name, keyCode: $0) }) {
                claimed.insert(mask)
            }
        }
        return claimed
    }
}
