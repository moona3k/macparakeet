import Foundation
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class OnboardingCoordinator {
    private let onboardingWindowController: OnboardingWindowController
    private let onRefreshHotkeys: () -> Void
    private let onOpenMainWindow: () -> Void
    private let onOpenSettings: () -> Void
    private let onCompleted: () -> Void
    private let onHotkeyPreviewArm: () -> Void
    private let onHotkeyPreviewDisarm: () -> Void

    private var reopenOnNextActivate = false

    init(
        onboardingWindowController: OnboardingWindowController,
        onRefreshHotkeys: @escaping () -> Void,
        onOpenMainWindow: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onCompleted: @escaping () -> Void = {},
        onHotkeyPreviewArm: @escaping () -> Void = {},
        onHotkeyPreviewDisarm: @escaping () -> Void = {}
    ) {
        self.onboardingWindowController = onboardingWindowController
        self.onRefreshHotkeys = onRefreshHotkeys
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenSettings = onOpenSettings
        self.onCompleted = onCompleted
        self.onHotkeyPreviewArm = onHotkeyPreviewArm
        self.onHotkeyPreviewDisarm = onHotkeyPreviewDisarm
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
                meetingVADModelPreparer: environment.meetingVADModelPreparer,
                entitlementsService: environment.entitlementsService
            )
        }
    }

    func show(environment: AppEnvironment?) {
        guard let environment else { return }
        show(
            permissionService: environment.permissionService,
            sttClient: environment.sttScheduler,
            diarizationService: environment.diarizationService,
            meetingVADModelPreparer: environment.meetingVADModelPreparer,
            entitlementsService: environment.entitlementsService
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
        meetingVADModelPreparer: any MeetingVADModelPreparing,
        entitlementsService: EntitlementsService
    ) {
        onboardingWindowController.show(
            permissionService: permissionService,
            sttClient: sttClient,
            diarizationService: diarizationService,
            meetingVADModelPreparer: meetingVADModelPreparer,
            onFinish: { [weak self] in
                self?.reopenOnNextActivate = false
                self?.onRefreshHotkeys()
                self?.onCompleted()
                Task {
                    await entitlementsService.bootstrapTrialIfNeeded()
                }
            },
            onHotkeyPreviewArm: { [weak self] in self?.onHotkeyPreviewArm() },
            onHotkeyPreviewDisarm: { [weak self] in self?.onHotkeyPreviewDisarm() },
            onOpenMainApp: { [weak self] in
                self?.onOpenMainWindow()
            },
            onOpenSettings: { [weak self] in
                self?.onOpenSettings()
            },
            onIncompleteDismiss: { [weak self] in
                self?.reopenOnNextActivate = true
            }
        )
    }
}
