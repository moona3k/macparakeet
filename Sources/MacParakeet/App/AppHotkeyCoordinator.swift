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
    private let onTriggerFileTranscription: () -> Void
    private let onTriggerYouTubeTranscription: () -> Void
    private let onDictationHotkeyManagersChanged: ([HotkeyManager]) -> Void
    private let onAnyHotkeyEnabled: () -> Void
    private let onHotkeyUnavailable: () -> Void
    private let onHotkeyConflict: (HotkeyTrigger, [HotkeyTrigger]) -> Void

    private var dictationHotkeyManagers: [HotkeyManager] = []
    private var meetingHotkeyManager: GlobalShortcutManager?
    private var fileTranscriptionHotkeyManager: GlobalShortcutManager?
    private var youtubeTranscriptionHotkeyManager: GlobalShortcutManager?

    init(
        settingsViewModel: SettingsViewModel,
        onStartDictation: @escaping (FnKeyStateMachine.RecordingMode) -> Void,
        onStopDictation: @escaping () -> Void,
        onCancelDictation: @escaping () -> Void,
        onDiscardRecording: @escaping (Bool) -> Void,
        onReadyForSecondTap: @escaping () -> Void,
        onEscapeWhileIdle: @escaping () -> Void,
        onToggleMeetingRecording: @escaping () -> Void,
        onTriggerFileTranscription: @escaping () -> Void,
        onTriggerYouTubeTranscription: @escaping () -> Void,
        onDictationHotkeyManagersChanged: @escaping ([HotkeyManager]) -> Void,
        onAnyHotkeyEnabled: @escaping () -> Void,
        onHotkeyUnavailable: @escaping () -> Void,
        onHotkeyConflict: @escaping (HotkeyTrigger, [HotkeyTrigger]) -> Void
    ) {
        self.settingsViewModel = settingsViewModel
        self.onStartDictation = onStartDictation
        self.onStopDictation = onStopDictation
        self.onCancelDictation = onCancelDictation
        self.onDiscardRecording = onDiscardRecording
        self.onReadyForSecondTap = onReadyForSecondTap
        self.onEscapeWhileIdle = onEscapeWhileIdle
        self.onToggleMeetingRecording = onToggleMeetingRecording
        self.onTriggerFileTranscription = onTriggerFileTranscription
        self.onTriggerYouTubeTranscription = onTriggerYouTubeTranscription
        self.onDictationHotkeyManagersChanged = onDictationHotkeyManagersChanged
        self.onAnyHotkeyEnabled = onAnyHotkeyEnabled
        self.onHotkeyUnavailable = onHotkeyUnavailable
        self.onHotkeyConflict = onHotkeyConflict
    }

    var hotkeyMenuTitle: String {
        Self.menuTitle(
            handsFree: settingsViewModel.hotkeyTrigger,
            pushToTalk: settingsViewModel.pushToTalkHotkeyTrigger
        )
    }

    struct DictationHotkeyPlan: Equatable {
        struct Spec: Equatable {
            let trigger: HotkeyTrigger
            let gestureMode: HotkeyGestureController.Mode
        }

        struct Conflict: Equatable {
            let trigger: HotkeyTrigger
            let conflicts: [HotkeyTrigger]
        }

        let specs: [Spec]
        let conflict: Conflict?
    }

    static func menuTitle(for trigger: HotkeyTrigger) -> String {
        menuTitle(handsFree: trigger, pushToTalk: trigger)
    }

    static func menuTitle(handsFree: HotkeyTrigger, pushToTalk: HotkeyTrigger) -> String {
        if handsFree.isDisabled && pushToTalk.isDisabled {
            return "Dictation Shortcuts: Disabled"
        }
        if !handsFree.isDisabled, handsFree == pushToTalk {
            return "Dictation: \(handsFree.displayName) (hold or double-tap)"
        }
        if handsFree.isDisabled {
            return "Push-to-talk: Hold \(pushToTalk.displayName)"
        }
        if pushToTalk.isDisabled {
            return "Hands-free: Double-tap \(handsFree.displayName)"
        }
        return "Dictation: Hold \(pushToTalk.displayName) / Double-tap \(handsFree.displayName)"
    }

    static func dictationHotkeyPlan(
        handsFree handsFreeTrigger: HotkeyTrigger,
        pushToTalk pushToTalkTrigger: HotkeyTrigger
    ) -> DictationHotkeyPlan {
        guard !handsFreeTrigger.isDisabled || !pushToTalkTrigger.isDisabled else {
            return DictationHotkeyPlan(specs: [], conflict: nil)
        }

        if !handsFreeTrigger.isDisabled, !pushToTalkTrigger.isDisabled {
            if handsFreeTrigger == pushToTalkTrigger {
                return DictationHotkeyPlan(
                    specs: [
                        DictationHotkeyPlan.Spec(
                            trigger: handsFreeTrigger,
                            gestureMode: .doubleTapAndHold
                        ),
                    ],
                    conflict: nil
                )
            }

            if handsFreeTrigger.overlaps(with: pushToTalkTrigger) {
                return DictationHotkeyPlan(
                    specs: [
                        DictationHotkeyPlan.Spec(
                            trigger: handsFreeTrigger,
                            gestureMode: .doubleTapOnly
                        ),
                    ],
                    conflict: DictationHotkeyPlan.Conflict(
                        trigger: pushToTalkTrigger,
                        conflicts: [handsFreeTrigger]
                    )
                )
            }
        }

        var specs: [DictationHotkeyPlan.Spec] = []
        if !handsFreeTrigger.isDisabled {
            specs.append(
                DictationHotkeyPlan.Spec(
                    trigger: handsFreeTrigger,
                    gestureMode: .doubleTapOnly
                )
            )
        }
        if !pushToTalkTrigger.isDisabled {
            specs.append(
                DictationHotkeyPlan.Spec(
                    trigger: pushToTalkTrigger,
                    gestureMode: .holdOnly
                )
            )
        }
        return DictationHotkeyPlan(specs: specs, conflict: nil)
    }

    func setupDictationHotkeys() {
        let plan = Self.dictationHotkeyPlan(
            handsFree: settingsViewModel.hotkeyTrigger,
            pushToTalk: settingsViewModel.pushToTalkHotkeyTrigger
        )
        if let conflict = plan.conflict {
            onHotkeyConflict(conflict.trigger, conflict.conflicts)
        }

        let managers = plan.specs.compactMap { spec in
            startDictationHotkey(
                trigger: spec.trigger,
                gestureMode: spec.gestureMode
            )
        }
        dictationHotkeyManagers = managers
        onDictationHotkeyManagersChanged(managers)
    }

    private func stopDictationHotkeys() {
        dictationHotkeyManagers.forEach { $0.stop() }
        dictationHotkeyManagers = []
        onDictationHotkeyManagersChanged([])
    }

    private func startDictationHotkey(
        trigger: HotkeyTrigger,
        gestureMode: HotkeyGestureController.Mode
    ) -> HotkeyManager? {
        guard !trigger.isDisabled else { return nil }

        let manager = HotkeyManager(trigger: trigger, gestureMode: gestureMode)
        manager.onStartRecording = { [weak self, weak manager] mode in
            if let manager {
                self?.suppressOtherDictationHotkeys(activeManager: manager)
            }
            self?.onStartDictation(mode)
        }
        manager.onStopRecording = { [weak self] in
            self?.resetDictationHotkeyGestures()
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
            onAnyHotkeyEnabled()
            return manager
        } else {
            onHotkeyUnavailable()
            return nil
        }
    }

    private func suppressOtherDictationHotkeys(activeManager: HotkeyManager) {
        for manager in dictationHotkeyManagers where manager !== activeManager {
            manager.suppressUntilReset()
        }
    }

    private func resetDictationHotkeyGestures() {
        dictationHotkeyManagers.forEach { $0.resetToIdle() }
    }

    func setupMeetingHotkey() {
        guard AppFeatures.meetingRecordingEnabled else {
            meetingHotkeyManager = nil
            return
        }
        meetingHotkeyManager = startAuxiliaryHotkey(
            trigger: settingsViewModel.meetingHotkeyTrigger,
            conflicts: [
                settingsViewModel.hotkeyTrigger,
                settingsViewModel.pushToTalkHotkeyTrigger,
                settingsViewModel.fileTranscriptionHotkeyTrigger,
                settingsViewModel.youtubeTranscriptionHotkeyTrigger,
            ],
            onTrigger: { [weak self] in
                self?.onToggleMeetingRecording()
            }
        )
    }

    func setupFileTranscriptionHotkey() {
        fileTranscriptionHotkeyManager = startAuxiliaryHotkey(
            trigger: settingsViewModel.fileTranscriptionHotkeyTrigger,
            conflicts: [
                settingsViewModel.hotkeyTrigger,
                settingsViewModel.pushToTalkHotkeyTrigger,
                settingsViewModel.meetingHotkeyTrigger,
                settingsViewModel.youtubeTranscriptionHotkeyTrigger,
            ],
            onTrigger: { [weak self] in
                self?.onTriggerFileTranscription()
            }
        )
    }

    func setupYouTubeTranscriptionHotkey() {
        youtubeTranscriptionHotkeyManager = startAuxiliaryHotkey(
            trigger: settingsViewModel.youtubeTranscriptionHotkeyTrigger,
            conflicts: [
                settingsViewModel.hotkeyTrigger,
                settingsViewModel.pushToTalkHotkeyTrigger,
                settingsViewModel.meetingHotkeyTrigger,
                settingsViewModel.fileTranscriptionHotkeyTrigger,
            ],
            onTrigger: { [weak self] in
                self?.onTriggerYouTubeTranscription()
            }
        )
    }

    /// Shared setup for auxiliary (non-dictation) hotkeys: disabled-check,
    /// conflict-check against all other configured triggers, start via
    /// `GlobalShortcutManager`, and surface the availability callback.
    private func startAuxiliaryHotkey(
        trigger: HotkeyTrigger,
        conflicts: [HotkeyTrigger],
        onTrigger: @escaping @MainActor () -> Void
    ) -> GlobalShortcutManager? {
        guard !trigger.isDisabled else { return nil }
        let overlappingTriggers = Self.uniqueTriggers(
            conflicts.filter { !$0.isDisabled && $0.overlaps(with: trigger) }
        )
        if !overlappingTriggers.isEmpty {
            onHotkeyConflict(trigger, overlappingTriggers)
            return nil
        }

        let manager = GlobalShortcutManager(trigger: trigger)
        manager.onTrigger = {
            Task { @MainActor in
                onTrigger()
            }
        }

        if manager.start() {
            onAnyHotkeyEnabled()
            return manager
        } else {
            onHotkeyUnavailable()
            return nil
        }
    }

    private static func uniqueTriggers(_ triggers: [HotkeyTrigger]) -> [HotkeyTrigger] {
        var unique: [HotkeyTrigger] = []
        for trigger in triggers where !unique.contains(trigger) {
            unique.append(trigger)
        }
        return unique
    }

    func refreshAllHotkeys() {
        stopDictationHotkeys()
        meetingHotkeyManager?.stop()
        fileTranscriptionHotkeyManager?.stop()
        youtubeTranscriptionHotkeyManager?.stop()
        meetingHotkeyManager = nil
        fileTranscriptionHotkeyManager = nil
        youtubeTranscriptionHotkeyManager = nil
        setupDictationHotkeys()
        setupMeetingHotkey()
        setupFileTranscriptionHotkey()
        setupYouTubeTranscriptionHotkey()
    }

    func refreshMeetingHotkey() {
        meetingHotkeyManager?.stop()
        meetingHotkeyManager = nil
        setupMeetingHotkey()
    }

    func refreshFileTranscriptionHotkey() {
        fileTranscriptionHotkeyManager?.stop()
        fileTranscriptionHotkeyManager = nil
        setupFileTranscriptionHotkey()
    }

    func refreshYouTubeTranscriptionHotkey() {
        youtubeTranscriptionHotkeyManager?.stop()
        youtubeTranscriptionHotkeyManager = nil
        setupYouTubeTranscriptionHotkey()
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
        stopDictationHotkeys()
        meetingHotkeyManager?.stop()
        fileTranscriptionHotkeyManager?.stop()
        youtubeTranscriptionHotkeyManager?.stop()
        meetingHotkeyManager = nil
        fileTranscriptionHotkeyManager = nil
        youtubeTranscriptionHotkeyManager = nil
    }
}
