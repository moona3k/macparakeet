import Cocoa
import Foundation
import MacParakeetCore

/// Lightweight global shortcut listener for immediate actions like toggling
/// meeting recording. Unlike `HotkeyManager`, this does not model hold or
/// double-tap gestures.
public final class GlobalShortcutManager {
    public var onTrigger: (() -> Void)?

    private let trigger: HotkeyTrigger
    private let targetMask: CGEventFlags?
    private let requiredChordFlags: UInt64
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedSelf: Unmanaged<GlobalShortcutManager>?
    private var installedRunLoop: CFRunLoop?
    private var targetModifierWasPressed = false
    private var triggerKeyIsPressed = false

    public init(trigger: HotkeyTrigger) {
        self.trigger = trigger
        self.targetMask = trigger.kind == .modifier ? Self.mask(for: trigger) : nil
        self.requiredChordFlags = trigger.chordEventFlags
    }

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let runLoop = installedRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        retainedSelf?.release()
    }

    public func start() -> Bool {
        if eventTap != nil {
            stop()
        }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(type: type, event: event)
            },
            userInfo: {
                let retained = Unmanaged.passRetained(self)
                self.retainedSelf = retained
                return retained.toOpaque()
            }()
        ) else {
            retainedSelf?.release()
            retainedSelf = nil
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
        targetModifierWasPressed = false
        triggerKeyIsPressed = false
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        switch trigger.kind {
        case .modifier:
            return handleModifierEvent(type: type, event: event)
        case .keyCode:
            return handleKeyCodeEvent(type: type, event: event)
        case .chord:
            return handleChordEvent(type: type, event: event)
        }
    }

    private func handleModifierEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged, let mask = targetMask else {
            return Unmanaged.passUnretained(event)
        }

        let isPressed = event.flags.contains(mask)
        if isPressed != targetModifierWasPressed {
            targetModifierWasPressed = isPressed
            if isPressed {
                onTrigger?()
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyCodeEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let triggerCode = trigger.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            guard keyCode == triggerCode else { return Unmanaged.passUnretained(event) }
            guard !triggerKeyIsPressed else { return nil }
            triggerKeyIsPressed = true
            onTrigger?()
            return nil
        case .keyUp:
            guard keyCode == triggerCode else { return Unmanaged.passUnretained(event) }
            triggerKeyIsPressed = false
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleChordEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let triggerCode = trigger.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shouldSwallow = handleChordEvent(
            type: type,
            triggerCode: triggerCode,
            keyCode: keyCode,
            flags: event.flags.rawValue & HotkeyTrigger.relevantModifierBits
        )
        return shouldSwallow ? nil : Unmanaged.passUnretained(event)
    }

    @discardableResult
    private func handleChordEvent(
        type: CGEventType,
        triggerCode: UInt16,
        keyCode: UInt16,
        flags: UInt64
    ) -> Bool {
        switch type {
        case .keyDown:
            guard keyCode == triggerCode else { return false }
            guard flags == requiredChordFlags else { return false }
            guard !triggerKeyIsPressed else { return true }
            triggerKeyIsPressed = true
            onTrigger?()
            return true
        case .keyUp:
            guard keyCode == triggerCode else { return false }
            guard triggerKeyIsPressed else { return false }
            triggerKeyIsPressed = false
            return true
        default:
            return false
        }
    }

    @discardableResult
    func handleChordEventForTesting(
        type: CGEventType,
        keyCode: UInt16,
        flags: UInt64
    ) -> Bool {
        guard let triggerCode = trigger.keyCode else { return false }
        return handleChordEvent(
            type: type,
            triggerCode: triggerCode,
            keyCode: keyCode,
            flags: flags & HotkeyTrigger.relevantModifierBits
        )
    }

    private static func mask(for trigger: HotkeyTrigger) -> CGEventFlags? {
        guard trigger.kind == .modifier, let name = trigger.modifierName else { return nil }
        switch name {
        case "fn": return .maskSecondaryFn
        case "control": return .maskControl
        case "option": return .maskAlternate
        case "shift": return .maskShift
        case "command": return .maskCommand
        default: return nil
        }
    }
}
