import MacParakeetCore
import MacParakeetViewModels

enum SettingsStatusRules {
    static func meetingRecordingCardStatus(
        meetingRecordingEnabled: Bool,
        screenRecordingGranted: Bool,
        meetingAudioSourceMode: MeetingAudioSourceMode
    ) -> SettingsCardStatus? {
        guard meetingRecordingEnabled else { return nil }
        guard meetingAudioSourceMode.capturesSystemAudio else {
            return SettingsCardStatus(.ok, label: "Ready")
        }
        return screenRecordingGranted
            ? SettingsCardStatus(.ok, label: "Ready")
            : SettingsCardStatus(.required, label: "Permission required")
    }

    /// `parakeet` and `nemotron` carry the status of each engine's *selected*
    /// build (Parakeet v3/v2/Unified, Nemotron multilingual/English) — per-build disk badges live in the
    /// engine's model card, not in this rollup.
    static func localModelsCardStatus(
        parakeet: SettingsViewModel.LocalModelStatus,
        nemotron: SettingsViewModel.LocalModelStatus,
        whisper: SettingsViewModel.LocalModelStatus,
        cohere: SettingsViewModel.LocalModelStatus,
        cohereEnabled: Bool = true,
        activeEngine: SpeechEnginePreference
    ) -> SettingsCardStatus? {
        let cohereStatus = cohereEnabled || activeEngine == .cohere ? cohere : .notDownloaded
        if parakeet == .failed || nemotron == .failed || whisper == .failed || cohereStatus == .failed {
            return SettingsCardStatus(.required, label: "Action needed")
        }

        let activeStatus: SettingsViewModel.LocalModelStatus
        switch activeEngine {
        case .parakeet: activeStatus = parakeet
        case .nemotron: activeStatus = nemotron
        case .whisper: activeStatus = whisper
        case .cohere: activeStatus = cohereStatus
        }

        if activeStatus == .notDownloaded {
            return SettingsCardStatus(.recommended, label: "Download recommended")
        }

        if activeStatus == .preparing || activeStatus == .repairing || activeStatus == .checking {
            return SettingsCardStatus(.recommended, label: "Preparing")
        }

        let optionalNemotronReady = nemotron == .notDownloaded || isAvailable(nemotron)
        // Cohere is an optional, large-download engine like Nemotron: its absence
        // must not block the "Ready" state when it isn't the active engine.
        let optionalCohereReady = cohereStatus == .notDownloaded || isAvailable(cohereStatus)
        if isAvailable(parakeet), isAvailable(whisper), optionalNemotronReady, optionalCohereReady {
            return SettingsCardStatus(.ok, label: "Ready")
        }

        return nil
    }

    static func permissionsCardStatus(
        meetingRecordingEnabled: Bool,
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        meetingAudioSourceMode: MeetingAudioSourceMode
    ) -> SettingsCardStatus {
        if !microphoneGranted || !accessibilityGranted {
            return SettingsCardStatus(.required, label: "Action required")
        }

        if meetingRecordingEnabled, meetingAudioSourceMode.capturesSystemAudio, !screenRecordingGranted {
            return SettingsCardStatus(.required, label: "Action required")
        }

        if meetingRecordingEnabled, !meetingAudioSourceMode.capturesSystemAudio, !screenRecordingGranted {
            return SettingsCardStatus(.ok, label: "Ready")
        }

        return SettingsCardStatus(.ok, label: "All granted")
    }

    private static func isAvailable(_ status: SettingsViewModel.LocalModelStatus) -> Bool {
        status == .ready || status == .notLoaded
    }
}
