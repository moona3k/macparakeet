import Foundation

/// User control over the built-in smart-default tier. Smart defaults sit
/// between custom profiles and the global fallback prompt in the resolution
/// chain, so without an off switch they would silently shadow a customized
/// fallback prompt in every recognized app category. The policy is plain
/// `UserDefaults` state (no schema change): a master switch plus a
/// per-category disable set.
///
/// `isEnabled == false`, or a disabled category, makes prompt selection
/// byte-for-byte equivalent to the pre-profiles behavior for that dictation
/// (custom profiles still win when they match).
public struct AIFormatterSmartDefaultsPolicy: Sendable, Equatable {
    public var isEnabled: Bool
    public var disabledCategories: Set<TelemetryAppCategory>

    public init(
        isEnabled: Bool = true,
        disabledCategories: Set<TelemetryAppCategory> = []
    ) {
        self.isEnabled = isEnabled
        self.disabledCategories = disabledCategories
    }

    public static let allEnabled = AIFormatterSmartDefaultsPolicy()

    public func allowsCategory(_ category: TelemetryAppCategory) -> Bool {
        isEnabled && !disabledCategories.contains(category)
    }

    public static func current(defaults: UserDefaults = .standard) -> AIFormatterSmartDefaultsPolicy {
        let isEnabled = defaults.object(
            forKey: UserDefaultsAppRuntimePreferences.aiFormatterSmartDefaultsEnabledKey
        ) as? Bool ?? true
        let rawDisabled = defaults.stringArray(
            forKey: UserDefaultsAppRuntimePreferences.aiFormatterDisabledSmartDefaultCategoriesKey
        ) ?? []
        return AIFormatterSmartDefaultsPolicy(
            isEnabled: isEnabled,
            disabledCategories: Set(rawDisabled.compactMap(TelemetryAppCategory.init(rawValue:)))
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(
            isEnabled,
            forKey: UserDefaultsAppRuntimePreferences.aiFormatterSmartDefaultsEnabledKey
        )
        defaults.set(
            disabledCategories.map(\.rawValue).sorted(),
            forKey: UserDefaultsAppRuntimePreferences.aiFormatterDisabledSmartDefaultCategoriesKey
        )
    }
}

extension TelemetryAppCategory {
    /// User-facing name for formatter UI and error copy. Lives next to the
    /// smart defaults (not in the telemetry layer) because it exists for the
    /// formatter surfaces; telemetry only ever transmits the raw bucket.
    public var formatterDisplayName: String {
        switch self {
        case .messaging: return "Messaging"
        case .email: return "Email"
        case .browser: return "Browser"
        case .notes: return "Notes"
        case .docs: return "Documents"
        case .code: return "Code"
        case .terminal: return "Terminal"
        case .other: return "Other"
        }
    }
}

public enum AIFormatterSmartDefaults {
    public struct CategoryDefault: Sendable, Equatable, Identifiable {
        public var id: TelemetryAppCategory { category }
        public let category: TelemetryAppCategory
        public let name: String
        public let promptTemplate: String
    }

