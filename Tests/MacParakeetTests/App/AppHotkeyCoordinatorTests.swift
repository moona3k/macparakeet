import IOKit.hidsystem
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

    func testBareFnWaitsOutTheTapThresholdWhenAnyAcceptedShortcutIsAnFnChord() {
        let fnPolish = HotkeyTrigger.chord(modifiers: ["fn"], keyCode: 35)
        let cases: [(name: String, plan: AppHotkeyCoordinator.DictationHotkeyPlan, mode: HotkeyGestureController.Mode)] = [
            (
                "shared Fn primary, Fn chord additional",
                AppHotkeyCoordinator.dictationHotkeyPlan(
                    handsFree: .fn, pushToTalk: .fn, alternateHandsFree: .fnSpace),
                .doubleTapAndHold
            ),
            (
                "Fn chord primary, shared Fn additional",
                AppHotkeyCoordinator.dictationHotkeyPlan(
                    handsFree: .fnSpace, pushToTalk: .disabled, alternateHandsFree: .fn, alternatePushToTalk: .fn),
                .doubleTapAndHold
            ),
            (
                "Fn push-to-talk primary, Fn chord additional",
                AppHotkeyCoordinator.dictationHotkeyPlan(
                    handsFree: .disabled, pushToTalk: .fn, alternateHandsFree: .fnSpace),
                .holdOnly
            ),
            (
                "Fn chord primary, Fn push-to-talk additional",
                AppHotkeyCoordinator.dictationHotkeyPlan(
                    handsFree: .fnSpace, pushToTalk: .disabled, alternatePushToTalk: .fn),
                .holdOnly
            ),
            (
                "Fn chord and Fn push-to-talk in the same additional pair",
                AppHotkeyCoordinator.dictationHotkeyPlan(
                    handsFree: .control, pushToTalk: .control, alternateHandsFree: .fnSpace, alternatePushToTalk: .fn),
                .holdOnly
            ),
            (
                "shared Fn primary, Fn chord AI polish",
                AppHotkeyCoordinator.dictationHotkeyPlan(handsFree: .fn, pushToTalk: .fn, aiPolish: fnPolish),
                .doubleTapAndHold
            ),
        ]

        for testCase in cases {
            let fnSpecs = testCase.plan.specs.filter { $0.trigger == .fn }
            XCTAssertEqual(fnSpecs.count, 1, testCase.name)
            XCTAssertEqual(fnSpecs.first?.gestureMode, testCase.mode, testCase.name)
            XCTAssertEqual(
                fnSpecs.first?.startupDebounceMs, FnKeyStateMachine.defaultTapThresholdMs, testCase.name)
            XCTAssertTrue(
                testCase.plan.specs.contains { $0.trigger == .fnSpace || $0.trigger.chordModifiers == ["fn"] },
                "The Fn chord must be an accepted shortcut: \(testCase.name)")
            XCTAssertNil(testCase.plan.conflict, testCase.name)
        }
    }

    func testBareFnKeepsStandardDebounceWithoutAnAcceptedFnChord() {
        let plans = [
            AppHotkeyCoordinator.dictationHotkeyPlan(
                handsFree: .fn, pushToTalk: .fn, alternateHandsFree: .chord(modifiers: ["control"], keyCode: 49)),
            AppHotkeyCoordinator.dictationHotkeyPlan(handsFree: .control, pushToTalk: .fn, alternateHandsFree: .option),
            // Bare Fn that only toggles on release cannot beat a chord to the start.
            AppHotkeyCoordinator.dictationHotkeyPlan(
                handsFree: .fn, pushToTalk: .disabled, alternateHandsFree: .fnSpace),
        ]
        for plan in plans {
            for spec in plan.specs where spec.trigger == .fn {
                XCTAssertEqual(spec.startupDebounceMs, FnKeyStateMachine.defaultStartupDebounceMs)
            }
        }
    }

    func testBareFnDoesNotStartBeforeAnFnChordOnTheOtherPair() {
        let plans = [
            AppHotkeyCoordinator.dictationHotkeyPlan(
                handsFree: .fn, pushToTalk: .fn, alternateHandsFree: .fnSpace),
            AppHotkeyCoordinator.dictationHotkeyPlan(
                handsFree: .disabled, pushToTalk: .fn, alternateHandsFree: .fnSpace),
            AppHotkeyCoordinator.dictationHotkeyPlan(
                handsFree: .fnSpace, pushToTalk: .disabled, alternateHandsFree: .fn, alternatePushToTalk: .fn),
        ]
        for plan in plans {
            let coordinator = makeCoordinator(settingsViewModel: makeViewModel(), onHotkeyConflict: { _, _ in })
            let managers = installDictationManagers(in: coordinator, plan: plan)
            let fnManager = managers[plan.specs.firstIndex { $0.trigger == .fn }!]

            let pressed = fnManager.modifierFlagsChangedOutputsForTesting(flags: [.maskSecondaryFn], timestampMs: 1_000)
            XCTAssertTrue(
                pressed.contains(.scheduleStartupDebounce(milliseconds: FnKeyStateMachine.defaultTapThresholdMs)),
                "\(pressed)")
            // The Space half of Fn+Space arrives well inside the old 100 ms debounce.
            let interrupted = fnManager.modifierKeyDownOutputsForTesting(keyCode: 49, timestampMs: 1_200)
            XCTAssertTrue(interrupted.contains(.cancelStartupDebounce), "\(interrupted)")
            XCTAssertEqual(fnManager.startupDebounceElapsedForTesting(), [])
        }
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

    func testAdditionalChordOnAnotherPairsTerminalKeyIsReportedAsAConflict() {
        let commandK = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 40)
        let optionK = HotkeyTrigger.chord(modifiers: ["option"], keyCode: 40)
        let shared = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: commandK, pushToTalk: commandK, alternateHandsFree: optionK, alternatePushToTalk: optionK)
        XCTAssertEqual(shared.specs.map(\.trigger), [commandK], "The primary shortcut keeps its tap")
        XCTAssertEqual(shared.conflict?.trigger, optionK)
        XCTAssertEqual(shared.conflict?.conflicts, [commandK])

        let withPolish = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .disabled, pushToTalk: .disabled, aiPolish: commandK, alternateHandsFree: optionK)
        XCTAssertEqual(withPolish.specs.map(\.trigger), [commandK])
        XCTAssertEqual(withPolish.conflict?.trigger, optionK)
    }

    func testChordsOnOneTerminalKeyStillCoexistWithinTheLongStandingPrimaryPlan() {
        let commandK = HotkeyTrigger.chord(modifiers: ["command"], keyCode: 40)
        let optionK = HotkeyTrigger.chord(modifiers: ["option"], keyCode: 40)
        let primary = AppHotkeyCoordinator.dictationHotkeyPlan(handsFree: commandK, pushToTalk: optionK)
        XCTAssertNil(primary.conflict)
        XCTAssertEqual(primary.specs.map(\.trigger), [commandK, optionK])

        let additionalPair = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .disabled, pushToTalk: .disabled, alternateHandsFree: commandK, alternatePushToTalk: optionK)
        XCTAssertNil(additionalPair.conflict)
        XCTAssertEqual(additionalPair.specs.map(\.trigger), [commandK, optionK])

        let polish = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: commandK, pushToTalk: commandK, aiPolish: optionK)
        XCTAssertNil(polish.conflict)
        XCTAssertEqual(polish.specs.map(\.trigger), [commandK, optionK])
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
            let manager = coordinator.makeDictationHotkeyManager(spec: spec, in: plan)
            manager.setPhysicalKeyStateProviderForTesting { _ in false }
            manager.setPhysicalFlagsProviderForTesting { [] }
            // Coordinator-built managers read the host's Escape preference.
            manager.shouldCancelOnEscape = { true }
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

    func testHandsFreeTakeStopsOnceFromEitherShortcutThroughCoordinatorStart() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .control, pushToTalk: .control, alternateHandsFree: .option, alternatePushToTalk: .option)
        let flags: [CGEventFlags] = [.maskControl, .maskAlternate]
        for starterIndex in [0, 1] {
            for stopperIndex in [0, 1] {
                let coordinator = makeCoordinator(settingsViewModel: makeViewModel(), onHotkeyConflict: { _, _ in })
                let managers = installDictationManagers(in: coordinator, plan: plan)
                let starter = managers[starterIndex]
                let stopper = managers[stopperIndex]

                _ = starter.modifierFlagsChangedOutputsForTesting(flags: flags[starterIndex], timestampMs: 1_000)
                _ = starter.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 1_050)
                let started = starter.modifierFlagsChangedOutputsForTesting(
                    flags: flags[starterIndex], timestampMs: 1_200)
                XCTAssertEqual(started, [.startRecording(mode: .persistent)])
                deliver(started, to: starter)
                // The flow reports the persistent take back to the coordinator.
                coordinator.syncDictationHotkeyRecordingMode(.persistent)
                _ = starter.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 1_250)

                let down = stopper.modifierFlagsChangedOutputsForTesting(flags: flags[stopperIndex], timestampMs: 5_000)
                let up = stopper.modifierFlagsChangedOutputsForTesting(flags: [], timestampMs: 5_050)
                XCTAssertEqual(
                    (down + up).filter { $0 == .stopRecording }.count, 1,
                    "starter: \(starterIndex) stopper: \(stopperIndex)")
            }
        }
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

    // MARK: - Peer shortcut input during a held take

    /// What the dictation flow would see from the managers' callbacks.
    private final class FlowRecorder {
        var starts = 0
        var pendingStops = 0
        var cancels = 0
        var discards = 0
        var killedTakes: Int { cancels + discards }
    }

    /// One physical event as every event tap receives it: combined global flags.
    private struct PhysicalEvent {
        let type: CGEventType
        let keyCode: UInt16
        let flags: CGEventFlags

        static func modifier(_ keyCode: UInt16, _ flags: CGEventFlags) -> PhysicalEvent {
            PhysicalEvent(type: .flagsChanged, keyCode: keyCode, flags: flags)
        }

        static func down(_ keyCode: UInt16, _ flags: CGEventFlags = []) -> PhysicalEvent {
            PhysicalEvent(type: .keyDown, keyCode: keyCode, flags: flags)
        }

        static func up(_ keyCode: UInt16, _ flags: CGEventFlags = []) -> PhysicalEvent {
            PhysicalEvent(type: .keyUp, keyCode: keyCode, flags: flags)
        }
    }

    private static func device(_ mask: Int32) -> CGEventFlags {
        CGEventFlags(rawValue: UInt64(mask))
    }

    private static let ctrl: CGEventFlags = .maskControl
    private static let opt: CGEventFlags = .maskAlternate
    private static let shift: CGEventFlags = .maskShift
    private static let fn: CGEventFlags = .maskSecondaryFn
    private static let ctrlOpt: CGEventFlags = [.maskControl, .maskAlternate]
    private static let leftControl = device(NX_DEVICELCTLKEYMASK)
    private static let leftOption = device(NX_DEVICELALTKEYMASK)
    private static let rightOption = device(NX_DEVICERALTKEYMASK)
    private static let rightCommand = device(NX_DEVICERCMDKEYMASK)

    private static let rightOptionTrigger = HotkeyTrigger(
        kind: .modifier, modifierName: "option", keyCode: nil, modifierKeyCode: 61)
    private static let rightCommandTrigger = HotkeyTrigger(
        kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 54)
    private static let leftCommandTrigger = HotkeyTrigger(
        kind: .modifier, modifierName: "command", keyCode: nil, modifierKeyCode: 55)
    private static let leftCommand = device(NX_DEVICELCMDKEYMASK)

    /// A shortcut pair where `owner` holds a take and the user then presses and
    /// releases the `peer` shortcut, as the taps see it.
    private struct PeerScenario {
        let name: String
        let owner: HotkeyTrigger
        let peer: HotkeyTrigger
        let ownerPress: [PhysicalEvent]
        let peerInput: [PhysicalEvent]
        let ownerRelease: [PhysicalEvent]
        /// AI polish is a third accepted shortcut, so it is a peer too.
        var aiPolish: HotkeyTrigger = .disabled
    }

    private enum TakeVariant: CaseIterable {
        /// Shared hold/double-tap shortcut, held less than the tap threshold.
        case provisional
        /// Shared hold/double-tap shortcut, held past the tap threshold.
        case confirmed
        /// Push-to-talk only shortcut.
        case pushToTalkOnly
    }

    private static let peerScenarios: [PeerScenario] = [
        PeerScenario(
            name: "Control owner, Option peer",
            owner: .control, peer: .option,
            ownerPress: [.modifier(59, ctrl)],
            peerInput: [.modifier(58, ctrlOpt), .modifier(58, ctrl)],
            ownerRelease: [.modifier(59, [])]),
        PeerScenario(
            name: "Option owner, Control peer",
            owner: .option, peer: .control,
            ownerPress: [.modifier(58, opt)],
            peerInput: [.modifier(59, ctrlOpt), .modifier(59, opt)],
            ownerRelease: [.modifier(58, [])]),
        PeerScenario(
            name: "Owner released while the peer is still held",
            owner: .control, peer: .option,
            ownerPress: [.modifier(59, ctrl)],
            peerInput: [.modifier(58, ctrlOpt)],
            ownerRelease: [.modifier(59, opt), .modifier(58, [])]),
        PeerScenario(
            name: "Fn owner, standalone key peer",
            owner: .fn, peer: .fromKeyCode(117),
            ownerPress: [.modifier(63, fn)],
            peerInput: [.down(117, fn), .down(117, fn), .up(117, fn)],
            ownerRelease: [.modifier(63, [])]),
        PeerScenario(
            name: "Fn owner, modifier-first peer chord released modifier first",
            owner: .fn, peer: .chord(modifiers: ["option"], keyCode: 119),
            ownerPress: [.modifier(63, fn)],
            peerInput: [
                .modifier(58, [fn, opt]), .down(119, [fn, opt]), .modifier(58, fn), .up(119, fn),
            ],
            ownerRelease: [.modifier(63, [])]),
        PeerScenario(
            name: "Control owner, modifier-first peer chord released key first",
            owner: .control, peer: .chord(modifiers: ["option"], keyCode: 119),
            ownerPress: [.modifier(59, ctrl)],
            peerInput: [
                .modifier(58, ctrlOpt), .down(119, ctrlOpt), .up(119, ctrlOpt), .modifier(58, ctrl),
            ],
            ownerRelease: [.modifier(59, [])]),
        PeerScenario(
            name: "Control owner, peer chord keyUp after its modifier released",
            owner: .control, peer: .chord(modifiers: ["option"], keyCode: 119),
            ownerPress: [.modifier(59, ctrl)],
            peerInput: [
                .modifier(58, ctrlOpt), .down(119, ctrlOpt), .modifier(58, ctrl), .up(119, ctrl),
            ],
            ownerRelease: [.modifier(59, [])]),
        PeerScenario(
            name: "Modifier-chord owner, Option peer",
            owner: .modifierChord(modifiers: ["control", "shift"]), peer: .option,
            ownerPress: [.modifier(59, ctrl), .modifier(56, [ctrl, shift])],
            peerInput: [.modifier(58, [ctrl, shift, opt]), .modifier(58, [ctrl, shift])],
            ownerRelease: [.modifier(56, ctrl), .modifier(59, [])]),
        PeerScenario(
            name: "Modifier-chord owner, standalone key peer",
            owner: .modifierChord(modifiers: ["control", "shift"]), peer: .fromKeyCode(105),
            ownerPress: [.modifier(59, ctrl), .modifier(56, [ctrl, shift])],
            peerInput: [.down(105, [ctrl, shift]), .up(105, [ctrl, shift])],
            ownerRelease: [.modifier(56, ctrl), .modifier(59, [])]),
        PeerScenario(
            name: "Control owner, AI-polish peer",
            owner: .control, peer: .fromKeyCode(117),
            ownerPress: [.modifier(59, ctrl)],
            peerInput: [.modifier(56, [ctrl, shift]), .modifier(56, ctrl)],
            ownerRelease: [.modifier(59, [])],
            aiPolish: .shift),
        PeerScenario(
            name: "Control owner, side-specific peer",
            owner: .control, peer: rightOptionTrigger,
            ownerPress: [.modifier(59, [ctrl, leftControl])],
            peerInput: [
                .modifier(61, [ctrl, leftControl, opt, rightOption]),
                .modifier(61, [ctrl, leftControl]),
            ],
            ownerRelease: [.modifier(59, [])]),
        PeerScenario(
            name: "Control owner, side-specific peer reporting only the generic flag",
            owner: .control, peer: rightOptionTrigger,
            ownerPress: [.modifier(59, ctrl)],
            peerInput: [.modifier(61, ctrlOpt), .modifier(61, ctrl)],
            ownerRelease: [.modifier(59, [])]),
        PeerScenario(
            name: "Modifier-chord owner, side-specific peer reporting only the generic flag",
            owner: .modifierChord(modifiers: ["control", "shift"]), peer: rightOptionTrigger,
            ownerPress: [.modifier(59, ctrl), .modifier(56, [ctrl, shift])],
            peerInput: [.modifier(61, [ctrl, shift, opt]), .modifier(61, [ctrl, shift])],
            ownerRelease: [.modifier(56, ctrl), .modifier(59, [])]),
        PeerScenario(
            name: "Side-specific owner, Option peer",
            owner: rightCommandTrigger, peer: .option,
            ownerPress: [.modifier(54, [.maskCommand, rightCommand])],
            peerInput: [
                .modifier(58, [.maskCommand, rightCommand, opt, leftOption]),
                .modifier(58, [.maskCommand, rightCommand]),
            ],
            ownerRelease: [.modifier(54, [])]),
        PeerScenario(
            name: "Key owner, standalone key peer",
            owner: .fromKeyCode(105), peer: .fromKeyCode(117),
            ownerPress: [.down(105)],
            peerInput: [.down(117), .up(117)],
            ownerRelease: [.up(105)]),
        PeerScenario(
            name: "Key owner, Fn peer",
            owner: .fromKeyCode(105), peer: .fn,
            ownerPress: [.down(105)],
            peerInput: [.modifier(63, fn), .modifier(63, []), .down(179)],
            ownerRelease: [.up(105)]),
        PeerScenario(
            name: "Chord owner, standalone key peer",
            owner: .chord(modifiers: ["control", "option"], keyCode: 20), peer: .fromKeyCode(105),
            ownerPress: [.modifier(59, ctrl), .modifier(58, ctrlOpt), .down(20, ctrlOpt)],
            peerInput: [.down(105, ctrlOpt), .up(105, ctrlOpt)],
            ownerRelease: [.up(20, ctrlOpt)]),
    ]

    @MainActor
    private final class PeerRig {
        /// Managers hold their coordinator weakly.
        let coordinator: AppHotkeyCoordinator
        let recorder: FlowRecorder
        let managers: [HotkeyManager]
        let owner: HotkeyManager
        let scenario: PeerScenario
        let variant: TakeVariant
        let reverse: Bool
        private var clockMs: UInt64 = 1_000

        init(
            coordinator: AppHotkeyCoordinator,
            recorder: FlowRecorder,
            managers: [HotkeyManager],
            owner: HotkeyManager,
            scenario: PeerScenario,
            variant: TakeVariant,
            reverse: Bool
        ) {
            self.coordinator = coordinator
            self.recorder = recorder
            self.managers = managers
            self.owner = owner
            self.scenario = scenario
            self.variant = variant
            self.reverse = reverse
        }

        var label: String { "\(scenario.name) [\(variant), reverse: \(reverse)]" }

        /// Delivers each event to every manager, as separate taps would.
        func send(_ events: [PhysicalEvent]) {
            for event in events {
                clockMs += 25
                for manager in reverse ? managers.reversed() : managers {
                    manager.processForTesting(
                        type: event.type, keyCode: event.keyCode, flags: event.flags, timestampMs: clockMs)
                }
            }
        }

        /// Presses the owner and lets its startup debounce elapse.
        func startHeldTake() {
            send(scenario.ownerPress)
            let started = owner.startupDebounceElapsedForTesting()
            XCTAssertEqual(started, [.startRecording(mode: .holdToTalk)], label)
            owner.onStartRecording?(.holdToTalk)
            if variant == .confirmed { _ = owner.holdWindowElapsedForTesting() }
        }

        func releaseOwnerAfterTapThreshold() {
            clockMs += 500
            send(scenario.ownerRelease)
        }
    }

    private func makePeerRig(
        viewModel: SettingsViewModel,
        scenario: PeerScenario,
        ownerIsPrimary: Bool,
        variant: TakeVariant,
        reverse: Bool
    ) -> PeerRig {
        let recorder = FlowRecorder()
        let coordinator = AppHotkeyCoordinator(
            settingsViewModel: viewModel,
            onStartDictation: { _, _ in
                recorder.starts += 1
                return true
            },
            onStopDictation: {},
            onStopDictationPending: { recorder.pendingStops += 1 },
            onCancelDictation: { recorder.cancels += 1 },
            onDiscardRecording: { _ in recorder.discards += 1 },
            onReadyForSecondTap: {},
            onEscapeWhileIdle: {},
            onToggleMeetingRecording: {},
            onTriggerFileTranscription: {},
            onTriggerYouTubeTranscription: {},
            onDictationHotkeyManagersChanged: { _ in },
            onAnyHotkeyEnabled: {},
            onHotkeyUnavailable: {},
            onHotkeyConflict: { _, _ in }
        )
        let ownerHandsFree: HotkeyTrigger = variant == .pushToTalkOnly ? .disabled : scenario.owner
        let plan =
            ownerIsPrimary
            ? AppHotkeyCoordinator.dictationHotkeyPlan(
                handsFree: ownerHandsFree, pushToTalk: scenario.owner, aiPolish: scenario.aiPolish,
                alternateHandsFree: scenario.peer, alternatePushToTalk: scenario.peer)
            : AppHotkeyCoordinator.dictationHotkeyPlan(
                handsFree: scenario.peer, pushToTalk: scenario.peer, aiPolish: scenario.aiPolish,
                alternateHandsFree: ownerHandsFree, alternatePushToTalk: scenario.owner)
        XCTAssertNil(plan.conflict, scenario.name)
        XCTAssertEqual(plan.specs.count, scenario.aiPolish.isDisabled ? 2 : 3, scenario.name)
        let managers = installDictationManagers(in: coordinator, plan: plan)
        let ownerIndex = plan.specs.firstIndex { $0.trigger == scenario.owner } ?? 0
        return PeerRig(
            coordinator: coordinator, recorder: recorder, managers: managers, owner: managers[ownerIndex],
            scenario: scenario, variant: variant, reverse: reverse)
    }

    /// Runs `body` for every pair position, delivery order and take variant.
    private func forEachPeerRig(
        _ scenarios: [PeerScenario],
        variants: [TakeVariant] = TakeVariant.allCases,
        body: (PeerRig) -> Void
    ) {
        let viewModel = makeViewModel()
        for scenario in scenarios {
            for variant in variants {
                for ownerIsPrimary in [true, false] {
                    for reverse in [false, true] {
                        body(
                            makePeerRig(
                                viewModel: viewModel, scenario: scenario, ownerIsPrimary: ownerIsPrimary,
                                variant: variant, reverse: reverse))
                    }
                }
            }
        }
    }

    func testPeerShortcutInputNeverInterruptsAHeldTakeAndTheOwnerStillStopsOnce() {
        forEachPeerRig(Self.peerScenarios) { rig in
            rig.startHeldTake()
            XCTAssertEqual(rig.recorder.starts, 1, rig.label)

            rig.send(rig.scenario.peerInput)
            XCTAssertEqual(rig.recorder.killedTakes, 0, "Peer input killed the take: \(rig.label)")
            XCTAssertEqual(rig.recorder.pendingStops, 0, rig.label)
            for peer in rig.managers where peer !== rig.owner {
                XCTAssertEqual(peer.startupDebounceElapsedForTesting(), [], "Peer must stay suppressed: \(rig.label)")
            }

            rig.releaseOwnerAfterTapThreshold()
            XCTAssertEqual(rig.recorder.starts, 1, rig.label)
            XCTAssertEqual(rig.recorder.pendingStops, 1, "Owner release must stop once: \(rig.label)")
            XCTAssertEqual(rig.recorder.killedTakes, 0, rig.label)
        }
    }

    func testInputThatIsNotAConfiguredPeerStillInterruptsAHeldTake() {
        let optionEnd = HotkeyTrigger.chord(modifiers: ["option"], keyCode: 119)
        func scenario(
            _ name: String,
            owner: HotkeyTrigger = .control,
            peer: HotkeyTrigger,
            ownerPress: [PhysicalEvent] = [.modifier(59, Self.ctrl)],
            interference: [PhysicalEvent]
        ) -> PeerScenario {
            PeerScenario(
                name: name, owner: owner, peer: peer, ownerPress: ownerPress, peerInput: interference,
                ownerRelease: [.modifier(59, [])])
        }
        func releasedPeerKey(
            _ name: String, owner: HotkeyTrigger, held: CGEventFlags, press: [PhysicalEvent]
        ) -> PeerScenario {
            let withOption = held.union(Self.opt)
            return scenario(
                "\(name), peer chord key typed again after its release", owner: owner, peer: optionEnd,
                ownerPress: press,
                interference: [
                    .modifier(58, withOption), .down(119, withOption), .up(119, withOption),
                    .modifier(58, held), .down(119, held),
                ])
        }
        let scenarios = [
            scenario("Ordinary typing", peer: .option, interference: [.down(0, Self.ctrl)]),
            scenario("Unconfigured modifier", peer: .option, interference: [.modifier(56, [Self.ctrl, Self.shift])]),
            scenario(
                "Peer modifier first, then typing", peer: .option,
                interference: [
                    .modifier(58, Self.ctrlOpt), .down(0, Self.ctrlOpt),
                ]),
            scenario(
                "Peer chord terminal key without its modifiers", peer: optionEnd,
                interference: [
                    .down(119, Self.ctrl)
                ]),
            scenario(
                "Wrong key under the peer chord's modifiers", peer: optionEnd,
                interference: [
                    .modifier(58, Self.ctrlOpt), .down(0, Self.ctrlOpt),
                ]),
            scenario(
                "Opposite side of a side-specific peer", peer: Self.rightOptionTrigger,
                interference: [
                    .modifier(58, [Self.ctrl, Self.leftControl, Self.opt, Self.leftOption])
                ]),
            scenario(
                "Both sides held for a side-specific peer", peer: Self.rightOptionTrigger,
                interference: [
                    .modifier(61, [Self.ctrl, Self.leftControl, Self.opt, Self.rightOption, Self.leftOption])
                ]),
            scenario(
                "Fn owner, unclaimed key", owner: .fn, peer: .fromKeyCode(117),
                ownerPress: [.modifier(63, Self.fn)], interference: [.down(0, Self.fn)]),
            scenario(
                "Fn owner, key after a claimed key", owner: .fn, peer: .fromKeyCode(117),
                ownerPress: [.modifier(63, Self.fn)], interference: [.down(117, Self.fn), .down(0, Self.fn)]),
            scenario(
                "Modifier-chord owner, unconfigured modifier",
                owner: .modifierChord(modifiers: ["control", "shift"]), peer: .option,
                ownerPress: [.modifier(59, Self.ctrl), .modifier(56, [Self.ctrl, Self.shift])],
                interference: [.modifier(55, [Self.ctrl, Self.shift, .maskCommand])]),
            scenario(
                "Modifier-chord owner, ordinary typing",
                owner: .modifierChord(modifiers: ["control", "shift"]), peer: .option,
                ownerPress: [.modifier(59, Self.ctrl), .modifier(56, [Self.ctrl, Self.shift])],
                interference: [.down(0, [Self.ctrl, Self.shift])]),
            scenario(
                "Side-specific owner, unconfigured modifier",
                owner: Self.rightCommandTrigger, peer: .option,
                ownerPress: [.modifier(54, [.maskCommand, Self.rightCommand])],
                interference: [.modifier(56, [.maskCommand, Self.rightCommand, Self.shift])]),
            scenario(
                "Key owner, ordinary typing", owner: .fromKeyCode(105), peer: .fromKeyCode(117),
                ownerPress: [.down(105)], interference: [.down(0)]),
            scenario(
                "Key owner, unconfigured Fn", owner: .fromKeyCode(105), peer: .fromKeyCode(117),
                ownerPress: [.down(105)], interference: [.down(179)]),
            // The claim ends at the key's release, so the same key is typing again.
            releasedPeerKey("Control owner", owner: .control, held: Self.ctrl, press: [.modifier(59, Self.ctrl)]),
            releasedPeerKey("Fn owner", owner: .fn, held: Self.fn, press: [.modifier(63, Self.fn)]),
            releasedPeerKey(
                "Modifier-chord owner", owner: .modifierChord(modifiers: ["control", "shift"]),
                held: [Self.ctrl, Self.shift],
                press: [.modifier(59, Self.ctrl), .modifier(56, [Self.ctrl, Self.shift])]),
            releasedPeerKey("Key owner", owner: .fromKeyCode(105), held: [], press: [.down(105)]),
            scenario(
                "Chord owner, ordinary typing",
                owner: .chord(modifiers: ["control", "option"], keyCode: 20), peer: .fromKeyCode(105),
                ownerPress: [.modifier(59, Self.ctrl), .modifier(58, Self.ctrlOpt), .down(20, Self.ctrlOpt)],
                interference: [.down(0, Self.ctrlOpt)]),
        ]
        forEachPeerRig(scenarios) { rig in
            rig.startHeldTake()
            rig.send(rig.scenario.peerInput)
            XCTAssertEqual(rig.recorder.killedTakes, 1, "Interference must end the take once: \(rig.label)")

            rig.releaseOwnerAfterTapThreshold()
            XCTAssertEqual(rig.recorder.pendingStops, 0, "A killed take must not also stop: \(rig.label)")
            XCTAssertEqual(rig.recorder.killedTakes, 1, rig.label)
        }
    }

    func testPeerInputBeforeCaptureStillInterruptsThePendingPress() {
        let scenario = Self.peerScenarios[0]
        forEachPeerRig([scenario], variants: [.provisional]) { rig in
            rig.send(scenario.ownerPress)
            rig.send(scenario.peerInput)
            XCTAssertEqual(
                rig.owner.startupDebounceElapsedForTesting(), [],
                "No take is owned yet, so the peer press clears the pending one: \(rig.label)")
            XCTAssertEqual(rig.recorder.starts, 0, rig.label)
        }
    }

    func testEscapeStillCancelsOnceWhilePeerInputIsHeld() {
        let scenario = Self.peerScenarios[0]
        forEachPeerRig([scenario]) { rig in
            rig.startHeldTake()
            rig.send([.modifier(58, Self.ctrlOpt)])
            rig.send([.down(53, Self.ctrlOpt)])
            XCTAssertEqual(rig.recorder.cancels, 1, "One Escape cancels the take once: \(rig.label)")
            XCTAssertEqual(rig.recorder.discards, 0, rig.label)
        }
    }

    func testClaimedPeerKeyDoesNotOutliveTheTakeThatAbsorbedIt() {
        let optionEnd = HotkeyTrigger.chord(modifiers: ["option"], keyCode: 119)
        let scenario = PeerScenario(
            name: "Peer chord key never released", owner: .control, peer: optionEnd,
            ownerPress: [.modifier(59, Self.ctrl)],
            peerInput: [.modifier(58, Self.ctrlOpt), .down(119, Self.ctrlOpt)],
            ownerRelease: [.modifier(59, [])])
        forEachPeerRig([scenario], variants: [.confirmed]) { rig in
            rig.startHeldTake()
            rig.send(scenario.peerInput)
            XCTAssertEqual(rig.recorder.killedTakes, 0, rig.label)
            rig.releaseOwnerAfterTapThreshold()
            XCTAssertEqual(rig.recorder.pendingStops, 1, rig.label)

            // The next take sees the same key without the chord's modifier: typing.
            rig.send([.modifier(58, [])])
            rig.send(scenario.ownerPress)
            let restarted = rig.owner.startupDebounceElapsedForTesting()
            guard restarted == [.startRecording(mode: .holdToTalk)] else {
                return XCTFail("The owner should be able to start a second take: \(rig.label) \(restarted)")
            }
            rig.send([.down(119, Self.ctrl)])
            XCTAssertEqual(rig.recorder.killedTakes, 1, "A stale claim absorbed typing: \(rig.label)")
        }
    }
    // MARK: - Tap recovery during a held take

    /// A tap that macOS disabled and re-enabled resyncs from the physical state.
    /// Peer input held at that moment is judged the way the live paths judge it.
    func testTapRecoveryKeepsPeerInputThatIsHeldDuringAHeldTakeFromBecomingAnInterruption() {
        struct Recovery {
            let scenario: PeerScenario
            let heldAtRecovery: CGEventFlags
            let heldKeys: Set<UInt16>
            let afterRecovery: [PhysicalEvent]
        }
        let ctrlShift: CGEventFlags = [Self.ctrl, Self.shift]
        let recoveries = [
            Recovery(
                scenario: PeerScenario(
                    name: "Control owner, Option peer", owner: .control, peer: .option,
                    ownerPress: [.modifier(59, Self.ctrl)], peerInput: [.modifier(58, Self.ctrlOpt)],
                    ownerRelease: [.modifier(59, [])]),
                heldAtRecovery: Self.ctrlOpt, heldKeys: [], afterRecovery: [.modifier(58, Self.ctrl)]),
            Recovery(
                scenario: PeerScenario(
                    name: "Fn owner, Option peer", owner: .fn, peer: .option,
                    ownerPress: [.modifier(63, Self.fn)], peerInput: [.modifier(58, [Self.fn, Self.opt])],
                    ownerRelease: [.modifier(63, [])]),
                heldAtRecovery: [Self.fn, Self.opt], heldKeys: [], afterRecovery: [.modifier(58, Self.fn)]),
            Recovery(
                scenario: PeerScenario(
                    name: "Fn owner, standalone key peer", owner: .fn, peer: .fromKeyCode(117),
                    ownerPress: [.modifier(63, Self.fn)], peerInput: [.down(117, Self.fn)],
                    ownerRelease: [.modifier(63, [])]),
                heldAtRecovery: Self.fn, heldKeys: [117], afterRecovery: [.up(117, Self.fn)]),
            Recovery(
                scenario: PeerScenario(
                    name: "Modifier-chord owner, Option peer",
                    owner: .modifierChord(modifiers: ["control", "shift"]), peer: .option,
                    ownerPress: [.modifier(59, Self.ctrl), .modifier(56, ctrlShift)],
                    peerInput: [.modifier(58, [Self.ctrl, Self.shift, Self.opt])],
                    ownerRelease: [.modifier(56, Self.ctrl), .modifier(59, [])]),
                heldAtRecovery: [Self.ctrl, Self.shift, Self.opt], heldKeys: [],
                afterRecovery: [.modifier(58, ctrlShift)]),
            Recovery(
                scenario: PeerScenario(
                    name: "Right Command owner, Left Command peer",
                    owner: Self.rightCommandTrigger, peer: Self.leftCommandTrigger,
                    ownerPress: [.modifier(54, [.maskCommand, Self.rightCommand])],
                    peerInput: [.modifier(55, [.maskCommand, Self.rightCommand, Self.leftCommand])],
                    ownerRelease: [.modifier(54, [])]),
                heldAtRecovery: [.maskCommand, Self.rightCommand, Self.leftCommand], heldKeys: [],
                afterRecovery: [.modifier(55, [.maskCommand, Self.rightCommand])]),
        ]
        for recovery in recoveries {
            forEachPeerRig([recovery.scenario], variants: [.provisional, .confirmed]) { rig in
                rig.startHeldTake()
                rig.send(recovery.scenario.peerInput)
                rig.owner.setPhysicalKeyStateProviderForTesting { recovery.heldKeys.contains($0) }
                rig.owner.recoverFromDisabledTapForTesting(flags: recovery.heldAtRecovery, triggerKeyPressed: false)
                XCTAssertEqual(rig.recorder.killedTakes, 0, "Recovery killed the take: \(rig.label)")

                rig.send(recovery.afterRecovery)
                rig.releaseOwnerAfterTapThreshold()
                XCTAssertEqual(rig.recorder.pendingStops, 1, "Owner release must stop, not cancel: \(rig.label)")
                XCTAssertEqual(rig.recorder.killedTakes, 0, rig.label)
            }
        }
    }

    func testTapRecoveryStillTreatsAnUnconfiguredModifierAsInterference() {
        let scenario = PeerScenario(
            name: "Control owner, Option peer, Shift held", owner: .control, peer: .option,
            ownerPress: [.modifier(59, Self.ctrl)], peerInput: [],
            ownerRelease: [.modifier(59, [])])
        forEachPeerRig([scenario], variants: [.confirmed]) { rig in
            rig.startHeldTake()
            rig.owner.recoverFromDisabledTapForTesting(
                flags: [Self.ctrl, Self.opt, Self.shift], triggerKeyPressed: false)
            rig.releaseOwnerAfterTapThreshold()
            XCTAssertEqual(rig.recorder.pendingStops, 0, "Shift is not a peer, so the release cancels: \(rig.label)")
            XCTAssertEqual(rig.recorder.killedTakes, 1, rig.label)
        }
    }

    func testTapRecoveryDropsPeerKeyClaimsForKeysReleasedWhileTheTapWasDown() {
        let optionEnd = HotkeyTrigger.chord(modifiers: ["option"], keyCode: 119)
        let owners: [(name: String, owner: HotkeyTrigger, ownerPress: PhysicalEvent, held: CGEventFlags)] = [
            ("Control owner", .control, .modifier(59, Self.ctrl), Self.ctrl),
            ("Fn owner", .fn, .modifier(63, Self.fn), Self.fn),
        ]
        for (name, owner, ownerPress, held) in owners {
            let withOption = held.union(Self.opt)
            let scenario = PeerScenario(
                name: "\(name), Option+End peer", owner: owner, peer: optionEnd,
                ownerPress: [ownerPress],
                peerInput: [.modifier(58, withOption), .down(119, withOption)],
                ownerRelease: [.modifier(owner == .fn ? 63 : 59, [])])

            // The key went up while the tap was down, so typing it is typing again.
            forEachPeerRig([scenario], variants: [.confirmed]) { rig in
                rig.startHeldTake()
                rig.send(scenario.peerInput)
                rig.owner.setPhysicalKeyStateProviderForTesting { _ in false }
                rig.owner.recoverFromDisabledTapForTesting(flags: held, triggerKeyPressed: false)
                XCTAssertEqual(rig.recorder.killedTakes, 0, "Recovery alone is fine: \(rig.label)")

                rig.send([.down(119, held)])
                XCTAssertEqual(rig.recorder.killedTakes, 1, "A stale claim excused typing: \(rig.label)")
            }

            // The key is still down after recovery, so its claim holds until keyUp.
            forEachPeerRig([scenario], variants: [.confirmed]) { rig in
                rig.startHeldTake()
                rig.send(scenario.peerInput)
                rig.owner.setPhysicalKeyStateProviderForTesting { $0 == 119 }
                rig.owner.recoverFromDisabledTapForTesting(flags: withOption, triggerKeyPressed: false)
                rig.send([.up(119, withOption), .modifier(58, held)])
                XCTAssertEqual(rig.recorder.killedTakes, 0, "A held peer key survives recovery: \(rig.label)")

                rig.releaseOwnerAfterTapThreshold()
                XCTAssertEqual(rig.recorder.pendingStops, 1, rig.label)
                XCTAssertEqual(rig.recorder.killedTakes, 0, rig.label)
            }
        }
    }

}
