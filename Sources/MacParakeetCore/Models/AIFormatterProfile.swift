import Foundation
import GRDB

public enum AIFormatterProfileTargetKind: String, Codable, Sendable, CaseIterable {
    case bundle
    case category
}

public enum AIFormatterProfileMatchKind: String, Codable, Sendable, Equatable, CaseIterable {
    case exactApp = "exact_app"
    case category
    case global
}

public enum AIFormatterProfileOrigin: String, Codable, Sendable, Equatable, CaseIterable {
    case custom
    case template
}

public struct AIFormatterProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var targetKind: AIFormatterProfileTargetKind
    public var bundleIdentifier: String?
    public var appDisplayName: String?
    public var appCategory: TelemetryAppCategory?
    public var promptTemplate: String
    public var origin: AIFormatterProfileOrigin
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        targetKind: AIFormatterProfileTargetKind,
        bundleIdentifier: String? = nil,
        appDisplayName: String? = nil,
        appCategory: TelemetryAppCategory? = nil,
        promptTemplate: String,
        origin: AIFormatterProfileOrigin = .custom,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEnabled = isEnabled
        self.targetKind = targetKind
        self.bundleIdentifier = AppPromptContext.normalizedBundleIdentifier(bundleIdentifier)
        self.appDisplayName = AppPromptContext.normalizedDisplayName(appDisplayName)
        self.appCategory = appCategory
        self.promptTemplate = AIFormatter.normalizedPromptTemplate(promptTemplate)
        self.origin = origin
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func exactApp(
        name: String,
        bundleIdentifier: String,
        appDisplayName: String? = nil,
        promptTemplate: String,
        isEnabled: Bool = true,
        origin: AIFormatterProfileOrigin = .custom,
        sortOrder: Int = 0,
        now: Date = Date()
    ) -> AIFormatterProfile {
        AIFormatterProfile(
            name: name,
            isEnabled: isEnabled,
            targetKind: .bundle,
            bundleIdentifier: bundleIdentifier,
            appDisplayName: appDisplayName,
            appCategory: nil,
            promptTemplate: promptTemplate,
            origin: origin,
            sortOrder: sortOrder,
            createdAt: now,
            updatedAt: now
        )
    }

    public static func category(
        name: String,
        appCategory: TelemetryAppCategory,
        promptTemplate: String,
        isEnabled: Bool = true,
        origin: AIFormatterProfileOrigin = .custom,
        sortOrder: Int = 0,
        now: Date = Date()
    ) -> AIFormatterProfile {
        AIFormatterProfile(
            name: name,
            isEnabled: isEnabled,
            targetKind: .category,
            bundleIdentifier: nil,
            appDisplayName: nil,
            appCategory: appCategory,
            promptTemplate: promptTemplate,
            origin: origin,
            sortOrder: sortOrder,
            createdAt: now,
            updatedAt: now
        )
    }

    public var matchKind: AIFormatterProfileMatchKind {
        switch targetKind {
        case .bundle: return .exactApp
        case .category: return .category
        }
    }
}
extension AIFormatterProfile: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ai_formatter_profiles"

    public enum Columns: String, ColumnExpression {
        case id, name, isEnabled, targetKind, bundleIdentifier, appDisplayName
        case appCategory, promptTemplate, origin, sortOrder, createdAt, updatedAt
    }
}
