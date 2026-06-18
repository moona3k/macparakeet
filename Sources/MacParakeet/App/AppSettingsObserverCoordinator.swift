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

    private var observerTokens: [NSObjectProtocol] = []

    private static let plainChannels:
        [(Notification.Name, @MainActor @Sendable (AppSettingsObserverCoordinator) -> Void)] = [
            (.macParakeetHotkeyTriggerDidChange, { $0.onHotkeyTriggerChanged() }),
            (.macParakeetPushToTalkHotkeyTriggerDidChange, { $0.onPushToTalkHotkeyTriggerChanged() }),
            (.macParakeetMeetingHotkeyTriggerDidChange, { $0.onMeetingHotkeyTriggerChanged() }),
            (.macParakeetFileTranscriptionHotkeyTriggerDidChange, { $0.onFileTranscriptionHotkeyTriggerChanged() }),
            (.macParakeetYouTubeTranscriptionHotkeyTriggerDidChange, { $0.onYouTubeTranscriptionHotkeyTriggerChanged() }),
            (.macParakeetAppearanceModeDidChange, { $0.onAppearanceModeChanged() }),
            (.macParakeetMenuBarOnlyModeDidChange, { $0.onMenuBarOnlyModeChanged() }),
            (.macParakeetShowIdlePillDidChange, { $0.onShowIdlePillChanged() }),
            (.macParakeetInstantDictationDidChange, { $0.onInstantDictationChanged() }),
            (.macParakeetMicrophoneSelectionDidChange, { $0.onMicrophoneSelectionChanged() }),
        ]

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

        observerTokens.append(notificationCenter.addObserver(
            forName: .macParakeetOpenOnboarding, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onOpenOnboarding() }
        })

        observerTokens.append(notificationCenter.addObserver(
            forName: .macParakeetOpenSettings, object: nil, queue: .main
        ) { [weak self] notification in
            let tab = Self.settingsTab(from: notification)
            Task { @MainActor in self?.onOpenSettings(tab) }
        })

        for (name, invoke) in Self.plainChannels {
            let token = notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    invoke(self)
                }
            }
            observerTokens.append(token)
        }
    }

    nonisolated private static func settingsTab(from notification: Notification) -> SettingsTab? {
        guard let raw = notification.userInfo?[settingsTabUserInfoKey] as? String else {
            return nil
        }
        return SettingsTab(rawValue: raw)
    }

    func stopObserving() {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
    }
}
