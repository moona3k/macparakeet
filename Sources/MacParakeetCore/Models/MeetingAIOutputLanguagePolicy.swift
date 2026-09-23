import Foundation

/// Policy for the language of generated meeting AI results (summary, chapters,
/// action items). This does not change speech recognition or the stored
/// transcript. Do not use Parakeet detected-language metadata.
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
                "Ask the model to write results in the predominant language of the transcript text. Mixed or unclear transcripts fall back to English."
        case .language(let code) where code == "en":
            return "Always write meeting AI results in English, including headings."
        case .language:
            return "Always write meeting AI results in \(displayTitle), including headings."
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

    public static let pickerCases: [MeetingAIOutputLanguagePolicy] = [
        .followTranscript,
        .language("en"),
        .language("pl"),
        .language("de"),
        .language("es"),
        .language("fr"),
        .language("pt"),
        .language("ja"),
        .language("zh"),
    ]

    public static var configurationValues: [String] {
        pickerCases.map(\.configurationValue)
    }

    public init?(configurationValue: String) {
        let trimmed = configurationValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "follow-transcript" || trimmed == "follow_transcript" {
            self = .followTranscript
            return
        }
        guard
            Self.pickerCases.contains(where: {
                if case .language(let code) = $0 { return code == trimmed }
                return false
            })
        else {
            return nil
        }
        self = .language(trimmed)
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
        switch code {
        case "en": return "English"
        case "pl": return "Polish"
        case "de": return "German"
        case "es": return "Spanish"
        case "fr": return "French"
        case "pt": return "Portuguese"
        case "ja": return "Japanese"
        case "zh": return "Chinese"
        default: return code
        }
    }
}
