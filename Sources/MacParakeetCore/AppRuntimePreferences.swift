import Foundation

public protocol AppRuntimePreferencesProtocol: Sendable {
    var processingMode: Dictation.ProcessingMode { get }
    var dictationInsertionStyle: DictationInsertionStyle { get }
    var voiceReturnTrigger: String? { get }
    var shouldSaveAudioRecordings: Bool { get }
    var shouldSaveDictationHistory: Bool { get }
    var shouldSaveTranscriptionAudio: Bool { get }
    var meetingAudioRetention: MeetingAudioRetention { get }
    var shouldSaveMeetingAudio: Bool { get }
    var shouldAutoGenerateMeetingTitles: Bool { get }
    var youtubeAudioQuality: YouTubeAudioQuality { get }
    var shouldDiarize: Bool { get }
    var aiFormatterEnabled: Bool { get }
    var aiFormatterEnabledForDictation: Bool { get }
    var aiFormatterEnabledForTranscriptions: Bool { get }
    var aiFormatterPrompt: String { get }
    var transcriptAIContextMode: TranscriptAIContextMode { get }
    var selectedMicrophoneDeviceUID: String? { get }
    var meetingAudioSourceMode: MeetingAudioSourceMode { get }
    var pauseMediaDuringDictation: Bool { get }
    var instantDictationEnabled: Bool { get }
    var showLiveDictationPreview: Bool { get }
    var dictationPreviewTextSize: DictationPreviewTextSize { get }
    var shouldKeepDictationOnClipboard: Bool { get }
    var hasCompletedFirstDictation: Bool { get }
    /// Flip the one-shot "first dictation completed" flag. Returns `true` only
    /// the first time it transitions (so callers can fire a one-shot side
    /// effect like the activation telemetry event); `false` on every
    /// subsequent call.
    @discardableResult
    func markFirstDictationCompleted() -> Bool
}

public enum MeetingAudioRetentionMode: String, CaseIterable, Identifiable, Hashable, Sendable, Equatable {
    case keepForever = "keep_forever"
    case deleteAfterDays = "delete_after_days"
    case deleteImmediately = "delete_immediately"

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .keepForever:
            return "Keep forever"
        case .deleteAfterDays:
            return "Delete after..."
        case .deleteImmediately:
            return "Delete after transcription"
        }
    }
}

public enum MeetingAudioRetention: Hashable, Sendable, Equatable {
    public static let minDeleteAfterDays = 1
    public static let maxDeleteAfterDays = 365
    public static let defaultDeleteAfterDays = 30
    public static let deleteAfterDaysRange = minDeleteAfterDays...maxDeleteAfterDays

    case keepForever
    case deleteAfterDays(Int)
    case deleteImmediately

    public var mode: MeetingAudioRetentionMode {
        switch self {
        case .keepForever:
            return .keepForever
        case .deleteAfterDays:
            return .deleteAfterDays
        case .deleteImmediately:
            return .deleteImmediately
        }
    }

    public var deleteAfterDays: Int {
        switch self {
        case .deleteAfterDays(let days):
            return Self.normalizedDeleteAfterDays(days)
        case .keepForever, .deleteImmediately:
            return Self.defaultDeleteAfterDays
        }
    }

    public var shouldSaveFreshAudio: Bool {
        self != .deleteImmediately
    }

    public var automaticallyDeletesAudio: Bool {
        self != .keepForever
    }

    public var storageRawValue: String {
        switch self {
        case .keepForever:
            return MeetingAudioRetentionMode.keepForever.rawValue
        case .deleteAfterDays:
            return MeetingAudioRetentionMode.deleteAfterDays.rawValue
        case .deleteImmediately:
            return MeetingAudioRetentionMode.deleteImmediately.rawValue
        }
    }

