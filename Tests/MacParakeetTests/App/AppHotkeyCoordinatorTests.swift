import XCTest
import MacParakeetCore
import MacParakeetViewModels
@testable import MacParakeet

@MainActor
final class AppHotkeyCoordinatorTests: XCTestCase {

    private func makeViewModel(functionName: String = #function) -> SettingsViewModel {
        let suiteName = makeIsolatedDefaultsSuite("AppHotkeyCoordinatorTests.\(functionName).")
        let defaults = UserDefaults(suiteName: suiteName)!
        return SettingsViewModel(defaults: defaults)
    }

    private func makeCoordinator(
        settingsViewModel: SettingsViewModel,
        onStartDictation: @escaping (FnKeyStateMachine.RecordingMode, Bool?) -> Bool = { _, _ in true },
        onAnyHotkeyEnabled: @escaping () -> Void = {},
        onHotkeyUnavailable: @escaping () -> Void = {},
        onHotkeyConflict: @escaping (HotkeyTrigger, [HotkeyTrigger]) -> Void
    ) -> AppHotkeyCoordinator {
        AppHotkeyCoordinator(
            settingsViewModel: settingsViewModel,
            onStartDictation: onStartDictation,
            onStopDictation: {},
            onCancelDictation: {},
            onDiscardRecording: { _ in },
            onReadyForSecondTap: {},
            onEscapeWhileIdle: {},
            onToggleMeetingRecording: {},
            onTriggerFileTranscription: {},
            onTriggerYouTubeTranscription: {},
            onDictationHotkeyManagersChanged: { _ in },
            onAnyHotkeyEnabled: onAnyHotkeyEnabled,
            onHotkeyUnavailable: onHotkeyUnavailable,
            onHotkeyConflict: onHotkeyConflict
        )
    }

    private func rightCommandTrigger() -> HotkeyTrigger {
        HotkeyTrigger(
            kind: .modifier,
            modifierName: "command",
            keyCode: nil,
            modifierKeyCode: 54
        )
    }

    func testRefusedDictationStartResetsGestureForNextTap() {
        let coordinator = makeCoordinator(
            settingsViewModel: makeViewModel(),
            onStartDictation: { _, _ in false },
            onHotkeyConflict: { _, _ in }
        )
        let manager = HotkeyManager(trigger: .control, gestureMode: .singleTapToggle)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }
        manager.setPhysicalFlagsProviderForTesting { [] }
        manager.resumeRecording(mode: .persistent)
        let spec = AppHotkeyCoordinator.DictationHotkeyPlan.Spec(
            trigger: .control,
            gestureMode: .singleTapToggle
        )

