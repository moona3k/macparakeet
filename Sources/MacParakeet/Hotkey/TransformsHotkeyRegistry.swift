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
/// **Threading.** The CGEvent tap callback runs on `EventTapThread`, never
/// the main run loop, so a UI stall cannot delay other apps' keystrokes
/// (#1142). `onTrigger` is invoked synchronously from that callback — callers
/// should hop to `@MainActor` for any UI work (as `TransformsCoordinator`
/// does). Bindings are edited from the main thread under `bindingsLock`.
///
/// The tap is installed only while at least one binding exists: an empty
/// filtering tap would still make every keystroke wait on this process.
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

    private let bindingsLock = NSLock()
    /// Guarded by `bindingsLock`.
    private var dispatchTable: [KeyMatch: UUID] = [:]
    /// Tap thread only (or while no tap is running).
    private var pressedKeys: Set<UInt16> = []

    /// Main thread only.
    private var backgroundTap: BackgroundEventTap?
    /// True between `start()` and `stop()`: the owner wants shortcuts live.
    private var isStarted = false

    public init() {}

    deinit {
        backgroundTap?.stop()
    }

    // MARK: - Public API

    /// Register or update the binding for a Transform. If `shortcut` is nil,
    /// the Transform is unbound (its row stays in the DB; just no hotkey
    /// dispatch). Replaces any existing binding for the same `promptID`.
    public func register(promptID: UUID, shortcut: KeyboardShortcut?) {
        withBindings { table in
            // Drop any prior binding for this prompt.
            Self.removeBindings(for: promptID, from: &table)
            guard let shortcut else { return }
            table[Self.match(for: shortcut)] = promptID
        }
    }

    /// Remove any binding for the given Transform.
    public func unregister(promptID: UUID) {
        withBindings { table in
            Self.removeBindings(for: promptID, from: &table)
        }
    }

    /// Replace the entire binding set in one shot. Useful when the prompt
    /// repository reloads after a save/delete/import.
    public func replaceBindings(_ bindings: [UUID: KeyboardShortcut]) {
        withBindings { table in
            table.removeAll(keepingCapacity: true)
            for (promptID, shortcut) in bindings {
                table[Self.match(for: shortcut)] = promptID
            }
        }
    }

    /// Returns true if no bindings are currently active.
    public var isEmpty: Bool {
        bindingsLock.withLock { dispatchTable.isEmpty }
    }

    /// True while a system-wide tap is installed.
    public var isTapInstalled: Bool { backgroundTap != nil }

    private func withBindings(_ edit: (inout [KeyMatch: UUID]) -> Void) {
        bindingsLock.withLock { edit(&dispatchTable) }
        updateTapInstallation()
    }

    private static func removeBindings(for promptID: UUID, from table: inout [KeyMatch: UUID]) {
        for key in table.filter({ $0.value == promptID }).keys {
            table[key] = nil
        }
    }

    private static func match(for shortcut: KeyboardShortcut) -> KeyMatch {
        KeyMatch(keyCode: shortcut.keyCode, modifierBits: cgFlags(for: shortcut.modifiers))
    }

    // MARK: - Tap lifecycle

    /// Enable shortcut dispatch. The tap itself is installed only while a
    /// binding exists. Returns false when a needed tap could not be created.
    @discardableResult
    public func start() -> Bool {
        isStarted = true
        return updateTapInstallation()
    }

    public func stop() {
        isStarted = false
        updateTapInstallation()
    }

    /// Installs or removes the tap to match `isStarted` and the bindings.
    @discardableResult
    private func updateTapInstallation() -> Bool {
        let wantsTap = isStarted && !isEmpty
        if !wantsTap {
            // Returns only after the tap thread has stopped calling back.
            backgroundTap?.stop()
            backgroundTap = nil
            pressedKeys.removeAll(keepingCapacity: true)
            return true
        }
        guard backgroundTap == nil else { return true }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        guard let tap = BackgroundEventTap.start(
            options: .defaultTap,
            eventsOfInterest: eventMask,
            handler: { [weak self] type, event in
                guard let self else { return Unmanaged.passUnretained(event) }
                return self.handleEvent(type: type, event: event)
            }
        ) else {
            let isTrusted = AXIsProcessTrusted()
            Self.logger.error(
                "transforms_hotkey_tap_create_failed accessibility_trusted=\(isTrusted, privacy: .public)"
            )
            return false
        }
        backgroundTap = tap
        return true
    }

    var runLoopSourceForTesting: CFRunLoopSource? {
        backgroundTap?.runLoopSourceForTesting
    }

    // MARK: - Event handling

    /// Runs on the tap thread.
    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // `BackgroundEventTap` already re-enabled the tap.
            pressedKeys.removeAll(keepingCapacity: true)
            return Unmanaged.passUnretained(event)
        }

        if StreamingCursorEventMarker.isMarked(event) {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifierBits = event.flags.rawValue & HotkeyTrigger.relevantModifierBits

        switch type {
        case .keyDown:
            let match = KeyMatch(keyCode: keyCode, modifierBits: modifierBits)
            guard let promptID = bindingsLock.withLock({ dispatchTable[match] }) else {
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
    private static func cgFlags(for modifierBits: UInt) -> UInt64 {
        UInt64(modifierBits) & HotkeyTrigger.relevantModifierBits
    }
}