    public var configurationValue: String {
        switch self {
        case .keepForever:
            return "keep-forever"
        case .deleteAfterDays(let days):
            let normalizedDays = Self.normalizedDeleteAfterDays(days)
            return "delete-after-\(normalizedDays)-\(Self.dayUnit(for: normalizedDays))"
        case .deleteImmediately:
            return "delete-immediately"
        }
    }

    public static func make(mode: MeetingAudioRetentionMode, days: Int = defaultDeleteAfterDays) -> MeetingAudioRetention {
        switch mode {
        case .keepForever:
            return .keepForever
        case .deleteAfterDays:
            return .deleteAfterDays(normalizedDeleteAfterDays(days))
        case .deleteImmediately:
            return .deleteImmediately
        }
    }

    public static func normalizedDeleteAfterDays(_ days: Int) -> Int {
        guard deleteAfterDaysRange.contains(days) else {
            return defaultDeleteAfterDays
        }
        return days
    }

    public static func isValidDeleteAfterDays(_ days: Int) -> Bool {
        deleteAfterDaysRange.contains(days)
    }

    public static func parseConfigurationValue(_ value: String) -> MeetingAudioRetention? {
        let raw = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        switch raw {
        case "keep-forever", "forever", "keep", "on", "true":
            return .keepForever
        case "delete-immediately", "immediate", "delete-after-transcription", "after-transcription", "off", "false":
            return .deleteImmediately
        default:
            break
        }

        var dayValue = raw
        if dayValue.hasSuffix("-days") {
            dayValue = String(dayValue.dropLast("-days".count))
        } else if dayValue.hasSuffix("-day") {
            dayValue = String(dayValue.dropLast("-day".count))
        } else if dayValue.hasSuffix("d") {
            dayValue = String(dayValue.dropLast())
        }
        if dayValue.hasPrefix("delete-after-") {
            dayValue = String(dayValue.dropFirst("delete-after-".count))
        } else if dayValue.hasPrefix("after-") {
            dayValue = String(dayValue.dropFirst("after-".count))
        }

        if let days = Int(dayValue),
           isValidDeleteAfterDays(days) {
            return .deleteAfterDays(days)
        }
        return nil
    }

    private static func dayUnit(for days: Int) -> String {
        days == 1 ? "day" : "days"
    }
}

public enum DictationInsertionStyle: String, CaseIterable, Hashable, Sendable, Equatable {
    case sentence
    case inline

    public var displayTitle: String {
        switch self {
        case .sentence:
            return "Sentence"
        case .inline:
            return "Inline"
        }
    }

    public var detail: String {
        switch self {
        case .sentence:
            return "Starts like a sentence and keeps ending punctuation."
        case .inline:
            return "Fits replacements, fields, search, and commands."
        }
    }

