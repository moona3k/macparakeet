import Foundation
import GRDB

public struct Prompt: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var content: String
    public var category: Category
    public var isBuiltIn: Bool
    public var isVisible: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public enum Category: String, Codable, Sendable {
        case summary
        case transform
    }

    public init(
        id: UUID = UUID(),
        name: String,
        content: String,
        category: Category = .summary,
        isBuiltIn: Bool = false,
        isVisible: Bool = true,
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
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static var defaultPrompt: Prompt {
        builtInPrompts().first(where: { $0.name == "General Summary" }) ?? builtInPrompts()[0]
    }

    private static func makeBuiltInPrompt(
        id: String,
        name: String,
        content: String,
        sortOrder: Int,
        now: Date
    ) -> Prompt {
        Prompt(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            content: content,
            category: .summary,
            isBuiltIn: true,
            sortOrder: sortOrder,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Community prompts defined as Swift constants.
    /// The canonical list also lives in Resources/community-prompts.json for community PRs.
    public static func builtInPrompts(now: Date = Date()) -> [Prompt] {
        [
            makeBuiltInPrompt(
                id: "A4882688-E72C-415A-9A5E-1F6AC82DF0D0",
                name: "General Summary",
                content: "You are a helpful assistant that summarizes transcripts. Provide a clear, concise summary that captures the key points, decisions, and action items. Use bullet points for clarity. Keep the summary under 500 words.",
                sortOrder: 0,
                now: now
            ),
            makeBuiltInPrompt(
                id: "FF4C9E18-0E21-4F58-82B2-EA5A3177908D",
                name: "Meeting Notes",
                content: "Summarize this transcript as structured meeting notes. Include: a one-line meeting purpose, attendees mentioned, key discussion points as bullet points, decisions made, and action items with owners if mentioned. Use clear headings.",
                sortOrder: 1,
                now: now
            ),
            makeBuiltInPrompt(
                id: "65A093C3-2732-4628-8A5C-1F722BCBE736",
                name: "Action Items",
                content: "Extract all action items, tasks, and commitments from this transcript. For each item include: what needs to be done, who is responsible (if mentioned), and any deadline or timeline mentioned. Format as a numbered list. If no clear action items exist, say so.",
                sortOrder: 2,
                now: now
            ),
            makeBuiltInPrompt(
                id: "E635AA95-3228-4AB9-B66B-CF3BAF620CFE",
                name: "Key Quotes",
                content: "Extract the most important and notable quotes from this transcript. Include exact wording where possible, with enough surrounding context to understand the significance. Attribute quotes to speakers if identified. List 5–10 quotes, ordered by importance.",
                sortOrder: 3,
                now: now
            ),
            makeBuiltInPrompt(
                id: "A97D4655-241A-421E-A967-CF2951B67B17",
                name: "Study Notes",
                content: "Summarize this transcript as study notes. Extract key concepts, definitions, and explanations. Organize by topic with clear headings. Include any examples or analogies that aid understanding. End with a brief list of key terms.",
                sortOrder: 4,
                now: now
            ),
            makeBuiltInPrompt(
                id: "00C9B6AE-540D-418E-B55F-9AB4C31C5B38",
                name: "Bullet Points",
                content: "Summarize this transcript as a concise bullet-point list. Each bullet should capture one distinct point, fact, or idea. Aim for 10–20 bullets. No sub-bullets. Order by importance, not chronology.",
                sortOrder: 5,
                now: now
            ),
            makeBuiltInPrompt(
                id: "F87B8B91-6EAD-4E48-B9D3-4D56E0FAE679",
                name: "Executive Brief",
                content: "Write a 2–3 paragraph executive brief of this transcript. First paragraph: the core topic and why it matters. Second paragraph: key findings, decisions, or conclusions. Third paragraph (if needed): next steps or open questions. Write for a busy reader who needs the essential takeaway in under 60 seconds.",
                sortOrder: 6,
                now: now
            ),
        ]
    }
}

extension Prompt: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "prompts"

    public enum Columns: String, ColumnExpression {
        case id, name, content, category, isBuiltIn, isVisible, sortOrder, createdAt, updatedAt
    }
}
