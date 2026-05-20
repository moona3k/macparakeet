import Cocoa
import Foundation
import MacParakeetCore
import OSLog

/// Single process-wide event tap that dispatches keyboard chords to bound
/// Transforms. Owns one `CGEventTap` and a `[KeyMatch: Prompt.ID]` dispatch
/// table — replaces the per-Transform `GlobalShortcutManager` pattern that
/// would compete on the same tap.
///
/// Each Transform's shortcut is a `KeyboardShortcut` (modifiers + virtual
/// keycode + display label). The registry collapses that into an internal
/// `KeyMatch(keyCode:modifierFlags:)` used for `O(1)` lookup on keyDown.
///
/// **Threading.** The CGEvent tap callback runs on the runloop that installed
/// the tap (typically the main runloop). The registry's public `onTrigger`
/// closure is invoked synchronously from that callback — callers should
/// hop to `@MainActor` for any UI work, the same way
/// `TransformsSpikeCoordinator` does for the spike's single hotkey.
///
/// See ADR-022 §4 for the architectural rationale (one tap, N transforms).
public final class TransformsHotkeyRegistry {
    private static let logger = Logger(subsystem: "com.macparakeet", category: "TransformsHotkeyRegistry")

    /// Fired when a registered shortcut's keyDown event is observed.
    /// The argument is the Prompt.ID bound to the shortcut.
    public var onTrigger: ((UUID) -> Void)?

    private struct KeyMatch: Hashable {
        let keyCode: UInt16
        /// Modifier flags, masked to the bits we care about
        /// (Cmd/Option/Control/Shift). Same `relevantModifierBits` mask used
        /// by `HotkeyTrigger` for chord matching elsewhere in the app.
        let modifierBits: UInt64
    }

    private var dispatchTable: [KeyMatch: UUID] = [:]
    private var pressedKeys: Set<UInt16> = []

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<TransformsHotkeyRegistry>?
    private var installedRunLoop: CFRunLoop?

    public init() {}

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let runLoop = installedRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        retainedSelf?.release()
    }

    // MARK: - Public API

    /// Register or update the binding for a Transform. If `shortcut` is nil,
    /// the Transform is unbound (its row stays in the DB; just no hotkey
    /// dispatch). Replaces any existing binding for the same `promptID`.
    public func register(promptID: UUID, shortcut: KeyboardShortcut?) {
        // Drop any prior binding for this prompt.
        unregister(promptID: promptID)
        guard let shortcut else { return }
        let match = KeyMatch(
            keyCode: shortcut.keyCode,
            modifierBits: cgFlags(for: shortcut.modifiers)
        )
        dispatchTable[match] = promptID
    }

    /// Remove any binding for the given Transform.
    public func unregister(promptID: UUID) {
        let staleMatches = dispatchTable.filter { $0.value == promptID }.keys
        for key in staleMatches {
            dispatchTable[key] = nil
        }
    }

    /// Replace the entire binding set in one shot. Useful when the prompt
    /// repository reloads after a save/delete/import.
    public func replaceBindings(_ bindings: [UUID: KeyboardShortcut]) {
        dispatchTable.removeAll(keepingCapacity: true)
        for (promptID, shortcut) in bindings {
            let match = KeyMatch(
                keyCode: shortcut.keyCode,
                modifierBits: cgFlags(for: shortcut.modifiers)
            )
            dispatchTable[match] = promptID
        }
    }

    /// Returns true if no bindings are currently active.
    public var isEmpty: Bool { dispatchTable.isEmpty }

    // MARK: - Tap lifecycle

    /// Install the system-wide event tap. Idempotent; safe to call again if
    /// the tap was previously stopped.
    @discardableResult
    public func start() -> Bool {
        if eventTap != nil {
            stop()
        }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let registry = Unmanaged<TransformsHotkeyRegistry>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                return registry.handleEvent(type: type, event: event)
            },
            userInfo: {
                let retained = Unmanaged.passRetained(self)
                self.retainedSelf = retained
                return retained.toOpaque()
            }()
        ) else {
            retainedSelf?.release()
            retainedSelf = nil
            let isTrusted = AXIsProcessTrusted()
            Self.logger.error(
                "transforms_hotkey_tap_create_failed accessibility_trusted=\(isTrusted, privacy: .public)"
            )
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        installedRunLoop = runLoop
        CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let runLoop = installedRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        retainedSelf?.release()
        retainedSelf = nil
        eventTap = nil
        runLoopSource = nil
        installedRunLoop = nil
        pressedKeys.removeAll(keepingCapacity: true)
    }

    // MARK: - Event handling

    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            pressedKeys.removeAll(keepingCapacity: true)
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifierBits = event.flags.rawValue & HotkeyTrigger.relevantModifierBits

        switch type {
        case .keyDown:
            let match = KeyMatch(keyCode: keyCode, modifierBits: modifierBits)
            guard let promptID = dispatchTable[match] else {
                return Unmanaged.passUnretained(event)
            }
            // Debounce: don't refire while the key is held.
            guard !pressedKeys.contains(keyCode) else { return nil }
            pressedKeys.insert(keyCode)
            onTrigger?(promptID)
            return nil

        case .keyUp:
            // Only swallow the keyUp if its keyDown had been ours.
            let wasPressedByTransform = pressedKeys.remove(keyCode) != nil
            return wasPressedByTransform ? nil : Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Map our NSEvent-compatible modifier bits to CGEventFlags bits. The
    /// raw values are co-designed — `KeyboardShortcut.ModifierFlag`'s raw
    /// values match `NSEvent.ModifierFlags`, which match the high bits of
    /// `CGEventFlags`. So the mapping is identity on the relevant bits;
    /// we just mask down to the bits the event tap reports.
    private func cgFlags(for modifierBits: UInt) -> UInt64 {
        UInt64(modifierBits) & HotkeyTrigger.relevantModifierBits
    }
}

