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
        focus: FlashcardFocus,
        excluding knownKeys: Set<String>
    ) async throws -> [FlashcardDraft]
}

public enum FlashcardGenerationError: Error, LocalizedError, Equatable {
    case emptyTranscript
    case noCards
    case allWordsKnown

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript: return "There is no transcript text to make cards from."
        case .noCards: return "The AI provider did not return any usable cards. Try again or use a stronger model."
        case .allWordsKnown: return "Every word found in this transcript is already in your decks."
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
        focus: FlashcardFocus = FlashcardFocus(),
        excluding knownKeys: Set<String> = []
    ) async throws -> [FlashcardDraft] {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FlashcardGenerationError.emptyTranscript }
        let clipped = String(text.prefix(Self.maxTranscriptCharacters))

        guard style == .vocabulary else {
            let response = try await llmService.generatePromptResult(
                transcript: clipped,
                systemPrompt: Self.systemPrompt(style: style, language: meaningLanguage, maxCards: maxCards, focus: focus)
            )
            let drafts = Array(Self.parse(response).prefix(maxCards))
            guard !drafts.isEmpty else { throw FlashcardGenerationError.noCards }
            return drafts
        }

        // Step 1: the AI pulls out the words (in dictionary form). Ask for
        // extra so enough remain after dropping words the decks already have.
        let extraction = try await llmService.generatePromptResult(
            transcript: clipped,
            systemPrompt: Self.systemPrompt(
                style: .vocabulary, language: meaningLanguage, maxCards: maxCards * 2, focus: focus)
        )
        let extracted = Self.parseWords(extraction)
        guard !extracted.isEmpty else { throw FlashcardGenerationError.noCards }
        var seen = knownKeys
        let words = Array(extracted.filter { seen.insert(FlashcardDraft.duplicateKey($0.word)).inserted }.prefix(maxCards))
        guard !words.isEmpty else { throw FlashcardGenerationError.allWordsKnown }

        // Step 2: cards only for the new words.
        try Task.checkCancellation()
        let response = try await llmService.generatePromptResult(
            transcript: Self.wordListInput(words),
            systemPrompt: Self.cardPrompt(language: meaningLanguage)
        )
        let drafts = Self.parse(response).filter { !knownKeys.contains(FlashcardDraft.duplicateKey($0.front)) }
        guard !drafts.isEmpty else { throw FlashcardGenerationError.noCards }
        return Array(drafts.prefix(maxCards))
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
                Extract up to \(maxCards) words or short phrases from the transcript that are most useful for a language learner to memorize (skip names and trivial words).
                - Prefer items related to \(scope).
                \(levelRule)
                - "word": the word or phrase in its dictionary form, in the transcript's language. Verbs ALWAYS go in the infinitive, even when the transcript uses a conjugated form (e.g. "ging" -> "gehen", "went" -> "to go"; separable or reflexive verbs in full, e.g. "anfangen", "sich freuen"). Nouns in the singular with their article if the language has one. Adjectives in their base form.
                - Never list the same word twice, even in different forms.
                - "context": the sentence from the transcript where it appears, exactly as written.
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
            \(style == .vocabulary
                ? "You pick vocabulary for Anki flashcards from a transcript."
                : "You create Anki flashcards from a transcript.")

            \(task)

            Output ONLY a JSON array, no prose and no code fences, like:
            \(style == .vocabulary
                ? #"[{"word": "...", "context": "..."}]"#
                : #"[{"front": "...", "back": "...", "context": "..."}]"#)
            """
    }

    /// Second vocabulary step: turns an already-chosen word list into cards.
    static func cardPrompt(language: TranslationLanguage) -> String {
        """
        You create Anki flashcards for the given words. The input is a JSON array of {"word", "context"} items; make exactly one card per item, in the same order.
        - "front": the word exactly as given (already in dictionary form; verbs in the infinitive).
        - "meanings": every common meaning of the word (a word with several meanings gets one entry per meaning, the one used in "context" first). Each entry has:
          - "meaning": the meaning in \(language.displayName) (\(language.nativeName)), short.
          - "example": a short, natural example sentence in the word's language that uses it in that meaning.
          - "translation": that example sentence translated into \(language.displayName).
        - "context": the given context sentence, unchanged.
        - "context_translation": that sentence translated into \(language.displayName).

        Output ONLY a JSON array, no prose and no code fences, like:
        [{"front": "...", "meanings": [{"meaning": "...", "example": "...", "translation": "..."}], "context": "...", "context_translation": "..."}]
        """
    }

    struct ExtractedWord: Equatable {
        var word: String
        var context: String?
    }

    /// Parses step-1 output, dropping blanks and repeats.
    static func parseWords(_ response: String) -> [ExtractedWord] {
        var seen = Set<String>()
        return jsonItems(response).compactMap { item in
            guard let word = trimmed(item["word"] ?? item["front"]),
                seen.insert(FlashcardDraft.duplicateKey(word)).inserted
            else { return nil }
            return ExtractedWord(word: word, context: trimmed(item["context"]))
        }
    }

    static func wordListInput(_ words: [ExtractedWord]) -> String {
        let items = words.map { ["word": $0.word, "context": $0.context ?? ""] }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonItems(_ response: String) -> [[String: Any]] {
        guard let start = response.firstIndex(of: "["), let end = response.lastIndex(of: "]"), start < end,
            let data = String(response[start...end]).data(using: .utf8),
            let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return items
    }

    /// Parses the model's JSON array, tolerating code fences or a preamble.
    static func parse(_ response: String) -> [FlashcardDraft] {
        var seen = Set<String>()
        return jsonItems(response).compactMap { item in
            let front = (item["front"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let back = formatMeanings(item["meanings"])
                ?? (item["back"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var context = trimmed(item["context"])
            if let context0 = context, let translation = trimmed(item["context_translation"]) {
                context = "\(context0)\n→ \(translation)"
            }
            guard !front.isEmpty, !back.isEmpty, seen.insert(FlashcardDraft.duplicateKey(front)).inserted else { return nil }
            return FlashcardDraft(front: front, back: back, context: context)
        }
    }

    private static func trimmed(_ value: Any?) -> String? {
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// Renders `meanings` as numbered entries, each with its example and the
    /// example's translation. Nil when the model sent no usable meanings.
    static func formatMeanings(_ value: Any?) -> String? {
        guard let entries = value as? [[String: Any]] else { return nil }
        let blocks = entries.compactMap { entry -> String? in
            guard let meaning = trimmed(entry["meaning"]) else { return nil }
            var lines = [meaning]
            if let example = trimmed(entry["example"]) { lines.append("e.g. \(example)") }
            if let translation = trimmed(entry["translation"]) { lines.append("→ \(translation)") }
            return lines.joined(separator: "\n")
        }
        guard !blocks.isEmpty else { return nil }
        if blocks.count == 1 { return blocks[0] }
        return blocks.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n")
    }
}
