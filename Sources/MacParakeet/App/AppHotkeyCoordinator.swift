import AppKit
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class AppHotkeyCoordinator {
    static let holdToTalkStopTailMs = 200

    private let settingsViewModel: SettingsViewModel
    private let onStartDictation: (FnKeyStateMachine.RecordingMode, Bool?, Bool) -> Bool
    private let onStopDictation: () -> Void
    private let onStopDictationPending: () -> Void
    private let onStopDictationPendingCancelled: () -> Void
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

    private var dictationHotkeyEntries: [(spec: DictationHotkeyPlan.Spec, manager: HotkeyManager)] = []
    private var activeDictationHotkey: DictationHotkeyPlan.Spec?
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
        onStartDictation: @escaping (FnKeyStateMachine.RecordingMode, Bool?, Bool) -> Bool,
        onStopDictation: @escaping () -> Void,
        onStopDictationPending: @escaping () -> Void = {},
        onStopDictationPendingCancelled: @escaping () -> Void = {},
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
        self.onStopDictationPending = onStopDictationPending
        self.onStopDictationPendingCancelled = onStopDictationPendingCancelled
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
            pushToTalk: settingsViewModel.pushToTalkHotkeyTrigger,
            aiPolish: settingsViewModel.dictationAIPolishHotkeyTrigger,
            clipboard: settingsViewModel.dictationClipboardHotkeyTrigger
        )
    }

    struct DictationHotkeyPlan: Equatable {
        struct Spec: Equatable {
            let trigger: HotkeyTrigger
            let gestureMode: HotkeyGestureController.Mode
            let startupDebounceMs: Int
            let holdToTalkStopTailMs: Int
            let aiFormatterEnabled: Bool?
            let clipboardOnly: Bool

            init(
                trigger: HotkeyTrigger,
                gestureMode: HotkeyGestureController.Mode,
                startupDebounceMs: Int = FnKeyStateMachine.defaultStartupDebounceMs,
                holdToTalkStopTailMs: Int = 0,
                aiFormatterEnabled: Bool? = nil,
                clipboardOnly: Bool = false
            ) {
                self.trigger = trigger
                self.gestureMode = gestureMode
                self.startupDebounceMs = startupDebounceMs
                self.holdToTalkStopTailMs = max(0, holdToTalkStopTailMs)
                self.aiFormatterEnabled = aiFormatterEnabled
                self.clipboardOnly = clipboardOnly
            }
        }

        struct Conflict: Equatable {
            let trigger: HotkeyTrigger
            let conflicts: [HotkeyTrigger]
        }

        let specs: [Spec]
        let conflict: Conflict?
    }

    typealias HotkeyConflictCandidate = HotkeyConflictPolicy.Candidate

    static func menuTitle(for trigger: HotkeyTrigger) -> String {
        menuTitle(handsFree: trigger, pushToTalk: trigger)
    }

    static func menuTitle(
        handsFree: HotkeyTrigger,
        pushToTalk: HotkeyTrigger,
        aiPolish: HotkeyTrigger = .disabled,
        clipboard: HotkeyTrigger = .disabled
    ) -> String {
        if handsFree.isDisabled && pushToTalk.isDisabled {
            if !aiPolish.isDisabled && !clipboard.isDisabled {
                return "Dictation: AI polish / Clipboard-only"
            }
            if !aiPolish.isDisabled {
                return "AI polish: Tap \(aiPolish.displayName)"
            }
            if !clipboard.isDisabled {
                return "Clipboard-only: Tap \(clipboard.displayName)"
            }
            return "Dictation Shortcuts: Disabled"
        }
        if HotkeyTrigger.isSharedDictationGesture(handsFree: handsFree, pushToTalk: pushToTalk) {
            return "Dictation: Hold \(pushToTalk.displayName) / Double-tap \(handsFree.displayName)"
        }
        if handsFree.overlaps(with: pushToTalk) {
            let conflictName =
                handsFree == pushToTalk
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
        pushToTalk pushToTalkTrigger: HotkeyTrigger,
        aiPolish aiPolishTrigger: HotkeyTrigger = .disabled,
        clipboard clipboardTrigger: HotkeyTrigger = .disabled
    ) -> DictationHotkeyPlan {
        let base: DictationHotkeyPlan
        if !handsFreeTrigger.isDisabled || !pushToTalkTrigger.isDisabled {
            if HotkeyTrigger.isSharedDictationGesture(
                handsFree: handsFreeTrigger,
                pushToTalk: pushToTalkTrigger
            ) {
                base = DictationHotkeyPlan(
                    specs: [
                        DictationHotkeyPlan.Spec(
                            trigger: handsFreeTrigger,
                            gestureMode: .doubleTapAndHold,
                            holdToTalkStopTailMs: holdToTalkStopTailMs
                        )
                    ],
                    conflict: nil
                )
            } else if !handsFreeTrigger.isDisabled, !pushToTalkTrigger.isDisabled,
                handsFreeTrigger.overlaps(with: pushToTalkTrigger)
            {
                base = DictationHotkeyPlan(
                    specs: [
                        DictationHotkeyPlan.Spec(
                            trigger: handsFreeTrigger,
                            gestureMode: .singleTapToggle
                        )
                    ],
                    conflict: DictationHotkeyPlan.Conflict(
                        trigger: pushToTalkTrigger,
                        conflicts: [handsFreeTrigger]
                    )
                )
            } else {
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
                            ),
                            holdToTalkStopTailMs: holdToTalkStopTailMs
                        )
                    )
                }
                base = DictationHotkeyPlan(specs: specs, conflict: nil)
            }
        } else {
            base = DictationHotkeyPlan(specs: [], conflict: nil)
        }

        let withClipboard = appending(
            DictationHotkeyPlan.Spec(
                trigger: clipboardTrigger,
                gestureMode: .singleTapToggle,
                clipboardOnly: true
            ),
            to: base
        )
        return appending(
            DictationHotkeyPlan.Spec(
                trigger: aiPolishTrigger,
                gestureMode: .singleTapToggle,
                aiFormatterEnabled: true
            ),
            to: withClipboard
        )
    }

    private static func appending(
        _ spec: DictationHotkeyPlan.Spec,
        to plan: DictationHotkeyPlan
    ) -> DictationHotkeyPlan {
        guard !spec.trigger.isDisabled else { return plan }
        let conflicting = plan.specs.map(\.trigger).filter { spec.trigger.overlaps(with: $0) }
        if !conflicting.isEmpty {
            return DictationHotkeyPlan(
                specs: plan.specs,
                conflict: plan.conflict
                    ?? DictationHotkeyPlan.Conflict(
                        trigger: spec.trigger,
                        conflicts: conflicting
                    )
            )
        }
        var specs = plan.specs
        specs.append(spec)
        return DictationHotkeyPlan(specs: specs, conflict: plan.conflict)
    }

    private static func pushToTalkStartupDebounceMs(
        handsFree handsFreeTrigger: HotkeyTrigger,
        pushToTalk pushToTalkTrigger: HotkeyTrigger
    ) -> Int {
        guard pushToTalkTrigger.kind == .modifier,
            pushToTalkTrigger.modifierName == "fn",
            handsFreeTrigger.kind == .chord,
            handsFreeTrigger.chordModifiers?.contains("fn") == true
        else {
            return FnKeyStateMachine.defaultStartupDebounceMs
        }
        return FnKeyStateMachine.defaultTapThresholdMs
    }

    func setupDictationHotkeys() {
        let plan = Self.dictationHotkeyPlan(
            handsFree: settingsViewModel.hotkeyTrigger,
            pushToTalk: settingsViewModel.pushToTalkHotkeyTrigger,
            aiPolish: settingsViewModel.dictationAIPolishHotkeyTrigger,
            clipboard: settingsViewModel.dictationClipboardHotkeyTrigger
        )
        if let conflict = plan.conflict {
            onHotkeyConflict(conflict.trigger, conflict.conflicts)
        }

        let activeRecordingMode = dictationRecordingModeProvider()
        if activeRecordingMode == nil {
            activeDictationHotkey = nil
        }
        let entries: [(spec: DictationHotkeyPlan.Spec, manager: HotkeyManager)] = plan.specs.compactMap { spec in
            let resumeMode = Self.resumeMode(activeRecordingMode, for: spec.gestureMode)
            let shouldResume = Self.shouldResumeDictationHotkey(
                spec,
                activeMode: activeRecordingMode,
                activeHotkey: activeDictationHotkey
            )
            guard
                let manager = startDictationHotkey(
                    spec: spec,
                    resumeMode: shouldResume ? resumeMode : nil,
                    suppressUntilReset: activeRecordingMode != nil && !shouldResume
                )
            else { return nil }
            return (spec: spec, manager: manager)
        }
        dictationHotkeyEntries = entries
        onDictationHotkeyManagersChanged(entries.map { $0.manager })
    }

    private func stopDictationHotkeys() {
        dictationHotkeyEntries.forEach { $0.manager.stop() }
        dictationHotkeyEntries = []
        onDictationHotkeyManagersChanged([])
    }

    private func startDictationHotkey(
        spec: DictationHotkeyPlan.Spec,
        resumeMode: FnKeyStateMachine.RecordingMode? = nil,
        suppressUntilReset: Bool = false
    ) -> HotkeyManager? {
        guard !spec.trigger.isDisabled else { return nil }

        let manager = HotkeyManager(
            trigger: spec.trigger,
            gestureMode: spec.gestureMode,
            startupDebounceMs: spec.startupDebounceMs,
            holdToTalkStopTailMs: spec.holdToTalkStopTailMs
        )
        manager.onStartRecording = { [weak self, weak manager] mode in
            guard let manager else { return }
            guard let self else { manager.resetToIdle(); return }
            self.handleDictationHotkeyStart(manager: manager, spec: spec, mode: mode)
        }
        manager.onStopRecording = { [weak self] in
            self?.activeDictationHotkey = nil
            self?.resetDictationHotkeyGestures()
            self?.onStopDictation()
        }
        manager.onStopPending = { [weak self] in
            self?.onStopDictationPending()
        }
        manager.onStopPendingCancelled = { [weak self] in
            self?.onStopDictationPendingCancelled()
        }
        manager.onCancelRecording = { [weak self] in
            self?.activeDictationHotkey = nil
            self?.onCancelDictation()
        }
        manager.onDiscardRecording = { [weak self] showReadyPill in
            self?.activeDictationHotkey = nil
            self?.onDiscardRecording(showReadyPill)
        }
        manager.onReadyForSecondTap = { [weak self] in
            self?.onReadyForSecondTap()
        }
        manager.onEscapeWhileIdle = { [weak self] in
            self?.onEscapeWhileIdle()
        }
        manager.shouldCancelOnEscape = {
            UserDefaultsAppRuntimePreferences.escapeCancelsDictation()
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

    func handleDictationHotkeyStart(
        manager: HotkeyManager,
        spec: DictationHotkeyPlan.Spec,
        mode: FnKeyStateMachine.RecordingMode
    ) {
        guard onStartDictation(mode, spec.aiFormatterEnabled, spec.clipboardOnly) else {
            // The gesture controller has already entered recording mode.
            // A refused start must leave the next press able to start a take.
            manager.resetToIdle()
            return
        }
        suppressOtherDictationHotkeys(activeManager: manager)
        // A rapid restart can reset the previous take's hotkey state while
        // handling onStartDictation. Record this take's owner afterward.
        activeDictationHotkey = spec
    }

    private func suppressOtherDictationHotkeys(activeManager: HotkeyManager) {
        for entry in dictationHotkeyEntries where entry.manager !== activeManager {
            entry.manager.suppressUntilReset()
        }
    }

    private func resetDictationHotkeyGestures() {
        dictationHotkeyEntries.forEach { $0.manager.resetToIdle() }
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
                .init(settingsViewModel.dictationAIPolishHotkeyTrigger, mode: .bareModifierDictation),
                .init(settingsViewModel.dictationClipboardHotkeyTrigger),
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
                .init(settingsViewModel.dictationAIPolishHotkeyTrigger, mode: .bareModifierDictation),
                .init(settingsViewModel.dictationClipboardHotkeyTrigger),
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
                .init(settingsViewModel.dictationAIPolishHotkeyTrigger, mode: .bareModifierDictation),
                .init(settingsViewModel.dictationClipboardHotkeyTrigger),
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
        HotkeyConflictPolicy.conflictingTriggers(for: trigger, among: conflicts)
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
        HotkeyManager.resumeMode(activeMode, for: gestureMode)
    }

    static func shouldSuppressPeer(
        _ activeMode: FnKeyStateMachine.RecordingMode?,
        for gestureMode: HotkeyGestureController.Mode
    ) -> Bool {
        HotkeyManager.shouldSuppressPeer(activeMode, for: gestureMode)
    }

    static func shouldResumeDictationHotkey(
        _ spec: DictationHotkeyPlan.Spec,
        activeMode: FnKeyStateMachine.RecordingMode?,
        activeHotkey: DictationHotkeyPlan.Spec?
    ) -> Bool {
        guard resumeMode(activeMode, for: spec.gestureMode) != nil else { return false }
        guard let activeHotkey else {
            // Recordings started outside a shortcut keep the existing regular
            // dictation behavior; specialized shortcuts cannot take over it.
            return spec.aiFormatterEnabled != true && !spec.clipboardOnly
        }
        return spec.aiFormatterEnabled == activeHotkey.aiFormatterEnabled
            && spec.clipboardOnly == activeHotkey.clipboardOnly
    }

    func syncDictationHotkeyRecordingMode(_ mode: FnKeyStateMachine.RecordingMode) {
        Self.syncDictationHotkeyManagers(
            dictationHotkeyEntries,
            mode: mode,
            activeHotkey: activeDictationHotkey
        )
    }

    static func syncDictationHotkeyManagers(
        _ entries: [(spec: DictationHotkeyPlan.Spec, manager: HotkeyManager)],
        mode: FnKeyStateMachine.RecordingMode,
        activeHotkey: DictationHotkeyPlan.Spec?
    ) {
        for entry in entries {
            if shouldResumeDictationHotkey(entry.spec, activeMode: mode, activeHotkey: activeHotkey) {
                entry.manager.syncRecordingMode(mode)
            } else {
                entry.manager.suppressUntilReset()
            }
        }
    }

    func clearActiveDictationHotkey() {
        activeDictationHotkey = nil
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
