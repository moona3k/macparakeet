import AppKit
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class AppHotkeyCoordinator {
    private let settingsViewModel: SettingsViewModel
    private let onStartDictation: (FnKeyStateMachine.RecordingMode) -> Void
    private let onStopDictation: () -> Void
    private let onCancelDictation: () -> Void
    private let onDiscardRecording: (Bool) -> Void
    private let onReadyForSecondTap: () -> Void
    private let onEscapeWhileIdle: () -> Void
    private let onToggleMeetingRecording: () -> Void
    private let onPrimaryHotkeyManagerChanged: (HotkeyManager?) -> Void
    private let onAnyHotkeyEnabled: () -> Void
    private let onHotkeyUnavailable: () -> Void

    private var hotkeyManager: HotkeyManager?
    private var meetingHotkeyManager: GlobalShortcutManager?

    init(
        settingsViewModel: SettingsViewModel,
        onStartDictation: @escaping (FnKeyStateMachine.RecordingMode) -> Void,
        onStopDictation: @escaping () -> Void,
        onCancelDictation: @escaping () -> Void,
        onDiscardRecording: @escaping (Bool) -> Void,
        onReadyForSecondTap: @escaping () -> Void,
        onEscapeWhileIdle: @escaping () -> Void,
        onToggleMeetingRecording: @escaping () -> Void,
        onPrimaryHotkeyManagerChanged: @escaping (HotkeyManager?) -> Void,
        onAnyHotkeyEnabled: @escaping () -> Void,
        onHotkeyUnavailable: @escaping () -> Void
    ) {
        self.settingsViewModel = settingsViewModel
        self.onStartDictation = onStartDictation
        self.onStopDictation = onStopDictation
        self.onCancelDictation = onCancelDictation
        self.onDiscardRecording = onDiscardRecording
        self.onReadyForSecondTap = onReadyForSecondTap
        self.onEscapeWhileIdle = onEscapeWhileIdle
        self.onToggleMeetingRecording = onToggleMeetingRecording
        self.onPrimaryHotkeyManagerChanged = onPrimaryHotkeyManagerChanged
        self.onAnyHotkeyEnabled = onAnyHotkeyEnabled
        self.onHotkeyUnavailable = onHotkeyUnavailable
    }

    var hotkeyMenuTitle: String {
        Self.menuTitle(for: HotkeyTrigger.current)
    }

    static func menuTitle(for trigger: HotkeyTrigger) -> String {
        if trigger.isDisabled {
            return "Hotkey: Disabled"
        }
        return "Hotkey: \(trigger.displayName) (double-tap / hold)"
    }

    func setupPrimaryHotkey() {
        let trigger = HotkeyTrigger.current
        guard !trigger.isDisabled else {
            hotkeyManager = nil
            onPrimaryHotkeyManagerChanged(nil)
            return
        }

        let manager = HotkeyManager(trigger: trigger)
        manager.onStartRecording = { [weak self] mode in
            self?.onStartDictation(mode)
        }
        manager.onStopRecording = { [weak self] in
            self?.onStopDictation()
        }
        manager.onCancelRecording = { [weak self] in
            self?.onCancelDictation()
        }
        manager.onDiscardRecording = { [weak self] showReadyPill in
            self?.onDiscardRecording(showReadyPill)
        }
        manager.onReadyForSecondTap = { [weak self] in
            self?.onReadyForSecondTap()
        }
        manager.onEscapeWhileIdle = { [weak self] in
            self?.onEscapeWhileIdle()
        }

        if manager.start() {
            hotkeyManager = manager
            onPrimaryHotkeyManagerChanged(manager)
            onAnyHotkeyEnabled()
        } else {
            hotkeyManager = nil
            onPrimaryHotkeyManagerChanged(nil)
            onHotkeyUnavailable()
        }
    }

    func setupMeetingHotkey() {
        let trigger = settingsViewModel.meetingHotkeyTrigger
        guard !trigger.isDisabled else {
            meetingHotkeyManager = nil
            return
        }
        guard trigger != settingsViewModel.hotkeyTrigger else {
            meetingHotkeyManager = nil
            return
        }

        let manager = GlobalShortcutManager(trigger: trigger)
        manager.onTrigger = { [weak self] in
            Task { @MainActor in
                self?.onToggleMeetingRecording()
            }
        }

        if manager.start() {
            meetingHotkeyManager = manager
            onAnyHotkeyEnabled()
        } else {
            meetingHotkeyManager = nil
            onHotkeyUnavailable()
        }
    }

    func refreshAllHotkeys() {
        hotkeyManager?.stop()
        meetingHotkeyManager?.stop()
        hotkeyManager = nil
        meetingHotkeyManager = nil
        onPrimaryHotkeyManagerChanged(nil)
        setupPrimaryHotkey()
        setupMeetingHotkey()
    }

    func refreshMeetingHotkey() {
        meetingHotkeyManager?.stop()
        meetingHotkeyManager = nil
        setupMeetingHotkey()
    }

    func applyMeetingHotkey(to item: NSMenuItem) {
        let trigger = settingsViewModel.meetingHotkeyTrigger
        guard trigger.kind == .chord, let code = trigger.keyCode else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        let keyName = KeyCodeNames.name(for: code).shortSymbol
        item.keyEquivalent = keyName.lowercased()
        var mask: NSEvent.ModifierFlags = []
        for modifier in trigger.chordModifiers ?? [] {
            switch modifier {
            case "command": mask.insert(.command)
            case "shift": mask.insert(.shift)
            case "control": mask.insert(.control)
            case "option": mask.insert(.option)
            default: break
            }
        }
        item.keyEquivalentModifierMask = mask
    }

    func stopAll() {
        hotkeyManager?.stop()
        meetingHotkeyManager?.stop()
        hotkeyManager = nil
        meetingHotkeyManager = nil
        onPrimaryHotkeyManagerChanged(nil)
    }
}
