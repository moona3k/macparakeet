import Foundation

/// What kind of cards to make from a transcript.
public enum FlashcardStyle: String, CaseIterable, Identifiable, Sendable {
    /// Words and phrases worth learning, with their meaning.
    case vocabulary
    /// Questions and answers about what was said.
    case questions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vocabulary: return "Vocabulary"
        case .questions: return "Questions & answers"
        }
    }
}

/// Learner level on the CEFR scale. Vocabulary cards target this level.
public enum FlashcardLevel: String, CaseIterable, Identifiable, Sendable {
    case a1 = "A1", a2 = "A2", b1 = "B1", b2 = "B2", c1 = "C1", c2 = "C2"

    public var id: String { rawValue }
}

/// Topic area the cards should focus on, as in LinguaBrain's categories.
/// Custom names fall back to a generic scope built from the name.
public enum FlashcardCategory {
    public static let presets = ["General", "Work", "Software", "Medical", "Driving"]

    static func scope(for category: String) -> String {
        switch category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "general":
            return "common everyday situations, practical communication, home, travel, services, relationships, news and public life"
        case "work":
            return "workplaces, professions, tasks, meetings, employment, applications, contracts, schedules, collaboration and professional communication"
        case "software":
            return "software development, applications, interfaces, data, debugging, security, deployment, technical documentation and workplace communication"
        case "medical":
            return "healthcare, symptoms, anatomy, diagnosis, treatment, medication, appointments, hospitals, emergencies and communication with patients"
        case "driving":
            return "driving and road traffic, driving-licence tests, traffic laws, signs and signals, vehicles, hazards, accidents, fines, insurance and licensing"
        default:
            return "the topic '\(category)' and its terminology, actors, objects, places, actions, rules, processes, documents and real-world conversations"
        }
    }
}

/// Optional targeting for generated cards.
public struct FlashcardFocus: Equatable, Sendable {
    /// Nil means any level.
    public var level: FlashcardLevel?
    /// Empty or "General" means everyday language.
    public var category: String

    public init(level: FlashcardLevel? = nil, category: String = "General") {
        self.level = level
        self.category = category
    }
}

public protocol FlashcardGenerating: Sendable {
    func generate(
        from transcript: String,
        style: FlashcardStyle,
        meaningLanguage: TranslationLanguage,
        maxCards: Int,
        focus: FlashcardFocus
    ) async throws -> [FlashcardDraft]
}

public enum FlashcardGenerationError: Error, LocalizedError, Equatable {
    case emptyTranscript
    case noCards

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript: return "There is no transcript text to make cards from."
        case .noCards: return "The AI provider did not return any usable cards. Try again or use a stronger model."
        }
    }
}

/// Generates flashcard drafts with the configured AI provider. Long
/// transcripts are trimmed to stay inside small context windows.
public struct FlashcardGenerationService: FlashcardGenerating {
    static let maxTranscriptCharacters = 24_000

    private let llmService: LLMServiceProtocol

    public init(llmService: LLMServiceProtocol) {
        self.llmService = llmService
    }

    public func generate(
        from transcript: String,
        style: FlashcardStyle,
        meaningLanguage: TranslationLanguage,
        maxCards: Int,
        focus: FlashcardFocus = FlashcardFocus()
    ) async throws -> [FlashcardDraft] {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FlashcardGenerationError.emptyTranscript }
        let clipped = String(text.prefix(Self.maxTranscriptCharacters))

        let response = try await llmService.generatePromptResult(
            transcript: clipped,
            systemPrompt: Self.systemPrompt(style: style, language: meaningLanguage, maxCards: maxCards, focus: focus)
        )
        let drafts = Array(Self.parse(response).prefix(maxCards))
        guard !drafts.isEmpty else { throw FlashcardGenerationError.noCards }
        return drafts
    }

    static func systemPrompt(
        style: FlashcardStyle,
        language: TranslationLanguage,
        maxCards: Int,
        focus: FlashcardFocus = FlashcardFocus()
    ) -> String {
        let scope = FlashcardCategory.scope(for: focus.category)
        let levelRule = focus.level.map {
            "- Choose items suitable for a learner at CEFR level \($0.rawValue): skip what is clearly below that level and what is far above it."
        } ?? ""
        let task: String
        switch style {
        case .vocabulary:
            task = """
                Pick up to \(maxCards) words or short phrases from the transcript that are most useful for a language learner to memorize (skip names and trivial words).
                - Prefer items related to \(scope).
                \(levelRule)
                - "front": the word or phrase exactly as used, in the transcript's language (for nouns include the article if the language has one).
                - "back": its meaning in \(language.displayName) (\(language.nativeName)), short.
                - "context": the sentence from the transcript where it appears.
                """
        case .questions:
            task = """
                Write up to \(maxCards) flashcards that test the key facts, ideas, and decisions in the transcript.
                - Focus on what relates to \(scope).
                \(levelRule.replacingOccurrences(of: "Choose items", with: "Phrase questions"))
                - "front": a clear, self-contained question in \(language.displayName) (\(language.nativeName)).
                - "back": a short answer in \(language.displayName).
                - "context": the transcript sentence that supports the answer.
                """
        }
        return """
            You create Anki flashcards from a transcript.

            \(task)

            Output ONLY a JSON array, no prose and no code fences, like:
            [{"front": "...", "back": "...", "context": "..."}]
            """
    }

    /// Parses the model's JSON array, tolerating code fences or a preamble.
    static func parse(_ response: String) -> [FlashcardDraft] {
        guard let start = response.firstIndex(of: "["), let end = response.lastIndex(of: "]"), start < end,
            let data = String(response[start...end]).data(using: .utf8),
            let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        var seen = Set<String>()
        return items.compactMap { item in
            let front = (item["front"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let back = (item["back"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let context = (item["context"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !front.isEmpty, !back.isEmpty, seen.insert(front.lowercased()).inserted else { return nil }
            return FlashcardDraft(front: front, back: back, context: (context?.isEmpty ?? true) ? nil : context)
        }
    }
}
