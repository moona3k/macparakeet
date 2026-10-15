import Foundation
import NaturalLanguage

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

    /// Instruction for a concrete transcript. With `.followTranscript`, a
    /// confidently detected non-English language is named explicitly, because
    /// models given English instructions tend to drift into English.
    public func assemblyInstruction(forTranscript transcript: String?) -> String {
        guard case .followTranscript = self, let transcript,
            let code = Self.detectedLanguageCode(in: transcript), code != "en"
        else { return assemblyInstruction }
        let name = Self.displayName(for: code)
        return assemblyInstruction + " "
            + "The transcript's predominant language was detected as \(name), so write the result in \(name)."
    }

    /// On-device language detection; nil when the text is short or ambiguous.
    static func detectedLanguageCode(in text: String) -> String? {
        let sample = String(text.prefix(4_000))
        guard sample.count >= 40 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
            confidence >= 0.6
        else { return nil }
        let code = String(language.rawValue.prefix(while: { $0 != "-" })).lowercased()
        return WhisperLanguageCatalog.language(forCode: code) == nil ? nil : code
    }

    private static func displayName(for code: String) -> String {
        WhisperLanguageCatalog.language(forCode: code)?.englishName ?? code
    }
}
