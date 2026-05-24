import XCTest
import MacParakeetCore
import MacParakeetViewModels
@testable import MacParakeet

@MainActor
final class AppHotkeyCoordinatorTests: XCTestCase {

    private func makeViewModel(functionName: String = #function) -> SettingsViewModel {
        let suiteName = "AppHotkeyCoordinatorTests.\(functionName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsViewModel(defaults: defaults)
    }

    private func makeCoordinator(
        settingsViewModel: SettingsViewModel,
        onAnyHotkeyEnabled: @escaping () -> Void = {},
        onHotkeyUnavailable: @escaping () -> Void = {},
        onHotkeyConflict: @escaping (HotkeyTrigger, [HotkeyTrigger]) -> Void
    ) -> AppHotkeyCoordinator {
        AppHotkeyCoordinator(
            settingsViewModel: settingsViewModel,
            onStartDictation: { _ in },
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

    func testDictationHotkeyPlanUsesCombinedDefaultGestureForFnPair() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .fn,
            pushToTalk: .fn
        )

        XCTAssertEqual(
            plan,
            AppHotkeyCoordinator.DictationHotkeyPlan(
                specs: [
                    .init(trigger: .fn, gestureMode: .doubleTapAndHold),
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
                    .init(trigger: rightCommand, gestureMode: .doubleTapAndHold),
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
                    .init(trigger: .option, gestureMode: .holdOnly),
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
                    .init(trigger: .defaultDictation, gestureMode: .doubleTapAndHold),
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
                startupDebounceMs: FnKeyStateMachine.defaultStartupDebounceMs
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
                    .init(trigger: .control, gestureMode: .singleTapToggle),
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
                    .init(trigger: .option, gestureMode: .holdOnly),
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
}