// MARK: - Collision detection

/// Pure functions for validating a candidate Transform shortcut. Lives next
/// to the registry so the editor sheet can call into it without owning a
/// live event tap.
public enum TransformsHotkeyCollision: Equatable, Sendable {
    /// Bare-key bindings are rejected. Every Transform shortcut must include
    /// at least one modifier (Cmd, Option, Control, or Shift) — matches the
    /// "Shortcut must include modifier key…" constraint surfaced by
    /// reference implementations.
    case missingModifier
    /// macOS Opt+letter combos that produce alt-characters (Opt+e, Opt+u,
    /// Opt+i, Opt+n, Opt+`). Stealing these breaks the user's typing of
    /// accented characters across the entire OS.
    case macOSDeadKey
    /// Another Transform already binds this combo.
    case duplicateTransform(otherPromptID: UUID)
    /// Another app-level MacParakeet hotkey conflicts with this combo.
    case reservedHotkey(name: String)

    public var message: String {
        switch self {
        case .missingModifier:
            return "Shortcut must include a modifier key (⌃, ⌥, ⇧, or ⌘)."
        case .macOSDeadKey:
            return "This shortcut produces a special character on Mac (\u{2325} dead-key). Pick another combo."
        case .duplicateTransform:
            return "Another Transform already uses this shortcut."
        case .reservedHotkey(let name):
            return "This shortcut conflicts with \(name)."
        }
    }
}

public struct TransformsHotkeyCollisionChecker {
    public init() {}

    /// Validate a candidate shortcut against the current set of bindings
    /// and known system hotkeys. Returns nil if the shortcut is acceptable,
    /// or a `TransformsHotkeyCollision` describing the first problem found.
    ///
    /// `excludingPromptID` is the prompt being edited — its existing
    /// binding is ignored so re-saving a Transform without changing its
    /// shortcut doesn't read as a duplicate.
    public func check(
        candidate: KeyboardShortcut,
        existing: [UUID: KeyboardShortcut],
        excludingPromptID: UUID?,
        reservedHotkeys: [TransformShortcutReservedHotkey]
    ) -> TransformsHotkeyCollision? {
        guard candidate.hasModifier else { return .missingModifier }
        if candidate.isMacOSDeadKey { return .macOSDeadKey }

        for (otherID, other) in existing {
            if let exclude = excludingPromptID, exclude == otherID { continue }
            if matches(candidate, other) {
                return .duplicateTransform(otherPromptID: otherID)
            }
        }

        let candidateTrigger = candidate.hotkeyTrigger
        for reserved in reservedHotkeys where !reserved.trigger.isDisabled {
            if candidateTrigger.overlaps(with: reserved.trigger) {
                return .reservedHotkey(name: reserved.name)
            }
        }
        return nil
    }

    /// Two shortcuts match if their modifier bits AND their virtual key code
    /// are identical. Display label is for humans only.
    private func matches(_ lhs: KeyboardShortcut, _ rhs: KeyboardShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }
}