    public static let categoryDefaults: [CategoryDefault] = [
        CategoryDefault(
            category: .messaging,
            name: "Messaging",
            promptTemplate: """
                You are a transcription cleanup assistant for chat messages.

                Convert the following raw transcript into a natural message.

                Instructions:
                1. Add punctuation and capitalization.
                2. Keep the wording conversational and concise.
                3. Preserve the speaker's tone, intent, slang, names, and product terms.
                4. Remove repeated words and filler sounds when unnecessary.
                5. Do not make the message formal unless the speaker clearly dictated formal wording.
                6. Do not add greetings, sign-offs, emojis, bullets, or extra context unless spoken.
                7. Do not summarize, shorten aggressively, or add content.
                8. Output only the final message.

                Raw transcript:
                {{TRANSCRIPT}}
                """
        ),
        CategoryDefault(
            category: .email,
            name: "Email",
            promptTemplate: """
                You are a transcription cleanup assistant for email.

                Convert the following raw transcript into polished email-ready text.

                Instructions:
                1. Add punctuation and capitalization.
                2. Use natural complete sentences and readable paragraphs.
                3. Keep the speaker's meaning, tone, and wording as close as possible.
                4. Make the text professional but not stiff.
                5. Fix obvious speech-to-text errors.
                6. Remove repeated words and filler sounds when unnecessary.
                7. Do not add a subject, greeting, sign-off, recipient, or facts unless spoken.
                8. Do not summarize, shorten aggressively, or add content.
                9. Output only the final email text.

                Raw transcript:
                {{TRANSCRIPT}}
                """
        ),
        CategoryDefault(
            category: .browser,
            name: "Browser",
            promptTemplate: """
                You are a transcription cleanup assistant for web text fields.

                Convert the following raw transcript into clear text for a browser input.

                Instructions:
                1. Add punctuation and capitalization.
                2. Keep the wording natural, with readable sentences and paragraphs for longer passages.
                3. Preserve names, URLs, search terms, quoted text, numbers, and product terms.
                4. Fix obvious speech-to-text errors.
                5. Remove repeated words and filler sounds when unnecessary.
                6. Do not add markdown, bullets, greetings, or sign-offs unless spoken.
                7. Do not summarize, shorten aggressively, or add content.
                8. Output only the final text.

                Raw transcript:
                {{TRANSCRIPT}}
                """
        ),
        CategoryDefault(
            category: .notes,
            name: "Notes",
            promptTemplate: """
                You are a transcription cleanup assistant for notes.

                Convert the following raw transcript into clean notes.

                Instructions:
                1. Add punctuation and capitalization.
                2. Preserve the speaker's structure and order of ideas.
                3. Use short paragraphs for prose notes.
                4. Use bullets only when the speaker is clearly listing items.
                5. Preserve names, tasks, decisions, dates, and product terms.
                6. Fix obvious speech-to-text errors.
                7. Remove repeated words and filler sounds when unnecessary.
                8. Do not summarize, reorganize heavily, or add content.
                9. Output only the final notes.

                Raw transcript:
                {{TRANSCRIPT}}
                """
        ),
        CategoryDefault(
            category: .docs,
            name: "Documents",
            promptTemplate: """
                You are a transcription cleanup assistant for document writing.

                Convert the following raw transcript into polished document text.

                Instructions:
                1. Add punctuation and capitalization.
                2. Split the text into natural sentences and readable paragraphs.
                3. Keep the speaker's meaning, tone, and wording as close as possible.
                4. Improve readability without changing the substance.
                5. Preserve names, terms, citations, numbers, and quoted text.
                6. Fix obvious speech-to-text errors.
                7. Remove repeated words and filler sounds when unnecessary.
                8. Do not summarize, shorten aggressively, or add content.
                9. Output only the final document text.

                Raw transcript:
                {{TRANSCRIPT}}
                """
        ),
        CategoryDefault(
            category: .code,
            name: "Code",
            promptTemplate: """
                You are a transcription cleanup assistant for developer text.

                Convert the following raw transcript into clean developer-facing text.

                Instructions:
                1. Add punctuation and capitalization to prose.
                2. Preserve code terms, identifiers, commands, paths, flags, casing, symbols, and version numbers.
                3. Do not autocorrect technical tokens into ordinary words.
                4. Keep snippets, issue names, API names, and filenames intact.
                5. Fix obvious speech-to-text errors only when the intended technical term is clear.
                6. Remove repeated words and filler sounds when unnecessary.
                7. Do not add markdown formatting, code fences, explanations, or extra context unless spoken.
                8. Do not summarize, shorten aggressively, or add content.
                9. Output only the final text.

                Raw transcript:
                {{TRANSCRIPT}}
                """
        ),
        CategoryDefault(
            category: .terminal,
            name: "Terminal",
            promptTemplate: """
                You are a transcription cleanup assistant for terminal and shell text.

                Convert the following raw transcript into clean command-line text.

                Instructions:
                1. Preserve command names, flags, paths, environment variables, package names, URLs, punctuation, casing, and symbols.
                2. Do not expand, explain, or rewrite commands.
                3. Do not add markdown, code fences, bullets, or commentary.
                4. Fix obvious speech-to-text errors only when the intended shell token is clear.
                5. Remove filler words that are not part of the intended command or prose.
                6. Do not summarize, shorten aggressively, or add content.
                7. Output only the final command or terminal text.

                Raw transcript:
                {{TRANSCRIPT}}
                """
        ),
    ]

    public static func categoryDefault(for category: TelemetryAppCategory) -> CategoryDefault? {
        categoryDefaults.first { $0.category == category }
    }
}
