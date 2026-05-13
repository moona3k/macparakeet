import Foundation
import GRDB

public struct TransformProfile: Codable, Identifiable, Sendable, Equatable {
    public var promptId: UUID
    public var enabledRuleIDsJSON: String
    public var customInstructions: String?
    public var useWritingSamples: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public var id: UUID { promptId }

    public init(
        promptId: UUID,
        enabledRuleIDsJSON: String,
        customInstructions: String? = nil,
        useWritingSamples: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.promptId = promptId
        self.enabledRuleIDsJSON = enabledRuleIDsJSON
        self.customInstructions = customInstructions
        self.useWritingSamples = useWritingSamples
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var enabledRuleIDs: Set<String> {
        guard let data = enabledRuleIDsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return Set(decoded)
    }

    public mutating func setEnabledRuleIDs(_ ids: Set<String>) {
        let sorted = ids.sorted()
        let data = (try? JSONEncoder().encode(sorted)) ?? Data("[]".utf8)
        enabledRuleIDsJSON = String(data: data, encoding: .utf8) ?? "[]"
        updatedAt = Date()
    }

    public static func defaultProfile(for prompt: Prompt, now: Date = Date()) -> TransformProfile {
        let defaultIDs = Set(TransformRule.rules(for: prompt).filter(\.defaultEnabled).map(\.id))
        let data = (try? JSONEncoder().encode(defaultIDs.sorted())) ?? Data("[]".utf8)
        return TransformProfile(
            promptId: prompt.id,
            enabledRuleIDsJSON: String(data: data, encoding: .utf8) ?? "[]",
            createdAt: now,
            updatedAt: now
        )
    }
}

extension TransformProfile: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transform_profiles"

    public enum Columns: String, ColumnExpression {
        case promptId
        case enabledRuleIDsJSON
        case customInstructions
        case useWritingSamples
        case createdAt
        case updatedAt
    }
}
