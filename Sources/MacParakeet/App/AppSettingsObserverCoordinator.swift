import Foundation

@MainActor
final class AppSettingsObserverCoordinator {
    private let notificationCenter: NotificationCenter
    private let onOpenOnboarding: () -> Void
    private let onOpenSettings: () -> Void
    private let onHotkeyTriggerChanged: () -> Void
    private let onMeetingHotkeyTriggerChanged: () -> Void
    private let onMenuBarOnlyModeChanged: () -> Void
    private let onShowIdlePillChanged: () -> Void

    private var onboardingObserver: Any?
    private var settingsObserver: Any?
    private var hotkeyTriggerObserver: Any?
    private var meetingHotkeyTriggerObserver: Any?
    private var menuBarOnlyModeObserver: Any?
    private var showIdlePillObserver: Any?

    init(
        notificationCenter: NotificationCenter = .default,
        onOpenOnboarding: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onHotkeyTriggerChanged: @escaping () -> Void,
        onMeetingHotkeyTriggerChanged: @escaping () -> Void,
        onMenuBarOnlyModeChanged: @escaping () -> Void,
        onShowIdlePillChanged: @escaping () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.onOpenOnboarding = onOpenOnboarding
        self.onOpenSettings = onOpenSettings
        self.onHotkeyTriggerChanged = onHotkeyTriggerChanged
        self.onMeetingHotkeyTriggerChanged = onMeetingHotkeyTriggerChanged
        self.onMenuBarOnlyModeChanged = onMenuBarOnlyModeChanged
        self.onShowIdlePillChanged = onShowIdlePillChanged
    }

    func startObserving() {
        stopObserving()

        onboardingObserver = notificationCenter.addObserver(
            forName: .macParakeetOpenOnboarding,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onOpenOnboarding()
            }
        }

        settingsObserver = notificationCenter.addObserver(
            forName: .macParakeetOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onOpenSettings()
            }
        }

        hotkeyTriggerObserver = notificationCenter.addObserver(
            forName: .macParakeetHotkeyTriggerDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onHotkeyTriggerChanged()
            }
        }

        meetingHotkeyTriggerObserver = notificationCenter.addObserver(
            forName: .macParakeetMeetingHotkeyTriggerDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onMeetingHotkeyTriggerChanged()
            }
        }

        menuBarOnlyModeObserver = notificationCenter.addObserver(
            forName: .macParakeetMenuBarOnlyModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onMenuBarOnlyModeChanged()
            }
        }

        showIdlePillObserver = notificationCenter.addObserver(
            forName: .macParakeetShowIdlePillDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onShowIdlePillChanged()
            }
        }
    }

    func stopObserving() {
        if let onboardingObserver {
            notificationCenter.removeObserver(onboardingObserver)
            self.onboardingObserver = nil
        }
        if let settingsObserver {
            notificationCenter.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        if let hotkeyTriggerObserver {
            notificationCenter.removeObserver(hotkeyTriggerObserver)
            self.hotkeyTriggerObserver = nil
        }
        if let meetingHotkeyTriggerObserver {
            notificationCenter.removeObserver(meetingHotkeyTriggerObserver)
            self.meetingHotkeyTriggerObserver = nil
        }
        if let menuBarOnlyModeObserver {
            notificationCenter.removeObserver(menuBarOnlyModeObserver)
            self.menuBarOnlyModeObserver = nil
        }
        if let showIdlePillObserver {
            notificationCenter.removeObserver(showIdlePillObserver)
            self.showIdlePillObserver = nil
        }
    }
}
