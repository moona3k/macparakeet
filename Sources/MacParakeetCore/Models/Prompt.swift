import Foundation
import GRDB

public struct Prompt: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var content: String
    public var category: Category
    public var isBuiltIn: Bool
    public var isVisible: Bool
    public var isAutoRun: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public enum Category: String, Codable, Sendable {
        // Keep the stored raw value as "summary" until the prompts table itself is migrated.
        case result = "summary"
        case transform
    }

    public init(
        id: UUID = UUID(),
        name: String,
        content: String,
        category: Category = .result,
        isBuiltIn: Bool = false,
        isVisible: Bool = true,
        isAutoRun: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.category = category
        self.isBuiltIn = isBuiltIn
        self.isVisible = isVisible
        self.isAutoRun = isAutoRun
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Used for migrations and compatibility paths that need a canonical built-in summary prompt.
    // This is not a fallback for the explicit "no auto-run prompts enabled" state.
    public static var defaultPrompt: Prompt {
        builtInPrompts().first(where: { $0.isAutoRun }) ?? builtInPrompts()[0]
    }

    private static func makeBuiltInPrompt(
        id: String,
        name: String,
        content: String,
        isAutoRun: Bool = false,
        sortOrder: Int,
        now: Date
    ) -> Prompt {
        Prompt(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            content: content,
            category: .result,
            isBuiltIn: true,
            isAutoRun: isAutoRun,
            sortOrder: sortOrder,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Built-in prompt definitions shipped with the app.
    /// `community-prompts.json` is kept in sync as a contribution/reference artifact.
    public static func builtInPrompts(now: Date = Date()) -> [Prompt] {
        [
            makeBuiltInPrompt(
                id: "A4882688-E72C-415A-9A5E-1F6AC82DF0D0",
                name: "Summary",
                content: """
                    Analyze this transcript and produce a structured summary.

                    Open with a single sentence that captures what this is about and why it matters. Then organize the rest under clear headings:

                    **Key Points** — The 3–7 most important ideas, findings, or arguments. Each should be a complete thought, not a fragment. If speakers are identified, attribute claims to them.

                    **Decisions & Outcomes** — Anything that was agreed upon, concluded, or resolved. If nothing was decided, omit this section entirely — don't fabricate consensus.

                    **Open Questions** — Unresolved threads, disagreements, or topics raised but not settled. Only include these if they're genuinely unresolved in the transcript.

                    Be direct. Prefer specifics over generalizations — names, numbers, and concrete details beat vague summaries. If the transcript is short or straightforward, keep the output proportionally brief. Don't pad.
                    """.replacingOccurrences(of: "                    ", with: ""),
                isAutoRun: true,
                sortOrder: 0,
                now: now
            ),
            makeBuiltInPrompt(
                id: "65A093C3-2732-4628-8A5C-1F722BCBE736",
                name: "Action Items & Decisions",
                content: """
                    Extract every concrete commitment, task, and decision from this transcript.

                    **Decisions Made**
                    List each decision as a single clear statement. Include who made or endorsed it if identifiable. Only list things that were actually decided — not proposals that were merely floated.

                    **Action Items**
                    For each task or commitment:
                    - What needs to happen (specific enough to act on)
                    - Who owns it (if stated or clearly implied)
                    - When it's due (if any timeline was mentioned — use exact wording as spoken, don't convert or guess)

                    **Needs Follow-Up**
                    Anything flagged as needing attention but with no clear owner or next step yet.

                    If the transcript contains no clear actions or decisions, say so plainly — don't invent structure where none exists. Order items by the sequence they appeared.
                    """.replacingOccurrences(of: "                    ", with: ""),
                sortOrder: 1,
                now: now
            ),
            makeBuiltInPrompt(
                id: "FF4C9E18-0E21-4F58-82B2-EA5A3177908D",
                name: "Chapter Breakdown",
                content: """
                    Break this transcript into logical chapters or segments.

                    For each chapter:
                    - **Title** — A concise, descriptive name (not generic labels like "Discussion 1" or "Part 2")
                    - **Summary** — 2–4 sentences capturing what happened in this segment
                    - **Notable Moments** — Any standout quotes, turning points, or key data points (attribute to the speaker if identifiable)

                    Chapters should reflect natural topic shifts, not arbitrary time splits. A short transcript might have 2–3 chapters; a long one might have 8–12. Let the content dictate the structure.

                    If the transcript is a monologue (lecture, presentation, solo recording), organize by topic or argument progression instead of conversational turns.
                    """.replacingOccurrences(of: "                    ", with: ""),
                sortOrder: 2,
                now: now
            ),
            makeBuiltInPrompt(
                id: "A97D4655-241A-421E-A967-CF2951B67B17",
                name: "Study Guide",
                content: """
                    Transform this transcript into a learning resource.

                    **Overview** — One paragraph: what is being taught or discussed, and who would benefit from understanding it.

                    **Key Concepts** — Each concept gets:
                    - A clear, jargon-free explanation
                    - An example or analogy from the transcript (quote directly when useful)
                    - Why it matters or how it connects to the bigger picture

                    **Common Misconceptions** — If the speaker corrects misunderstandings, challenges assumptions, or contrasts their view with a popular one, capture those moments. Omit this section if none exist.

                    **Review Questions** — 3–5 questions to test understanding. Favor questions that require thinking over recall — "Why does X matter?" over "What is X?"

                    **Key Terms** — Specialized vocabulary worth remembering, with concise definitions drawn from context.

                    Write for someone encountering this material for the first time. Prioritize understanding over completeness.
                    """.replacingOccurrences(of: "                    ", with: ""),
                sortOrder: 3,
                now: now
            ),
            makeBuiltInPrompt(
                id: "00C9B6AE-540D-418E-B55F-9AB4C31C5B38",
                name: "Blog Post",
                content: """
                    Rewrite this transcript as a well-crafted blog post that stands entirely on its own — a reader who never heard the original should find it clear, engaging, and complete. Never reference "the transcript" or "the recording."

                    **Title** — Specific and compelling. Not clickbait, not boring.

                    **Opening** — Hook the reader with the most interesting or surprising point. No throat-clearing or background preamble.

                    **Body** — Develop the key ideas in a logical flow. Use direct quotes from speakers to add texture and credibility (attribute them by name). Break up dense sections with subheadings.

                    **Closing** — End with a takeaway, provocation, or call to reflection — not a generic "In conclusion."

                    Write in a clear, conversational tone. Vary sentence length. Cut filler. If the original conversation wandered or repeated itself, reorganize for the reader's benefit — the post should be tighter than the transcript, not a 1:1 rewrite.
                    """.replacingOccurrences(of: "                    ", with: ""),
                sortOrder: 4,
                now: now
            ),
            makeBuiltInPrompt(
                id: "F87B8B91-6EAD-4E48-B9D3-4D56E0FAE679",
                name: "What Stood Out",
                content: """
                    Read this transcript closely and surface what's easy to miss. Don't summarize — the reader already knows what was discussed. Instead, focus on:

                    **Underlying Tensions** — Where did people talk past each other, avoid a topic, or agree too quickly? What wasn't said that probably should have been?

                    **Surprising Moments** — Anything unexpected: a reversal of position, an offhand remark that revealed more than intended, a data point that contradicts the prevailing narrative.

                    **Patterns** — Recurring themes, repeated concerns, or ideas that surfaced in different forms across the conversation. What's the through-line the participants themselves might not have named?

                    **Strongest Claim, Weakest Evidence** — Identify the most confidently stated position that had the least support. Not adversarial — just flagging where the group might be over-indexing on confidence.

                    Be specific and grounded in the text. Every observation should point to a concrete moment in the transcript. If you're speculating, say so.
                    """.replacingOccurrences(of: "                    ", with: ""),
                sortOrder: 5,
                now: now
            ),
        ]
    }
}

extension Prompt: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "prompts"

    public enum Columns: String, ColumnExpression {
        case id, name, content, category, isBuiltIn, isVisible, isAutoRun, sortOrder, createdAt, updatedAt
    }
}
