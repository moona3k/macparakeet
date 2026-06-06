import Foundation

public protocol AppRuntimePreferencesProtocol: Sendable {
    var processingMode: Dictation.ProcessingMode { get }
    var voiceReturnTrigger: String? { get }
    var shouldSaveAudioRecordings: Bool { get }
    var shouldSaveDictationHistory: Bool { get }
    var shouldSaveTranscriptionAudio: Bool { get }
    var youtubeAudioQuality: YouTubeAudioQuality { get }
    var shouldDiarize: Bool { get }
    var aiFormatterEnabled: Bool { get }
    var aiFormatterEnabledForDictation: Bool { get }
    var aiFormatterPrompt: String { get }
    var transcriptAIContextMode: TranscriptAIContextMode { get }
    var selectedMicrophoneDeviceUID: String? { get }
    var meetingAudioSourceMode: MeetingAudioSourceMode { get }
    var pauseMediaDuringDictation: Bool { get }
    var shouldKeepDictationOnClipboard: Bool { get }
    var hasCompletedFirstDictation: Bool { get }
    /// Flip the one-shot "first dictation completed" flag. Returns `true` only
    /// the first time it transitions (so callers can fire a one-shot side
    /// effect like the activation telemetry event); `false` on every
    /// subsequent call.
    @discardableResult
    func markFirstDictationCompleted() -> Bool
}

public enum TranscriptAIContextMode: String, CaseIterable, Codable, Identifiable, Sendable, Equatable {
    case richTranscript = "rich_transcript"
    case plainTranscript = "plain_transcript"

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .richTranscript:
            return "Rich transcript"
        case .plainTranscript:
            return "Plain transcript"
        }
    }

    public var detail: String {
        switch self {
        case .richTranscript:
            return "Use timestamps and available speaker labels when the transcript has them."
        case .plainTranscript:
            return "Use the transcript text without timing or speaker labels."
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> TranscriptAIContextMode {
        guard let raw = defaults.string(forKey: UserDefaultsAppRuntimePreferences.transcriptAIContextModeKey),
              let mode = TranscriptAIContextMode(rawValue: raw) else {
            return .richTranscript
        }
        return mode
    }
}

public enum YouTubeAudioQuality: String, CaseIterable, Hashable, Sendable, Equatable {
    case m4a
    case bestAvailable = "best_available"

    public var displayTitle: String {
        switch self {
        case .m4a:
            return "M4A"
        case .bestAvailable:
            return "Best available"
        }
    }

    public var detail: String {
        switch self {
        case .m4a:
            return "Download an Apple-friendly m4a file. Smaller and slightly faster; transcripts are close to Best available for most videos."
        case .bestAvailable:
            return "YouTube's highest-quality audio stream — recommended when transcription accuracy matters most (issue #237 measured ~10% lower WER on a Stanford speech). WebM/Opus downloads are converted to m4a in the background so the in-app audio scrubber works."
        }
    }

    public var ytDlpFormatSelector: String {
        switch self {
        case .m4a:
            return "bestaudio[ext=m4a]/bestaudio/best"
        case .bestAvailable:
            return "bestaudio/best"
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> YouTubeAudioQuality {
        guard let raw = defaults.string(forKey: UserDefaultsAppRuntimePreferences.youtubeAudioQualityKey),
              let quality = YouTubeAudioQuality(rawValue: raw) else {
            return .m4a
        }
        return quality
    }
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
    public static let youtubeAudioQualityKey = "youtubeAudioQuality"
    public static let speakerDiarizationKey = "speakerDiarization"
    public static let aiFormatterEnabledKey = "aiFormatterEnabled"
    public static let aiFormatterEnabledForDictationKey = "aiFormatterEnabledForDictation"
    public static let aiFormatterPromptKey = "aiFormatterPrompt"
    public static let transcriptAIContextModeKey = "transcriptAIContextMode"
    public static let selectedMicrophoneDeviceUIDKey = "selectedMicrophoneDeviceUID"
    public static let meetingAudioSourceModeKey = "meetingAudioSourceMode"
    public static let pauseMediaDuringDictationKey = "pauseMediaDuringDictation"
    public static let keepDictationOnClipboardKey = "keepDictationOnClipboard"
    public static let hasCompletedFirstDictationKey = "hasCompletedFirstDictation"
    /// Play a chime (and, when backgrounded, post a banner) when a file/URL
    /// transcription or a batch finishes. Default on; opt-out in Settings.
    public static let notifyOnTranscriptionCompleteKey = "notifyOnTranscriptionComplete"

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

    public var youtubeAudioQuality: YouTubeAudioQuality {
        YouTubeAudioQuality.current(defaults: defaults)
    }

    public var shouldDiarize: Bool {
        defaults.object(forKey: Self.speakerDiarizationKey) as? Bool ?? false
    }

    public var aiFormatterEnabled: Bool {
        defaults.object(forKey: Self.aiFormatterEnabledKey) as? Bool ?? false
    }

    /// Whether the AI Formatter also runs on live dictation. Independent of the
    /// global `aiFormatterEnabled` switch so users can keep AI formatting for
    /// long-form file/meeting transcripts while keeping dictation low-latency
    /// (the LLM round-trip is the dominant cost on short utterances). Defaults
    /// to `false`; the dictation gate is the logical AND of both flags.
    public var aiFormatterEnabledForDictation: Bool {
        defaults.object(forKey: Self.aiFormatterEnabledForDictationKey) as? Bool ?? false
    }

    public var aiFormatterPrompt: String {
        let prompt = defaults.string(forKey: Self.aiFormatterPromptKey) ?? ""
        return AIFormatter.normalizedPromptTemplate(prompt)
    }

    public var transcriptAIContextMode: TranscriptAIContextMode {
        TranscriptAIContextMode.current(defaults: defaults)
    }

    public var selectedMicrophoneDeviceUID: String? {
        AudioDeviceManager.normalizedUID(defaults.string(forKey: Self.selectedMicrophoneDeviceUIDKey))
    }

    public var meetingAudioSourceMode: MeetingAudioSourceMode {
        MeetingAudioSourceMode.current(defaults: defaults)
    }

    public var pauseMediaDuringDictation: Bool {
        defaults.object(forKey: Self.pauseMediaDuringDictationKey) as? Bool ?? false
    }

    public var shouldKeepDictationOnClipboard: Bool {
        defaults.bool(forKey: Self.keepDictationOnClipboardKey)
    }

    public var hasCompletedFirstDictation: Bool {
        defaults.bool(forKey: Self.hasCompletedFirstDictationKey)
    }

    @discardableResult
    public func markFirstDictationCompleted() -> Bool {
        guard !hasCompletedFirstDictation else { return false }
        defaults.set(true, forKey: Self.hasCompletedFirstDictationKey)
        return true
    }
}
