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
    private let dictationRecordingModeProvider: () -> FnKeyStateMachine.RecordingMode?

    private var dictationHotkeyManagers: [HotkeyManager] = []
    private var meetingHotkeyManager: GlobalShortcutManager?
    private var fileTranscriptionHotkeyManager: GlobalShortcutManager?
    private var youtubeTranscriptionHotkeyManager: GlobalShortcutManager?
    /// Count of active `HotkeyRecorderView` sessions that have asked for the
    /// global CGEvent taps to stand down so the recorder can capture the
    /// user's keyDown. Reaches > 1 only across pathological re-entry — the
    /// counter exists so balanced suspend/resume calls never desync the
    /// underlying taps.
    private var suspendCount = 0

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
        onHotkeyConflict: @escaping (HotkeyTrigger, [HotkeyTrigger]) -> Void,
        dictationRecordingModeProvider: @escaping () -> FnKeyStateMachine.RecordingMode? = { nil }
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
        self.dictationRecordingModeProvider = dictationRecordingModeProvider
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
            let startupDebounceMs: Int

            init(
                trigger: HotkeyTrigger,
                gestureMode: HotkeyGestureController.Mode,
                startupDebounceMs: Int = FnKeyStateMachine.defaultStartupDebounceMs
            ) {
                self.trigger = trigger
                self.gestureMode = gestureMode
                self.startupDebounceMs = startupDebounceMs
            }
        }

        struct Conflict: Equatable {
            let trigger: HotkeyTrigger
            let conflicts: [HotkeyTrigger]
        }

        let specs: [Spec]
        let conflict: Conflict?
    }

    struct HotkeyConflictCandidate: Equatable {
        let trigger: HotkeyTrigger
        let mode: HotkeyTrigger.ConflictMode

        init(_ trigger: HotkeyTrigger, mode: HotkeyTrigger.ConflictMode = .exclusive) {
            self.trigger = trigger
            self.mode = mode
        }
    }

    static func menuTitle(for trigger: HotkeyTrigger) -> String {
        menuTitle(handsFree: trigger, pushToTalk: trigger)
    }

    static func menuTitle(handsFree: HotkeyTrigger, pushToTalk: HotkeyTrigger) -> String {
        if handsFree.isDisabled && pushToTalk.isDisabled {
            return "Dictation Shortcuts: Disabled"
        }
        if HotkeyTrigger.isSharedDictationGesture(handsFree: handsFree, pushToTalk: pushToTalk) {
            return "Dictation: Hold \(pushToTalk.displayName) / Double-tap \(handsFree.displayName)"
        }
        if handsFree.overlaps(with: pushToTalk) {
            let conflictName = handsFree == pushToTalk
                ? handsFree.displayName
                : "\(handsFree.displayName) / \(pushToTalk.displayName)"
            return "Dictation Shortcuts: Conflict on \(conflictName)"
        }
        if handsFree.isDisabled {
            return "Push-to-talk: Hold \(pushToTalk.displayName)"
        }
        if pushToTalk.isDisabled {
            return "Hands-free: Tap \(handsFree.displayName)"
        }
        return "Dictation: Hold \(pushToTalk.displayName) / Tap \(handsFree.displayName)"
    }

    static func dictationHotkeyPlan(
        handsFree handsFreeTrigger: HotkeyTrigger,
        pushToTalk pushToTalkTrigger: HotkeyTrigger
    ) -> DictationHotkeyPlan {
        guard !handsFreeTrigger.isDisabled || !pushToTalkTrigger.isDisabled else {
            return DictationHotkeyPlan(specs: [], conflict: nil)
        }

        if HotkeyTrigger.isSharedDictationGesture(
            handsFree: handsFreeTrigger,
            pushToTalk: pushToTalkTrigger
        ) {
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

        if !handsFreeTrigger.isDisabled, !pushToTalkTrigger.isDisabled {
            if handsFreeTrigger.overlaps(with: pushToTalkTrigger) {
                return DictationHotkeyPlan(
                    specs: [
                        DictationHotkeyPlan.Spec(
                            trigger: handsFreeTrigger,
                            gestureMode: .singleTapToggle
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
                    gestureMode: .singleTapToggle
                )
            )
        }
        if !pushToTalkTrigger.isDisabled {
            specs.append(
                DictationHotkeyPlan.Spec(
                    trigger: pushToTalkTrigger,
                    gestureMode: .holdOnly,
                    startupDebounceMs: pushToTalkStartupDebounceMs(
                        handsFree: handsFreeTrigger,
                        pushToTalk: pushToTalkTrigger
                    )
                )
            )
        }
        return DictationHotkeyPlan(specs: specs, conflict: nil)
    }

    private static func pushToTalkStartupDebounceMs(
        handsFree handsFreeTrigger: HotkeyTrigger,
        pushToTalk pushToTalkTrigger: HotkeyTrigger
    ) -> Int {
        guard pushToTalkTrigger.kind == .modifier,
              pushToTalkTrigger.modifierName == "fn",
              handsFreeTrigger.kind == .chord,
              handsFreeTrigger.chordModifiers?.contains("fn") == true else {
            return FnKeyStateMachine.defaultStartupDebounceMs
        }
        return FnKeyStateMachine.defaultTapThresholdMs
    }

    func setupDictationHotkeys() {
        let plan = Self.dictationHotkeyPlan(
            handsFree: settingsViewModel.hotkeyTrigger,
            pushToTalk: settingsViewModel.pushToTalkHotkeyTrigger
        )
        if let conflict = plan.conflict {
            onHotkeyConflict(conflict.trigger, conflict.conflicts)
        }

        let activeRecordingMode = dictationRecordingModeProvider()
        let managers = plan.specs.compactMap { spec in
            startDictationHotkey(
                trigger: spec.trigger,
                gestureMode: spec.gestureMode,
                startupDebounceMs: spec.startupDebounceMs,
                resumeMode: Self.resumeMode(activeRecordingMode, for: spec.gestureMode),
                suppressUntilReset: Self.shouldSuppressPeer(activeRecordingMode, for: spec.gestureMode)
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
        gestureMode: HotkeyGestureController.Mode,
        startupDebounceMs: Int = FnKeyStateMachine.defaultStartupDebounceMs,
        resumeMode: FnKeyStateMachine.RecordingMode? = nil,
        suppressUntilReset: Bool = false
    ) -> HotkeyManager? {
        guard !trigger.isDisabled else { return nil }

        let manager = HotkeyManager(
            trigger: trigger,
            gestureMode: gestureMode,
            startupDebounceMs: startupDebounceMs
        )
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
        if let resumeMode {
            manager.resumeRecording(mode: resumeMode)
        }

        if manager.start() {
            if suppressUntilReset {
                manager.suppressUntilReset()
            }
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
                .init(settingsViewModel.hotkeyTrigger, mode: .bareModifierDictation),
                .init(settingsViewModel.pushToTalkHotkeyTrigger, mode: .bareModifierDictation),
                .init(settingsViewModel.fileTranscriptionHotkeyTrigger),
                .init(settingsViewModel.youtubeTranscriptionHotkeyTrigger),
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
                .init(settingsViewModel.hotkeyTrigger, mode: .bareModifierDictation),
                .init(settingsViewModel.pushToTalkHotkeyTrigger, mode: .bareModifierDictation),
                .init(settingsViewModel.meetingHotkeyTrigger),
                .init(settingsViewModel.youtubeTranscriptionHotkeyTrigger),
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
                .init(settingsViewModel.hotkeyTrigger, mode: .bareModifierDictation),
                .init(settingsViewModel.pushToTalkHotkeyTrigger, mode: .bareModifierDictation),
                .init(settingsViewModel.meetingHotkeyTrigger),
                .init(settingsViewModel.fileTranscriptionHotkeyTrigger),
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
        conflicts: [HotkeyConflictCandidate],
        onTrigger: @escaping @MainActor () -> Void
    ) -> GlobalShortcutManager? {
        guard !trigger.isDisabled else { return nil }
        let overlappingTriggers = Self.uniqueTriggers(
            Self.conflictingTriggers(for: trigger, among: conflicts)
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

    static func conflictingTriggers(
        for trigger: HotkeyTrigger,
        among conflicts: [HotkeyConflictCandidate]
    ) -> [HotkeyTrigger] {
        conflicts.compactMap { conflict in
            guard !conflict.trigger.isDisabled,
                  trigger.conflicts(with: conflict.trigger, otherMode: conflict.mode) else {
                return nil
            }
            return conflict.trigger
        }
    }

    private static func uniqueTriggers(_ triggers: [HotkeyTrigger]) -> [HotkeyTrigger] {
        var unique: [HotkeyTrigger] = []
        for trigger in triggers where !unique.contains(trigger) {
            unique.append(trigger)
        }
        return unique
    }

    static func resumeMode(
        _ activeMode: FnKeyStateMachine.RecordingMode?,
        for gestureMode: HotkeyGestureController.Mode
    ) -> FnKeyStateMachine.RecordingMode? {
        guard let activeMode else { return nil }
        switch (activeMode, gestureMode) {
        case (.persistent, .singleTapToggle),
             (.persistent, .doubleTapOnly),
             (.persistent, .doubleTapAndHold),
             (.holdToTalk, .holdOnly),
             (.holdToTalk, .doubleTapAndHold):
            return activeMode
        case (.persistent, .holdOnly),
             (.holdToTalk, .singleTapToggle),
             (.holdToTalk, .doubleTapOnly):
            return nil
        }
    }

    static func shouldSuppressPeer(
        _ activeMode: FnKeyStateMachine.RecordingMode?,
        for gestureMode: HotkeyGestureController.Mode
    ) -> Bool {
        guard activeMode != nil else { return false }
        return resumeMode(activeMode, for: gestureMode) == nil
    }

    func refreshAllHotkeys() {
        // While a recorder is active, the SettingsViewModel observer can race
        // us — skip and rely on `resume()` to rebuild from current settings.
        guard suspendCount == 0 else { return }
        stopAll()
        setupAllHotkeys()
    }

    func refreshMeetingHotkey() {
        guard suspendCount == 0 else { return }
        meetingHotkeyManager?.stop()
        meetingHotkeyManager = nil
        setupMeetingHotkey()
    }

    func refreshFileTranscriptionHotkey() {
        guard suspendCount == 0 else { return }
        fileTranscriptionHotkeyManager?.stop()
        fileTranscriptionHotkeyManager = nil
        setupFileTranscriptionHotkey()
    }

    func refreshYouTubeTranscriptionHotkey() {
        guard suspendCount == 0 else { return }
        youtubeTranscriptionHotkeyManager?.stop()
        youtubeTranscriptionHotkeyManager = nil
        setupYouTubeTranscriptionHotkey()
    }

    // MARK: - Suspend / Resume

    /// Stand down every global hotkey CGEvent tap while a hotkey recorder UI
    /// is capturing keystrokes. Without this, the head-of-tap chord and
    /// key-code handlers swallow the keyDown the user is trying to record,
    /// silently fire their own actions (e.g. start a meeting recording mid-
    /// Settings), and leave the recorder to commit a wrong modifier-chord on
    /// release. Pair every call with `resume()`.
    func suspend() {
        suspendCount += 1
        if suspendCount == 1 {
            stopAll()
        }
    }

    /// Re-arm every global hotkey CGEvent tap after recording finishes,
    /// reading current values from `settingsViewModel` so a freshly-recorded
    /// trigger comes online immediately.
    func resume() {
        guard suspendCount > 0 else { return }
        suspendCount -= 1
        if suspendCount == 0 {
            setupAllHotkeys()
        }
    }

    func setupAllHotkeys() {
        guard suspendCount == 0 else { return }
        setupDictationHotkeys()
        setupMeetingHotkey()
        setupFileTranscriptionHotkey()
        setupYouTubeTranscriptionHotkey()
    }

    /// Test-only inspection. Exists so the suspend/resume refcount can be
    /// asserted without exposing the storage to production callers.
    var suspendCountForTesting: Int { suspendCount }

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
