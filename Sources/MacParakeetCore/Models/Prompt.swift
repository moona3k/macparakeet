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

    public static var defaultSummaryPrompt: Prompt {
        builtInSummaryPrompts()[0]
    }

    public static func builtInSummaryPrompts(now: Date = Date()) -> [Prompt] {
        [
            Prompt(
                name: "Concise Summary",
                content: """
                    Summarize this transcript clearly and concisely. Capture the key points, decisions, and action items. Use bullet points for clarity. Keep it under 500 words.
                    """,
                category: .summary,
                isBuiltIn: true,
                isVisible: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now
            ),
            Prompt(
                name: "Detailed Summary",
                content: """
                    Provide a comprehensive, structured summary of this transcript. Organize by topic with clear headings. Include key discussion points, decisions made, action items with owners if mentioned, and any notable quotes or insights. Be thorough — capture the full substance of the conversation.
                    """,
                category: .summary,
                isBuiltIn: true,
                isVisible: true,
                sortOrder: 1,
                createdAt: now,
                updatedAt: now
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
