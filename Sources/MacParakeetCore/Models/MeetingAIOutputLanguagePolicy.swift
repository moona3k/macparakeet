import Foundation

/// Policy for the language of generated AI prompt results (summaries,
/// chapters, action items, and custom prompts) for any transcript source.
/// This does not change speech recognition or the stored transcript. Do not
/// use Parakeet detected-language metadata.
public enum MeetingAIOutputLanguagePolicy: Equatable, Hashable, Sendable, Identifiable {
    case followTranscript
    case language(String)

    public static let english = MeetingAIOutputLanguagePolicy.language("en")
    public static let `default` = MeetingAIOutputLanguagePolicy.followTranscript

    public var id: String { configurationValue }

    public var configurationValue: String {
        switch self {
        case .followTranscript:
            return "follow-transcript"
        case .language(let code):
            return code
        }
    }

    public var displayTitle: String {
        switch self {
        case .followTranscript:
            return "Follow transcript"
        case .language(let code):
            return Self.displayName(for: code)
        }
    }

    public var detail: String {
        switch self {
        case .followTranscript:
            return
                "Matches the main language of each transcript. English is used when the language is mixed or unclear."
        case .language:
            return "Always writes results in \(displayTitle), including headings, whatever language was spoken."
        }
    }

    /// Instruction appended at assemble time. Extra instructions are appended
    /// after this so an explicit user request still wins.
    public var assemblyInstruction: String {
        switch self {
        case .followTranscript:
            return """
                Write the result, including headings, in the predominant language of the transcript. \
                Determine the language from the transcript text, not from these instructions or the meeting notes. \
                If there is no clear predominant language, use English. Preserve names and necessary technical terms. \
                If additional instructions explicitly specify an output language, follow that instead.
                """
        case .language(let code):
            let name = Self.displayName(for: code)
            return """
                Write the result, including headings, in \(name). Preserve names and necessary technical terms. \
                If additional instructions explicitly specify an output language, follow that instead.
                """
        }
    }

    /// Accepts `follow-transcript`, any catalog language code, a regional tag
    /// such as `ko-KR`, or an English language name such as `korean`. Stores
    /// the canonical catalog code.
    public init?(configurationValue: String) {
        let trimmed = configurationValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "follow-transcript" || trimmed == "follow_transcript" {
            self = .followTranscript
            return
        }
        guard let language = WhisperLanguageCatalog.language(forCode: trimmed) else {
            return nil
        }
        self = .language(language.code)
    }

    public static func current(defaults: UserDefaults = .standard) -> MeetingAIOutputLanguagePolicy {
        guard let raw = defaults.string(forKey: UserDefaultsAppRuntimePreferences.meetingAIOutputLanguagePolicyKey),
            let policy = MeetingAIOutputLanguagePolicy(configurationValue: raw)
        else {
            return .default
        }
        return policy
    }

    public static func save(_ policy: MeetingAIOutputLanguagePolicy, defaults: UserDefaults = .standard) {
        defaults.set(
            policy.configurationValue, forKey: UserDefaultsAppRuntimePreferences.meetingAIOutputLanguagePolicyKey)
    }

    private static func displayName(for code: String) -> String {
        WhisperLanguageCatalog.language(forCode: code)?.englishName ?? code
    }
}
