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
}
