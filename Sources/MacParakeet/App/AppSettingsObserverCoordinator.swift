import Foundation
import MacParakeetViewModels

@MainActor
final class AppSettingsObserverCoordinator {
    nonisolated static let settingsTabUserInfoKey = "settingsTab"

    private let notificationCenter: NotificationCenter
    private let onOpenOnboarding: () -> Void
    private let onOpenSettings: (SettingsTab?) -> Void
    private let onHotkeyTriggerChanged: () -> Void
    private let onPushToTalkHotkeyTriggerChanged: () -> Void
    private let onMeetingHotkeyTriggerChanged: () -> Void
    private let onFileTranscriptionHotkeyTriggerChanged: () -> Void
    private let onYouTubeTranscriptionHotkeyTriggerChanged: () -> Void
    private let onAppearanceModeChanged: () -> Void
    private let onMenuBarOnlyModeChanged: () -> Void
    private let onShowIdlePillChanged: () -> Void
    private let onInstantDictationChanged: () -> Void
    private let onMicrophoneSelectionChanged: () -> Void

    private var onboardingObserver: Any?
    private var settingsObserver: Any?
    private var hotkeyTriggerObserver: Any?
    private var pushToTalkHotkeyTriggerObserver: Any?
    private var meetingHotkeyTriggerObserver: Any?
    private var fileTranscriptionHotkeyTriggerObserver: Any?
    private var youtubeTranscriptionHotkeyTriggerObserver: Any?
    private var appearanceModeObserver: Any?
    private var menuBarOnlyModeObserver: Any?
    private var showIdlePillObserver: Any?
    private var instantDictationObserver: Any?
    private var microphoneSelectionObserver: Any?

    init(
        notificationCenter: NotificationCenter = .default,
        onOpenOnboarding: @escaping () -> Void,
        onOpenSettings: @escaping (SettingsTab?) -> Void,
        onHotkeyTriggerChanged: @escaping () -> Void,
        onPushToTalkHotkeyTriggerChanged: @escaping () -> Void,
        onMeetingHotkeyTriggerChanged: @escaping () -> Void,
        onFileTranscriptionHotkeyTriggerChanged: @escaping () -> Void,
        onYouTubeTranscriptionHotkeyTriggerChanged: @escaping () -> Void,
        onAppearanceModeChanged: @escaping () -> Void,
        onMenuBarOnlyModeChanged: @escaping () -> Void,
        onShowIdlePillChanged: @escaping () -> Void,
        onInstantDictationChanged: @escaping () -> Void,
        onMicrophoneSelectionChanged: @escaping () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.onOpenOnboarding = onOpenOnboarding
        self.onOpenSettings = onOpenSettings
        self.onHotkeyTriggerChanged = onHotkeyTriggerChanged
        self.onPushToTalkHotkeyTriggerChanged = onPushToTalkHotkeyTriggerChanged
        self.onMeetingHotkeyTriggerChanged = onMeetingHotkeyTriggerChanged
        self.onFileTranscriptionHotkeyTriggerChanged = onFileTranscriptionHotkeyTriggerChanged
        self.onYouTubeTranscriptionHotkeyTriggerChanged = onYouTubeTranscriptionHotkeyTriggerChanged
        self.onAppearanceModeChanged = onAppearanceModeChanged
        self.onMenuBarOnlyModeChanged = onMenuBarOnlyModeChanged
        self.onShowIdlePillChanged = onShowIdlePillChanged
        self.onInstantDictationChanged = onInstantDictationChanged
        self.onMicrophoneSelectionChanged = onMicrophoneSelectionChanged
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
        ) { [weak self] notification in
            let tab = Self.settingsTab(from: notification)
            Task { @MainActor in
                self?.onOpenSettings(tab)
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

        pushToTalkHotkeyTriggerObserver = notificationCenter.addObserver(
            forName: .macParakeetPushToTalkHotkeyTriggerDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onPushToTalkHotkeyTriggerChanged()
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

        fileTranscriptionHotkeyTriggerObserver = notificationCenter.addObserver(
            forName: .macParakeetFileTranscriptionHotkeyTriggerDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onFileTranscriptionHotkeyTriggerChanged()
            }
        }

        youtubeTranscriptionHotkeyTriggerObserver = notificationCenter.addObserver(
            forName: .macParakeetYouTubeTranscriptionHotkeyTriggerDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onYouTubeTranscriptionHotkeyTriggerChanged()
            }
        }

        appearanceModeObserver = notificationCenter.addObserver(
            forName: .macParakeetAppearanceModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onAppearanceModeChanged()
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

        instantDictationObserver = notificationCenter.addObserver(
            forName: .macParakeetInstantDictationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onInstantDictationChanged()
            }
        }

        microphoneSelectionObserver = notificationCenter.addObserver(
            forName: .macParakeetMicrophoneSelectionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onMicrophoneSelectionChanged()
            }
        }
    }

    nonisolated private static func settingsTab(from notification: Notification) -> SettingsTab? {
        guard let raw = notification.userInfo?[settingsTabUserInfoKey] as? String else {
            return nil
        }
        return SettingsTab(rawValue: raw)
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
        if let pushToTalkHotkeyTriggerObserver {
            notificationCenter.removeObserver(pushToTalkHotkeyTriggerObserver)
            self.pushToTalkHotkeyTriggerObserver = nil
        }
        if let meetingHotkeyTriggerObserver {
            notificationCenter.removeObserver(meetingHotkeyTriggerObserver)
            self.meetingHotkeyTriggerObserver = nil
        }
        if let fileTranscriptionHotkeyTriggerObserver {
            notificationCenter.removeObserver(fileTranscriptionHotkeyTriggerObserver)
            self.fileTranscriptionHotkeyTriggerObserver = nil
        }
        if let youtubeTranscriptionHotkeyTriggerObserver {
            notificationCenter.removeObserver(youtubeTranscriptionHotkeyTriggerObserver)
            self.youtubeTranscriptionHotkeyTriggerObserver = nil
        }
        if let appearanceModeObserver {
            notificationCenter.removeObserver(appearanceModeObserver)
            self.appearanceModeObserver = nil
        }
        if let menuBarOnlyModeObserver {
            notificationCenter.removeObserver(menuBarOnlyModeObserver)
            self.menuBarOnlyModeObserver = nil
        }
        if let showIdlePillObserver {
            notificationCenter.removeObserver(showIdlePillObserver)
            self.showIdlePillObserver = nil
        }
        if let instantDictationObserver {
            notificationCenter.removeObserver(instantDictationObserver)
            self.instantDictationObserver = nil
        }
        if let microphoneSelectionObserver {
            notificationCenter.removeObserver(microphoneSelectionObserver)
            self.microphoneSelectionObserver = nil
        }
    }
}
