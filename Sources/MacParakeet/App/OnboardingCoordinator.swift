import Foundation
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class OnboardingCoordinator {
    private let onboardingWindowController: OnboardingWindowController
    private let settingsViewModel: SettingsViewModel?
    private let onRefreshHotkeys: () -> Void
    private let onOpenSettings: () -> Void
    private let onCompleted: () -> Void
    private let onHotkeyPreviewArm: () -> Void
    private let onHotkeyPreviewDisarm: () -> Void
    private let onShortcutRecordingChanged: (Bool) -> Void
    private let onShortcutBindingsChanged: () -> Void

    private var reopenOnNextActivate = false

    init(
        onboardingWindowController: OnboardingWindowController,
        settingsViewModel: SettingsViewModel? = nil,
        onRefreshHotkeys: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onCompleted: @escaping () -> Void = {},
        onHotkeyPreviewArm: @escaping () -> Void = {},
        onHotkeyPreviewDisarm: @escaping () -> Void = {},
        onShortcutRecordingChanged: @escaping (Bool) -> Void = { _ in },
        onShortcutBindingsChanged: @escaping () -> Void = {}
    ) {
        self.onboardingWindowController = onboardingWindowController
        self.settingsViewModel = settingsViewModel
        self.onRefreshHotkeys = onRefreshHotkeys
        self.onOpenSettings = onOpenSettings
        self.onCompleted = onCompleted
        self.onHotkeyPreviewArm = onHotkeyPreviewArm
        self.onHotkeyPreviewDisarm = onHotkeyPreviewDisarm
        self.onShortcutRecordingChanged = onShortcutRecordingChanged
        self.onShortcutBindingsChanged = onShortcutBindingsChanged
    }

    var isVisible: Bool {
        onboardingWindowController.isVisible
    }

    func maybeShow(environment: AppEnvironment?) {
        guard let environment else { return }
        let completed = UserDefaults.standard.string(forKey: OnboardingViewModel.onboardingCompletedKey) != nil
        if !completed {
            show(
                permissionService: environment.permissionService,
                sttClient: environment.sttScheduler,
                diarizationService: environment.diarizationService,
                entitlementsService: environment.entitlementsService,
                restartExistingRun: false
            )
        }
    }

    func show(environment: AppEnvironment?) {
        guard let environment else { return }
        show(
            permissionService: environment.permissionService,
            sttClient: environment.sttScheduler,
            diarizationService: environment.diarizationService,
            entitlementsService: environment.entitlementsService,
            restartExistingRun: true
        )
    }

    func handleApplicationDidBecomeActive(environment: AppEnvironment?) {
        guard reopenOnNextActivate else { return }
        maybeShow(environment: environment)
    }

    private func show(
        permissionService: PermissionServiceProtocol,
        sttClient: STTClientProtocol,
        diarizationService: DiarizationServiceProtocol?,
        entitlementsService: EntitlementsService,
        restartExistingRun: Bool
    ) {
        onboardingWindowController.show(
            permissionService: permissionService,
            sttClient: sttClient,
            diarizationService: diarizationService,
            settingsViewModel: settingsViewModel,
            onFinish: { [weak self] in
                self?.reopenOnNextActivate = false
                self?.onRefreshHotkeys()
                self?.onCompleted()
                Task {
                    await entitlementsService.bootstrapTrialIfNeeded()
                }
            },
            restartExistingRun: restartExistingRun,
            onHotkeyPreviewArm: { [weak self] in self?.onHotkeyPreviewArm() },
            onHotkeyPreviewDisarm: { [weak self] in self?.onHotkeyPreviewDisarm() },
            onShortcutRecordingChanged: { [weak self] isRecording in
                self?.onShortcutRecordingChanged(isRecording)
            },
            onShortcutBindingsChanged: { [weak self] in self?.onShortcutBindingsChanged() },
            onOpenSettings: { [weak self] in
                self?.onOpenSettings()
            },
            onIncompleteDismiss: { [weak self] in
                self?.reopenOnNextActivate = true
            }
        )
    }
}
