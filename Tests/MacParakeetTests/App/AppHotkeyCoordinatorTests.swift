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
            "Dictation: Fn (hold or double-tap)"
        )
    }

    func testMenuTitleDescribesDistinctDictationTriggers() {
        XCTAssertEqual(
            AppHotkeyCoordinator.menuTitle(handsFree: .control, pushToTalk: .option),
            "Dictation: Hold Option / Double-tap Control"
        )
    }

    func testDictationHotkeyPlanUsesOneCombinedManagerForSharedTrigger() {
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

    func testDictationHotkeyPlanUsesSeparateManagersForDistinctTriggers() {
        let plan = AppHotkeyCoordinator.dictationHotkeyPlan(
            handsFree: .control,
            pushToTalk: .option
        )

        XCTAssertEqual(
            plan,
            AppHotkeyCoordinator.DictationHotkeyPlan(
                specs: [
                    .init(trigger: .control, gestureMode: .doubleTapOnly),
                    .init(trigger: .option, gestureMode: .holdOnly),
                ],
                conflict: nil
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
                    .init(trigger: .control, gestureMode: .doubleTapOnly),
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
}