    public var previewText: String {
        switch self {
        case .sentence:
            return "Hello world."
        case .inline:
            return "hello world"
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> DictationInsertionStyle {
        guard let raw = defaults.string(forKey: UserDefaultsAppRuntimePreferences.dictationInsertionStyleKey),
              let style = DictationInsertionStyle(rawValue: raw) else {
            return .sentence
        }
        return style
    }
}

/// Text size for the in-progress live transcript preview shown above the
/// dictation pill. Discrete presets keep the control glanceable; the view layer
/// maps each case to concrete font/padding metrics so Core stays UI-free.
public enum DictationPreviewTextSize: String, CaseIterable, Hashable, Sendable, Equatable {
    case small
    case medium
    case large

    public var displayTitle: String {
        switch self {
        case .small:
            return "Small"
        case .medium:
            return "Medium"
        case .large:
            return "Large"
        }
    }

    public static func current(defaults: UserDefaults = .standard) -> DictationPreviewTextSize {
        guard let raw = defaults.string(forKey: UserDefaultsAppRuntimePreferences.dictationPreviewTextSizeKey),
              let size = DictationPreviewTextSize(rawValue: raw) else {
            return .medium
        }
        return size
    }
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
            return "Use transcript text without timestamps."
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
    case microphoneOnly = "microphone_only"
    case systemOnly = "system_only"

    public var capturesMicrophone: Bool {
        switch self {
        case .microphoneAndSystem, .microphoneOnly:
            return true
        case .systemOnly:
            return false
        }
    }

    public var capturesSystemAudio: Bool {
        switch self {
        case .microphoneAndSystem, .systemOnly:
            return true
        case .microphoneOnly:
            return false
        }
    }

    public var displayTitle: String {
        switch self {
        case .microphoneAndSystem:
            return "Microphone + system audio"
        case .microphoneOnly:
            return "Microphone only"
        case .systemOnly:
            return "System audio only"
        }
    }

    public var detail: String {
        switch self {
        case .microphoneAndSystem:
            return "Capture your voice and call audio. Best when using headphones."
        case .microphoneOnly:
            return "Capture only your microphone. Useful when speaker audio bleeds into the mic."
        case .systemOnly:
            return "Capture only computer audio. Your microphone stays available for dictation."
        }
    }

    public var configurationValue: String {
        switch self {
        case .microphoneAndSystem:
            return "microphone-and-system"
        case .microphoneOnly:
            return "microphone-only"
        case .systemOnly:
            return "system-only"
        }
    }

    public static func parseConfigurationValue(_ value: String) -> MeetingAudioSourceMode? {
        let raw = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "_-+&").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        switch raw {
        case "microphone-and-system",
             "microphone-and-system-audio",
             "microphone-system",
             "microphone-system-audio",
             "mic-and-system",
             "mic-and-system-audio",
             "mic-system",
             "mic-system-audio",
             "both",
             "all",
             "default":
            return .microphoneAndSystem
        // Short source aliases are exclusive; use "both" or "default" for combined capture.
        case "microphone-only", "mic-only", "microphone", "mic":
            return .microphoneOnly
        case "system-only", "system-audio-only", "system", "computer-audio-only", "computer-audio":
            return .systemOnly
        default:
            return nil
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
    public static let dictationInsertionStyleKey = "dictationInsertionStyle"
    public static let saveDictationHistoryKey = "saveDictationHistory"
    public static let saveAudioRecordingsKey = "saveAudioRecordings"
    public static let saveTranscriptionAudioKey = "saveTranscriptionAudio"
    public static let saveMeetingAudioKey = "saveMeetingAudio"
    public static let meetingAudioRetentionKey = "meetingAudioRetention"
    public static let meetingAudioRetentionDeleteAfterDaysKey = "meetingAudioRetentionDeleteAfterDays"
    public static let meetingAudioRetentionAutoDeleteConfirmedKey = "meetingAudioRetentionAutoDeleteConfirmed"
    public static let lastMeetingAudioRetentionSweepAtKey = "lastMeetingAudioRetentionSweepAt"
    public static let autoGenerateMeetingTitlesKey = "autoGenerateMeetingTitles"
    public static let youtubeAudioQualityKey = "youtubeAudioQuality"
    public static let speakerDiarizationKey = "speakerDiarization"
    public static let aiFormatterEnabledKey = "aiFormatterEnabled"
    public static let aiFormatterEnabledForDictationKey = "aiFormatterEnabledForDictation"
    public static let aiFormatterEnabledForTranscriptionsKey = "aiFormatterEnabledForTranscriptions"
    public static let aiFormatterPromptKey = "aiFormatterPrompt"
    /// Master switch for the built-in smart-default formatter prompts
    /// (default on). Off means the resolution chain skips the smart-default
    /// tier entirely — custom profiles, then the fallback prompt.
    public static let aiFormatterSmartDefaultsEnabledKey = "aiFormatterSmartDefaultsEnabled"
    /// Raw `TelemetryAppCategory` values whose built-in smart default the user
    /// turned off individually (default empty).
    public static let aiFormatterDisabledSmartDefaultCategoriesKey = "aiFormatterDisabledSmartDefaultCategories"
    public static let transcriptAIContextModeKey = "transcriptAIContextMode"
    public static let selectedMicrophoneDeviceUIDKey = "selectedMicrophoneDeviceUID"
    public static let meetingAudioSourceModeKey = "meetingAudioSourceMode"
    public static let meetingAutoStopEnabledKey = "meetingAutoStopEnabled"
    public static let pauseMediaDuringDictationKey = "pauseMediaDuringDictation"
    public static let instantDictationEnabledKey = "instantDictationEnabled"
    public static let showLiveDictationPreviewKey = "showLiveDictationPreview"
    public static let dictationPreviewTextSizeKey = "dictationPreviewTextSize"
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

    public var dictationInsertionStyle: DictationInsertionStyle {
        DictationInsertionStyle.current(defaults: defaults)
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

    public var meetingAudioRetention: MeetingAudioRetention {
        Self.meetingAudioRetention(defaults: defaults)
    }

    public var shouldSaveMeetingAudio: Bool {
        meetingAudioRetention.shouldSaveFreshAudio
    }

    public var shouldAutoGenerateMeetingTitles: Bool {
        defaults.object(forKey: Self.autoGenerateMeetingTitlesKey) as? Bool ?? true
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

    /// Whether the AI Formatter runs on file/meeting transcripts. Defaults to
    /// `true` to preserve the pre-#493 behavior where transcripts followed the
    /// saved provider config alone; the transcription gate is the logical AND
    /// of `aiFormatterEnabled` and this flag.
    public var aiFormatterEnabledForTranscriptions: Bool {
        defaults.object(forKey: Self.aiFormatterEnabledForTranscriptionsKey) as? Bool ?? true
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

    public var instantDictationEnabled: Bool {
        defaults.object(forKey: Self.instantDictationEnabledKey) as? Bool ?? false
    }

    public var showLiveDictationPreview: Bool {
        defaults.object(forKey: Self.showLiveDictationPreviewKey) as? Bool ?? true
    }

    public var dictationPreviewTextSize: DictationPreviewTextSize {
        DictationPreviewTextSize.current(defaults: defaults)
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

    public static func meetingAudioRetention(defaults: UserDefaults = .standard) -> MeetingAudioRetention {
        if let raw = defaults.string(forKey: meetingAudioRetentionKey),
           let mode = MeetingAudioRetentionMode(rawValue: raw) {
            return MeetingAudioRetention.make(
                mode: mode,
                days: meetingAudioRetentionDeleteAfterDays(defaults: defaults)
            )
        }

        let migrated: MeetingAudioRetention = (defaults.object(forKey: saveMeetingAudioKey) as? Bool ?? true)
            ? .keepForever
            : .deleteImmediately
        saveMeetingAudioRetention(migrated, defaults: defaults)
        return migrated
    }

    public static func meetingAudioRetentionDeleteAfterDays(defaults: UserDefaults = .standard) -> Int {
        MeetingAudioRetention.normalizedDeleteAfterDays(
            defaults.object(forKey: meetingAudioRetentionDeleteAfterDaysKey) as? Int
                ?? MeetingAudioRetention.defaultDeleteAfterDays
        )
    }

    public static func saveMeetingAudioRetention(
        _ retention: MeetingAudioRetention,
        defaults: UserDefaults = .standard
    ) {
        let normalized = MeetingAudioRetention.make(
            mode: retention.mode,
            days: retention.deleteAfterDays
        )
        defaults.set(normalized.storageRawValue, forKey: meetingAudioRetentionKey)
        if case .deleteAfterDays(let days) = normalized {
            defaults.set(days, forKey: meetingAudioRetentionDeleteAfterDaysKey)
        } else if defaults.object(forKey: meetingAudioRetentionDeleteAfterDaysKey) == nil {
            defaults.set(
                MeetingAudioRetention.defaultDeleteAfterDays,
                forKey: meetingAudioRetentionDeleteAfterDaysKey
            )
        }
        defaults.set(normalized.shouldSaveFreshAudio, forKey: saveMeetingAudioKey)
    }
}
