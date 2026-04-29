import MacParakeetCore
import MacParakeetViewModels

enum SettingsStatusRules {
    static func meetingRecordingCardStatus(
        meetingRecordingEnabled: Bool,
        screenRecordingGranted: Bool
    ) -> SettingsCardStatus? {
        guard meetingRecordingEnabled else { return nil }
        return screenRecordingGranted
            ? SettingsCardStatus(.ok, label: "Ready")
            : SettingsCardStatus(.required, label: "Permission required")
    }

    static func localModelsCardStatus(
        parakeet: SettingsViewModel.LocalModelStatus,
        whisper: SettingsViewModel.LocalModelStatus,
        activeEngine: SpeechEnginePreference
    ) -> SettingsCardStatus? {
        if parakeet == .failed || whisper == .failed {
            return SettingsCardStatus(.required, label: "Action needed")
        }

        let activeStatus: SettingsViewModel.LocalModelStatus
        switch activeEngine {
        case .parakeet: activeStatus = parakeet
        case .whisper: activeStatus = whisper
        }

        if activeStatus == .notDownloaded {
            return SettingsCardStatus(.recommended, label: "Download recommended")
        }

        if isAvailable(parakeet), isAvailable(whisper) {
            return SettingsCardStatus(.ok, label: "Ready")
        }

        return nil
    }

    static func permissionsCardStatus(
        meetingRecordingEnabled: Bool,
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool
    ) -> SettingsCardStatus {
        if !microphoneGranted || !accessibilityGranted {
            return SettingsCardStatus(.required, label: "Action required")
        }

        if meetingRecordingEnabled, !screenRecordingGranted {
            return SettingsCardStatus(.required, label: "Action required")
        }

        return SettingsCardStatus(.ok, label: "All granted")
    }

    private static func isAvailable(_ status: SettingsViewModel.LocalModelStatus) -> Bool {
        status == .ready || status == .notLoaded
    }
}
