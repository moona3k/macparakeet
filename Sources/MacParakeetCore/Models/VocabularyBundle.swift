import Foundation

/// Portable, versioned representation of a user's vocabulary (custom words + text snippets).
///
/// Designed for backup / restore between machines. UUIDs and local-only fields
/// (`source`, `useCount`) are intentionally omitted — they are regenerated on import.
public struct VocabularyBundle: Codable, Sendable, Equatable {
    public static let schemaIdentifier = "macparakeet.vocabulary"
    public static let currentVersion = 1

    public let schema: String
    public let version: Int
    public let exportedAt: Date
    public let appVersion: String?
    public let customWords: [ExportedCustomWord]
    public let textSnippets: [ExportedTextSnippet]

    public init(
        exportedAt: Date,
        appVersion: String?,
        customWords: [ExportedCustomWord],
        textSnippets: [ExportedTextSnippet]
    ) {
        self.schema = Self.schemaIdentifier
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.customWords = customWords
        self.textSnippets = textSnippets
    }

    public struct ExportedCustomWord: Codable, Sendable, Equatable {
        public let word: String
        public let replacement: String?
        public let isEnabled: Bool
        public let createdAt: Date?

        public init(word: String, replacement: String?, isEnabled: Bool, createdAt: Date?) {
            self.word = word
            self.replacement = replacement
            self.isEnabled = isEnabled
            self.createdAt = createdAt
        }
    }

    public struct ExportedTextSnippet: Codable, Sendable, Equatable {
        public let trigger: String
        public let expansion: String
        public let isEnabled: Bool
        public let action: KeyAction?
        public let createdAt: Date?

        public init(
            trigger: String,
            expansion: String,
            isEnabled: Bool,
            action: KeyAction?,
            createdAt: Date?
        ) {
            self.trigger = trigger
            self.expansion = expansion
            self.isEnabled = isEnabled
            self.action = action
            self.createdAt = createdAt
        }
    }
}
