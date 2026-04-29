import Foundation

public protocol AppRuntimePreferencesProtocol: Sendable {
    var processingMode: Dictation.ProcessingMode { get }
    var voiceReturnTrigger: String? { get }
    var shouldSaveAudioRecordings: Bool { get }
    var shouldSaveDictationHistory: Bool { get }
    var shouldSaveTranscriptionAudio: Bool { get }
    var shouldDiarize: Bool { get }
    var aiFormatterEnabled: Bool { get }
    var aiFormatterPrompt: String { get }
    var selectedMicrophoneDeviceUID: String? { get }
    var meetingAudioSourceMode: MeetingAudioSourceMode { get }
}

public enum MeetingAudioSourceMode: String, CaseIterable, Hashable, Sendable, Equatable {
    case microphoneAndSystem = "microphone_and_system"
    case systemOnly = "system_only"

    public var capturesMicrophone: Bool {
        self == .microphoneAndSystem
    }

    public var displayTitle: String {
        switch self {
        case .microphoneAndSystem:
            return "Microphone + System Audio"
        case .systemOnly:
            return "System Audio Only"
        }
    }

    public var detail: String {
        switch self {
        case .microphoneAndSystem:
            return "Capture your microphone and computer audio. Weak mic bleed is suppressed live."
        case .systemOnly:
            return "Capture computer audio for meetings. Your microphone is still used for dictation."
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> MeetingAudioSourceMode {
        guard let raw = defaults.string(forKey: UserDefaultsAppRuntimePreferences.meetingAudioSourceModeKey),
              let mode = MeetingAudioSourceMode(rawValue: raw) else {
            return .microphoneAndSystem
        }
        return mode
    }
}

public final class UserDefaultsAppRuntimePreferences: AppRuntimePreferencesProtocol, @unchecked Sendable {
    public static let showIdlePillKey = "showIdlePill"
    public static let silenceAutoStopKey = "silenceAutoStop"
    public static let silenceDelayKey = "silenceDelay"
    public static let voiceReturnEnabledKey = "voiceReturnEnabled"
    public static let voiceReturnTriggerKey = "voiceReturnTrigger"
    public static let processingModeKey = "processingMode"
    public static let saveDictationHistoryKey = "saveDictationHistory"
    public static let saveAudioRecordingsKey = "saveAudioRecordings"
    public static let saveTranscriptionAudioKey = "saveTranscriptionAudio"
    public static let speakerDiarizationKey = "speakerDiarization"
    public static let aiFormatterEnabledKey = "aiFormatterEnabled"
    public static let aiFormatterPromptKey = "aiFormatterPrompt"
    public static let selectedMicrophoneDeviceUIDKey = "selectedMicrophoneDeviceUID"
    public static let meetingAudioSourceModeKey = "meetingAudioSourceMode"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var processingMode: Dictation.ProcessingMode {
        let raw = defaults.string(forKey: Self.processingModeKey)
        return Dictation.ProcessingMode(rawValue: raw ?? Dictation.ProcessingMode.raw.rawValue) ?? .raw
    }

    public var voiceReturnTrigger: String? {
        guard defaults.bool(forKey: Self.voiceReturnEnabledKey) else { return nil }
        let trigger = (defaults.string(forKey: Self.voiceReturnTriggerKey) ?? "press return")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trigger.isEmpty ? nil : trigger
    }

    public var shouldSaveAudioRecordings: Bool {
        defaults.object(forKey: Self.saveAudioRecordingsKey) as? Bool ?? true
    }

    public var shouldSaveDictationHistory: Bool {
        defaults.object(forKey: Self.saveDictationHistoryKey) as? Bool ?? true
    }

    public var shouldSaveTranscriptionAudio: Bool {
        defaults.object(forKey: Self.saveTranscriptionAudioKey) as? Bool ?? true
    }

    public var shouldDiarize: Bool {
        defaults.object(forKey: Self.speakerDiarizationKey) as? Bool ?? true
    }

    public var aiFormatterEnabled: Bool {
        defaults.object(forKey: Self.aiFormatterEnabledKey) as? Bool ?? false
    }

    public var aiFormatterPrompt: String {
        let prompt = defaults.string(forKey: Self.aiFormatterPromptKey) ?? ""
        return AIFormatter.normalizedPromptTemplate(prompt)
    }

    public var selectedMicrophoneDeviceUID: String? {
        AudioDeviceManager.normalizedUID(defaults.string(forKey: Self.selectedMicrophoneDeviceUIDKey))
    }

    public var meetingAudioSourceMode: MeetingAudioSourceMode {
        MeetingAudioSourceMode.current(defaults: defaults)
    }
}