        coordinator.handleDictationHotkeyStart(manager: manager, spec: spec, mode: .persistent)

        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskControl],
                timestampMs: 1_000
            ), []
        )
        XCTAssertEqual(
            manager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_050
            ), [.startRecording(mode: .persistent)]
        )
    }

    func testSetupFileTranscriptionHotkeyReportsConflictInsteadOfSilentlyDropping() {
        let viewModel = makeViewModel()
        let conflictingTrigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        viewModel.hotkeyTrigger = conflictingTrigger
        viewModel.fileTranscriptionHotkeyTrigger = conflictingTrigger
        var reportedTrigger: HotkeyTrigger?
        var reportedConflicts: [HotkeyTrigger] = []
        var enabledCount = 0
        var unavailableCount = 0

        let coordinator = makeCoordinator(
            settingsViewModel: viewModel,
            onAnyHotkeyEnabled: { enabledCount += 1 },
            onHotkeyUnavailable: { unavailableCount += 1 },
            onHotkeyConflict: { trigger, conflicts in
                reportedTrigger = trigger
                reportedConflicts = conflicts
            }
        )

        coordinator.setupFileTranscriptionHotkey()

        XCTAssertEqual(reportedTrigger, conflictingTrigger)
        XCTAssertEqual(reportedConflicts, [conflictingTrigger])
        XCTAssertEqual(enabledCount, 0)
        XCTAssertEqual(unavailableCount, 0)
    }

    func testMenuTitleDescribesSharedDictationTrigger() {
        XCTAssertEqual(
            AppHotkeyCoordinator.menuTitle(handsFree: .fn, pushToTalk: .fn),
            "Dictation: Hold Fn / Double-tap Fn"
        )
    }

    func testMenuTitleDescribesSharedCustomDictationTrigger() {
        let rightCommand = rightCommandTrigger()

        XCTAssertEqual(
            AppHotkeyCoordinator.menuTitle(handsFree: rightCommand, pushToTalk: rightCommand),
            "Dictation: Hold Right Command / Double-tap Right Command"
        )
    }

    func testMenuTitleDescribesOverlappingDictationTriggers() {
        XCTAssertEqual(
            AppHotkeyCoordinator.menuTitle(
                handsFree: .chord(modifiers: ["control"], keyCode: 49),
                pushToTalk: .control
            ),
            "Dictation Shortcuts: Conflict on Control+Space / Control"
        )
    }

    func testMenuTitleDescribesDistinctDictationTriggers() {
        XCTAssertEqual(
            AppHotkeyCoordinator.menuTitle(handsFree: .control, pushToTalk: .option),
            "Dictation: Hold Option / Tap Control"
        )
    }

    func testMenuTitleDescribesAIPolishWhenOtherDictationShortcutsAreDisabled() {
        XCTAssertEqual(
            AppHotkeyCoordinator.menuTitle(
                handsFree: .disabled,
                pushToTalk: .disabled,
                aiPolish: .control
            ),
            "AI polish: Tap Control"
        )
    }

    func testDictationHotkeyPlanUsesCombinedDefaultGestureForFnPair() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .fn,
            pushToTalk: .fn
        )

        XCTAssertEqual(
            plan,
            AppHotkeyCoordinator.DictationHotkeyPlan(
                specs: [
                    .init(
                        trigger: .fn,
                        gestureMode: .doubleTapAndHold,
                        holdToTalkStopTailMs: AppHotkeyCoordinator.holdToTalkStopTailMs
                    )
                ],
                conflict: nil
            )
        )
    }

    func testDictationHotkeyPlanUsesCombinedGestureForSharedRightCommand() {
        let rightCommand = rightCommandTrigger()
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: rightCommand,
            pushToTalk: rightCommand
        )

        XCTAssertEqual(
            plan,
            AppHotkeyCoordinator.DictationHotkeyPlan(
                specs: [
                    .init(
                        trigger: rightCommand,
                        gestureMode: .doubleTapAndHold,
                        holdToTalkStopTailMs: AppHotkeyCoordinator.holdToTalkStopTailMs
                    )
                ],
                conflict: nil
            )
        )
    }

    func testDictationHotkeyPlanUsesSeparateManagersForDistinctTriggers() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .control,
            pushToTalk: .option
        )

        XCTAssertEqual(
            plan,
            AppHotkeyCoordinator.DictationHotkeyPlan(
                specs: [
                    .init(trigger: .control, gestureMode: .singleTapToggle),
                    .init(
                        trigger: .option,
                        gestureMode: .holdOnly,
                        holdToTalkStopTailMs: AppHotkeyCoordinator.holdToTalkStopTailMs
                    ),
                ],
                conflict: nil
            )
        )
    }

    func testDictationHotkeyPlanUsesCombinedManagerForDefaults() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .defaultDictation,
            pushToTalk: .defaultPushToTalk
        )

        XCTAssertEqual(
            plan,
            AppHotkeyCoordinator.DictationHotkeyPlan(
                specs: [
                    .init(
                        trigger: .defaultDictation,
                        gestureMode: .doubleTapAndHold,
                        holdToTalkStopTailMs: AppHotkeyCoordinator.holdToTalkStopTailMs
                    )
                ],
                conflict: nil
            )
        )
    }

    func testDictationHotkeyPlanKeepsStandardPushToTalkDebounceWhenNoFnChordConflict() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .control,
            pushToTalk: .defaultPushToTalk
        )

        XCTAssertEqual(
            plan.specs.last,
            .init(
                trigger: .defaultPushToTalk,
                gestureMode: .holdOnly,
                startupDebounceMs: FnKeyStateMachine.defaultStartupDebounceMs,
                holdToTalkStopTailMs: AppHotkeyCoordinator.holdToTalkStopTailMs
            )
        )
    }

    func testDictationHotkeyPlanKeepsHandsFreeOnlyWhenTriggersOverlapButDiffer() {
        let pushToTalk = HotkeyTrigger.modifierChord(modifiers: ["control", "option"])
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .control,
            pushToTalk: pushToTalk
        )

        XCTAssertEqual(
            plan,
            AppHotkeyCoordinator.DictationHotkeyPlan(
                specs: [
                    .init(trigger: .control, gestureMode: .singleTapToggle)
                ],
                conflict: .init(trigger: pushToTalk, conflicts: [.control])
            )
        )
    }

    func testDictationHotkeyPlanHandlesDisabledRoles() {
        XCTAssertEqual(
            AppHotkeyCoordinator.dictationHotkeyPlan(
                handsFree: .disabled,
                pushToTalk: .option
            ),
            AppHotkeyCoordinator.DictationHotkeyPlan(
                specs: [
                    .init(
                        trigger: .option,
                        gestureMode: .holdOnly,
                        holdToTalkStopTailMs: AppHotkeyCoordinator.holdToTalkStopTailMs
                    )
                ],
                conflict: nil
            )
        )

        XCTAssertEqual(
            AppHotkeyCoordinator.dictationHotkeyPlan(
                handsFree: .disabled,
                pushToTalk: .disabled
            ),
            AppHotkeyCoordinator.DictationHotkeyPlan(specs: [], conflict: nil)
        )
    }

    func testDictationHotkeyPlanAddsAIPolishAsSeparateTapToggle() {
        let polish = HotkeyTrigger.chord(modifiers: ["control", "option"], keyCode: 35)
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .fn,
            pushToTalk: .fn,
            aiPolish: polish
        )

        XCTAssertEqual(plan.specs.count, 2)
        XCTAssertEqual(plan.specs.last?.trigger, polish)
        XCTAssertEqual(plan.specs.last?.gestureMode, .singleTapToggle)
        XCTAssertEqual(plan.specs.last?.aiFormatterEnabled, true)
        XCTAssertNil(plan.conflict)
    }

    func testDictationHotkeyPlanReportsConflictWhenAIPolishOverlapsHandsFree() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .control,
            pushToTalk: .option,
            aiPolish: .control
        )

        XCTAssertEqual(plan.conflict?.trigger, .control)
        XCTAssertFalse(plan.specs.contains(where: { $0.aiFormatterEnabled == true }))
    }

    func testRebuildResumesOnlyTheShortcutThatStartedAIPolish() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .fn,
            pushToTalk: .fn,
            aiPolish: .control
        )
        let polish = plan.specs.first { $0.aiFormatterEnabled == true }!

        for spec in plan.specs {
            XCTAssertEqual(
                AppHotkeyCoordinator.shouldResumeDictationHotkey(
                    spec,
                    activeMode: .persistent,
                    activeHotkey: polish
                ),
                spec.aiFormatterEnabled == true
            )
        }
    }

    func testRebuildSuppressesAIPolishWhenAnotherShortcutStartedTheTake() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .fn,
            pushToTalk: .fn,
            aiPolish: .control
        )
        let standard = plan.specs.first { $0.aiFormatterEnabled != true }!
        let polish = plan.specs.first { $0.aiFormatterEnabled == true }!

        XCTAssertTrue(
            AppHotkeyCoordinator.shouldResumeDictationHotkey(
                standard,
                activeMode: .persistent,
                activeHotkey: standard
            )
        )
        XCTAssertFalse(
            AppHotkeyCoordinator.shouldResumeDictationHotkey(
                polish,
                activeMode: .persistent,
                activeHotkey: standard
            )
        )
        XCTAssertFalse(
            AppHotkeyCoordinator.shouldResumeDictationHotkey(
                polish,
                activeMode: .persistent,
                activeHotkey: nil
            )
        )
    }

    func testRecordingStartSyncPreservesAIPolishShortcutOwnership() {
        let regularSpec = AppHotkeyCoordinator.DictationHotkeyPlan.Spec(
            trigger: .fn,
            gestureMode: .doubleTapAndHold
        )
        let polishSpec = AppHotkeyCoordinator.DictationHotkeyPlan.Spec(
            trigger: .control,
            gestureMode: .singleTapToggle,
            aiFormatterEnabled: true
        )
        let regularManager = HotkeyManager(trigger: .fn)
        let polishManager = HotkeyManager(trigger: .control, gestureMode: .singleTapToggle)
        regularManager.setPhysicalKeyStateProviderForTesting { _ in false }
        polishManager.setPhysicalKeyStateProviderForTesting { _ in false }

        AppHotkeyCoordinator.syncDictationHotkeyManagers(
            [(spec: regularSpec, manager: regularManager), (spec: polishSpec, manager: polishManager)],
            mode: .persistent,
            activeHotkey: polishSpec
        )

        XCTAssertEqual(
            regularManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskSecondaryFn],
                timestampMs: 1_000
            ),
            []
        )
        XCTAssertEqual(
            polishManager.modifierFlagsChangedOutputsForTesting(
                flags: [.maskControl],
                timestampMs: 1_100
            ),
            []
        )
        XCTAssertEqual(
            polishManager.modifierFlagsChangedOutputsForTesting(
                flags: [],
                timestampMs: 1_150
            ),
            [.stopRecording]
        )
    }

    // MARK: - Suspend / Resume

    func testSuspendAndResumeArePaired() {
        let viewModel = makeViewModel()
        let coordinator = makeCoordinator(
            settingsViewModel: viewModel,
            onHotkeyConflict: { _, _ in }
        )

        XCTAssertEqual(coordinator.suspendCountForTesting, 0)

        coordinator.suspend()
        XCTAssertEqual(coordinator.suspendCountForTesting, 1)

        coordinator.resume()
        XCTAssertEqual(coordinator.suspendCountForTesting, 0)
    }

    func testSuspendNestsAndResumeUnwinds() {
        let viewModel = makeViewModel()
        let coordinator = makeCoordinator(
            settingsViewModel: viewModel,
            onHotkeyConflict: { _, _ in }
        )

        coordinator.suspend()
        coordinator.suspend()
        XCTAssertEqual(coordinator.suspendCountForTesting, 2)

        coordinator.resume()
        XCTAssertEqual(coordinator.suspendCountForTesting, 1)

        coordinator.resume()
        XCTAssertEqual(coordinator.suspendCountForTesting, 0)
    }

    func testResumeWithoutSuspendIsNoop() {
        let viewModel = makeViewModel()
        let coordinator = makeCoordinator(
            settingsViewModel: viewModel,
            onHotkeyConflict: { _, _ in }
        )

        coordinator.resume()
        coordinator.resume()
        XCTAssertEqual(coordinator.suspendCountForTesting, 0)
    }

    func testRefreshAllHotkeysIsSkippedWhileSuspended() {
        // The SettingsViewModel observer in AppDelegate calls
        // refreshAllHotkeys / refreshMeetingHotkey when the user records a
        // new trigger. That call would race resume() and double-restart the
        // taps — guarded by `suspendCount == 0`. This test pins both halves:
        // refresh* short-circuits during suspension (no conflict reports
        // appear), and resume() actually rebuilds from current settings
        // (the same conflict is reported exactly once after resume).
        let viewModel = makeViewModel()
        var conflictReports = 0
        let coordinator = makeCoordinator(
            settingsViewModel: viewModel,
            onHotkeyConflict: { _, _ in conflictReports += 1 }
        )

        viewModel.meetingHotkeyTrigger = .defaultMeetingRecording
        viewModel.pushToTalkHotkeyTrigger = .defaultMeetingRecording

        coordinator.suspend()
        coordinator.refreshAllHotkeys()
        coordinator.refreshMeetingHotkey()
        coordinator.refreshFileTranscriptionHotkey()
        coordinator.refreshYouTubeTranscriptionHotkey()
        XCTAssertEqual(conflictReports, 0, "refresh* must short-circuit while suspended")

        coordinator.resume()
        XCTAssertEqual(conflictReports, 1, "resume() must rebuild taps from current settings")
    }

    func testAuxiliaryHotkeysCanShareChordsWithBareModifierDictationTriggers() {
        let rightCommand = HotkeyTrigger(
            kind: .modifier,
            modifierName: "command",
            keyCode: nil,
            modifierKeyCode: 54
        )

        XCTAssertEqual(
            AppHotkeyCoordinator.conflictingTriggers(
                for: .defaultMeetingRecording,
                among: [
                    .init(rightCommand, mode: .bareModifierDictation)
                ]
            ),
            []
        )
        XCTAssertEqual(
            AppHotkeyCoordinator.conflictingTriggers(
                for: .defaultMeetingRecording,
                among: [
                    .init(rightCommand)
                ]
            ),
            [rightCommand]
        )
    }

    func testSetupAllHotkeysIsDeferredWhileSuspended() {
        let viewModel = makeViewModel()
        let conflictingTrigger = HotkeyTrigger.modifierChord(modifiers: ["command", "option"])
        viewModel.hotkeyTrigger = .disabled
        viewModel.pushToTalkHotkeyTrigger = .disabled
        viewModel.meetingHotkeyTrigger = .disabled
        viewModel.fileTranscriptionHotkeyTrigger = conflictingTrigger
        viewModel.youtubeTranscriptionHotkeyTrigger = conflictingTrigger
        var conflictReports = 0
        let coordinator = makeCoordinator(
            settingsViewModel: viewModel,
            onHotkeyConflict: { _, _ in conflictReports += 1 }
        )

        coordinator.suspend()
        coordinator.setupAllHotkeys()
        XCTAssertEqual(conflictReports, 0)

        coordinator.resume()
        XCTAssertEqual(conflictReports, 2)
    }

    func testResumeModeMatchesActiveDictationRole() {
        XCTAssertEqual(
            AppHotkeyCoordinator.resumeMode(.persistent, for: .singleTapToggle),
            .persistent
        )
        XCTAssertFalse(AppHotkeyCoordinator.shouldSuppressPeer(.persistent, for: .singleTapToggle))
        XCTAssertEqual(
            AppHotkeyCoordinator.resumeMode(.persistent, for: .doubleTapOnly),
            .persistent
        )
        XCTAssertFalse(AppHotkeyCoordinator.shouldSuppressPeer(.persistent, for: .doubleTapOnly))
        XCTAssertEqual(
            AppHotkeyCoordinator.resumeMode(.persistent, for: .doubleTapAndHold),
            .persistent
        )
        XCTAssertFalse(AppHotkeyCoordinator.shouldSuppressPeer(.persistent, for: .doubleTapAndHold))
        XCTAssertNil(AppHotkeyCoordinator.resumeMode(.persistent, for: .holdOnly))
        XCTAssertTrue(AppHotkeyCoordinator.shouldSuppressPeer(.persistent, for: .holdOnly))

        XCTAssertEqual(
            AppHotkeyCoordinator.resumeMode(.holdToTalk, for: .holdOnly),
            .holdToTalk
        )
        XCTAssertFalse(AppHotkeyCoordinator.shouldSuppressPeer(.holdToTalk, for: .holdOnly))
        XCTAssertEqual(
            AppHotkeyCoordinator.resumeMode(.holdToTalk, for: .doubleTapAndHold),
            .holdToTalk
        )
        XCTAssertFalse(AppHotkeyCoordinator.shouldSuppressPeer(.holdToTalk, for: .doubleTapAndHold))
        XCTAssertNil(AppHotkeyCoordinator.resumeMode(.holdToTalk, for: .singleTapToggle))
        XCTAssertTrue(AppHotkeyCoordinator.shouldSuppressPeer(.holdToTalk, for: .singleTapToggle))
        XCTAssertNil(AppHotkeyCoordinator.resumeMode(.holdToTalk, for: .doubleTapOnly))
        XCTAssertTrue(AppHotkeyCoordinator.shouldSuppressPeer(.holdToTalk, for: .doubleTapOnly))
        XCTAssertNil(AppHotkeyCoordinator.resumeMode(nil, for: .doubleTapAndHold))
        XCTAssertFalse(AppHotkeyCoordinator.shouldSuppressPeer(nil, for: .doubleTapAndHold))
    }
    func testAdditionalPairPlansTwoCombinedManagersForFnAndDelete() {
        let key = HotkeyTrigger.fromKeyCode(117)
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .fn, pushToTalk: .fn, alternateHandsFree: key, alternatePushToTalk: key)
        XCTAssertNil(plan.conflict)
        XCTAssertEqual(plan.specs.map(\.trigger), [.fn, key])
        XCTAssertEqual(plan.specs.map(\.gestureMode), [.doubleTapAndHold, .doubleTapAndHold])
        XCTAssertTrue(plan.specs.allSatisfy { $0.holdToTalkStopTailMs == 200
})
    }

    func testAdditionalPairSupportsSeparateModesAndDisabledPrimaries() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .disabled, pushToTalk: .disabled, alternateHandsFree: .control, alternatePushToTalk: .option)
        XCTAssertNil(plan.conflict)
        XCTAssertEqual(plan.specs.map(\.gestureMode), [.singleTapToggle, .holdOnly])
    }

    func testAdditionalShortcutCannotRegisterDuplicateOfPrimaryOrPolish() {
        for key in [HotkeyTrigger.fn, .control] {
            let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
                handsFree: .fn, pushToTalk: .fn, aiPolish: .control, alternateHandsFree: key)
            XCTAssertEqual(plan.specs.count, 2)
            XCTAssertEqual(plan.conflict?.trigger, key)
        }
    }

    func testHoldRecordingSyncKeepsAdditionalTriggerSuppressed() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .control, pushToTalk: .control, alternateHandsFree: .option, alternatePushToTalk: .option)
        let owner = plan.specs[0]
        let peer = plan.specs[1]
        let manager = HotkeyManager(trigger: peer.trigger, gestureMode: peer.gestureMode)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }
        manager.setPhysicalFlagsProviderForTesting { [] }
        AppHotkeyCoordinator.syncDictationHotkeyManagers([(peer, manager)], mode: .holdToTalk, activeHotkey: owner)
        XCTAssertEqual(manager.modifierFlagsChangedOutputsForTesting(flags: [.maskAlternate], timestampMs: 1000), [])
        XCTAssertEqual(manager.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 1100), [])
        XCTAssertFalse(
            AppHotkeyCoordinator.shouldResumeDictationHotkey(peer, activeMode: .holdToTalk, activeHotkey: owner))
        XCTAssertTrue(
            AppHotkeyCoordinator.shouldResumeDictationHotkey(owner, activeMode: .holdToTalk, activeHotkey: owner))
    }

    func testHandsFreeRecordingCanStopFromAdditionalShortcutAfterSync() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .control, pushToTalk: .control, alternateHandsFree: .option, alternatePushToTalk: .option)
        let peer = plan.specs[1]
        let manager = HotkeyManager(trigger: peer.trigger, gestureMode: peer.gestureMode)
        manager.setPhysicalKeyStateProviderForTesting { _ in false }
        manager.setPhysicalFlagsProviderForTesting { [] }
        manager.suppressUntilReset()
        AppHotkeyCoordinator.syncDictationHotkeyManagers(
            [(peer, manager)], mode: .persistent, activeHotkey: plan.specs[0])
        let down = manager.modifierFlagsChangedOutputsForTesting(flags: [.maskAlternate], timestampMs: 1000)
        let up = manager.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 1050)
        XCTAssertEqual((down + up).filter { $0 == .stopRecording }.count, 1)
    }

    func testAuxiliaryRegistrationReservesAdditionalShortcut() {
        let vm = makeViewModel()
        vm.alternatePushToTalkHotkeyTrigger = .fromKeyCode(117)
        vm.fileTranscriptionHotkeyTrigger = vm.alternatePushToTalkHotkeyTrigger
        var conflicts: [HotkeyTrigger] = []
        let coordinator = makeCoordinator(settingsViewModel: vm, onHotkeyConflict: { _, peers in conflicts = peers })
        coordinator.setupFileTranscriptionHotkey()
        XCTAssertEqual(conflicts, [vm.alternatePushToTalkHotkeyTrigger])
    }

    func testOneEscapeDispatchesOneCancellationAcrossManagersInEitherOrder() {
        for reverse in [false, true] {
            let coordinator = makeCoordinator(settingsViewModel: makeViewModel(), onHotkeyConflict: { _, _ in })
            let owner = HotkeyManager(trigger: .control, gestureMode: .doubleTapAndHold)
            let peer = HotkeyManager(trigger: .option, gestureMode: .doubleTapAndHold)
            let managers = reverse ? [peer, owner] : [owner, peer]
            for manager in managers {
                manager.setPhysicalKeyStateProviderForTesting { _ in false }
                manager.setPhysicalFlagsProviderForTesting { [] }
            }
            coordinator.configureEscapeHandling(managers, preferred: owner)
            owner.resumeRecording(mode: .persistent)
            peer.resumeRecording(mode: .persistent)
            var cancellationCount = 0
            for press in 1...2 {
                for manager in managers {
                    let outputs = manager.modifierKeyDownOutputsForTesting(
                        keyCode: 53, timestampMs: UInt64(press * 1000))
                    if outputs.contains(.cancelRecording) {
                        cancellationCount += 1
                        // The real flow clears active ownership and synchronously
                        // puts every manager into the Undo/cancel window.
                        coordinator.clearActiveDictationHotkey()
                        managers.forEach { $0.notifyCancelledByUI() }
                    }
                    XCTAssertFalse(outputs.contains(.escapeWhileIdle))
                }
                XCTAssertEqual(cancellationCount, press, "One press must not skip the Undo window")
                guard press == 1 else { continue }
                for (manager, flag) in [(owner, CGEventFlags.maskControl), (peer, .maskAlternate)] {
                    XCTAssertEqual(
                        manager.modifierFlagsChangedOutputsForTesting(flags: flag, timestampMs: 1_100), [],
                        "A trigger pressed during the Undo window must stay blocked (reverse: \(reverse))")
                    XCTAssertEqual(manager.startupDebounceElapsedForTesting(), [])
                    XCTAssertFalse(
                        manager.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 1_200)
                            .contains(.startRecording(mode: .holdToTalk)))
                }
            }
        }
    }

    private func installDictationManagers(
        in coordinator: AppHotkeyCoordinator,
        plan: AppHotkeyCoordinator.DictationHotkeyPlan
    ) -> [HotkeyManager] {
        let managers = plan.specs.map { spec -> HotkeyManager in
            let manager = coordinator.makeDictationHotkeyManager(spec: spec)
            manager.setPhysicalKeyStateProviderForTesting { _ in false }
            manager.setPhysicalFlagsProviderForTesting { [] }
            return manager
        }
        coordinator.setDictationHotkeyEntriesForTesting(
            zip(plan.specs, managers).map { (spec: $0, manager: $1) })
        coordinator.configureEscapeHandling(managers)
        return managers
    }

    private func deliver(_ outputs: [HotkeyGestureController.Output], to manager: HotkeyManager) {
        for output in outputs {
            switch output {
            case .startRecording(let mode): manager.onStartRecording?(mode)
            case .discardRecording(let showReadyPill): manager.onDiscardRecording?(showReadyPill)
            default: break
            }
        }
    }

    private func startProvisionalTake(on manager: HotkeyManager, flags: CGEventFlags) {
        _ = manager.modifierFlagsChangedOutputsForTesting(flags: flags, timestampMs: 1_000)
        let started = manager.startupDebounceElapsedForTesting()
        XCTAssertEqual(started, [.startRecording(mode: .holdToTalk)])
        deliver(started, to: manager)
    }

    func testDiscardedProvisionalTakeLeavesTheOtherShortcutAbleToStart() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .control, pushToTalk: .control, alternateHandsFree: .option, alternatePushToTalk: .option)
        let flags: [CGEventFlags] = [.maskControl, .maskAlternate]
        for tappedIndex in [0, 1] {
            for typingInterrupts in [false, true] {
                let coordinator = makeCoordinator(settingsViewModel: makeViewModel(), onHotkeyConflict: { _, _ in })
                let managers = installDictationManagers(in: coordinator, plan: plan)
                let tapped = managers[tappedIndex]
                let other = managers[1 - tappedIndex]
                startProvisionalTake(on: tapped, flags: flags[tappedIndex])

                let discard =
                    typingInterrupts
                    ? tapped.modifierKeyDownOutputsForTesting(keyCode: 0, timestampMs: 1_150)
                    : tapped.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 1_150)
                XCTAssertTrue(
                    discard.contains { if case .discardRecording = $0 { true } else { false } },
                    "typingInterrupts: \(typingInterrupts)")
                deliver(discard, to: tapped)

                let pressed = other.modifierFlagsChangedOutputsForTesting(
                    flags: flags[1 - tappedIndex], timestampMs: 3_000)
                XCTAssertFalse(pressed.isEmpty, "tapped: \(tappedIndex) typingInterrupts: \(typingInterrupts)")
                XCTAssertEqual(
                    other.startupDebounceElapsedForTesting(), [.startRecording(mode: .holdToTalk)],
                    "tapped: \(tappedIndex) typingInterrupts: \(typingInterrupts)")
            }
        }
    }

    func testDiscardedProvisionalTakeKeepsTheOwnersSecondTapWindow() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .control, pushToTalk: .control, alternateHandsFree: .option, alternatePushToTalk: .option)
        let coordinator = makeCoordinator(settingsViewModel: makeViewModel(), onHotkeyConflict: { _, _ in })
        let managers = installDictationManagers(in: coordinator, plan: plan)
        startProvisionalTake(on: managers[0], flags: .maskControl)
        deliver(managers[0].modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 1_150), to: managers[0])

        XCTAssertEqual(
            managers[0].modifierFlagsChangedOutputsForTesting(flags: .maskControl, timestampMs: 1_300),
            [.startRecording(mode: .persistent)])
    }

    func testHoldOwnershipSurvivesChangingSharedTriggerToHoldOnly() {
        let old = AppHotkeyCoordinator.DictationHotkeyPlan.Spec(trigger: .fn, gestureMode: .doubleTapAndHold)
        let replacement = AppHotkeyCoordinator.DictationHotkeyPlan.Spec(trigger: .fn, gestureMode: .holdOnly)
        XCTAssertTrue(
            AppHotkeyCoordinator.shouldResumeDictationHotkey(replacement, activeMode: .holdToTalk, activeHotkey: old))
    }

    func testEscapeClearsPendingGestureOnNonDispatchingManager() {
        let manager = HotkeyManager(trigger: .option, gestureMode: .holdOnly)
        manager.shouldDispatchEscape = { false }
        manager.setPhysicalKeyStateProviderForTesting { _ in false }
        manager.setPhysicalFlagsProviderForTesting { [] }
        _ = manager.modifierFlagsChangedOutputsForTesting(flags: [.maskAlternate], timestampMs: 1000)
        let outputs = manager.modifierKeyDownOutputsForTesting(keyCode: 53, timestampMs: 1050)
        XCTAssertTrue(outputs.contains(.cancelStartupDebounce))
        XCTAssertFalse(outputs.contains(.cancelRecording))
        XCTAssertEqual(manager.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 1100), [.cancelStartupDebounce, .cancelHoldWindow])
    }

    func testMenuStartedPersistentRecordingSelectsAnEligibleEscapeDispatcher() {
        let coordinator = makeCoordinator(settingsViewModel: makeViewModel(), onHotkeyConflict: { _, _ in })
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(handsFree: .disabled, pushToTalk: .fn, alternateHandsFree: .option)
        let managers = plan.specs.map { HotkeyManager(trigger: $0.trigger, gestureMode: $0.gestureMode) }
        let entries = Array(zip(plan.specs, managers)).map { (spec: $0.0, manager: $0.1) }
        let dispatcher = AppHotkeyCoordinator.syncDictationHotkeyManagers(entries, mode: .persistent, activeHotkey: nil)
        XCTAssertTrue(dispatcher === managers[1])
        coordinator.configureEscapeHandling(managers, preferred: dispatcher)
        let outputs = managers.flatMap { $0.modifierKeyDownOutputsForTesting(keyCode: 53, timestampMs: 1000) }
        XCTAssertEqual(outputs.filter { $0 == .cancelRecording }.count, 1)
    }

}
