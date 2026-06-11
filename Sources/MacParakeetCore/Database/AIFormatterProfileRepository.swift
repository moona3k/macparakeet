import Foundation
import GRDB

public enum AIFormatterProfileRepositoryError: Error, LocalizedError, Equatable {
    case emptyName
    case missingBundleIdentifier
    case missingCategory
    case duplicateExactApp(String)
    case duplicateCategory(TelemetryAppCategory)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Profile name can't be empty."
        case .missingBundleIdentifier:
            return "Exact-app profiles need a bundle identifier."
        case .missingCategory:
            return "Category profiles need an app category."
        case .duplicateExactApp(let bundleIdentifier):
            return "A profile already exists for \(bundleIdentifier)."
        case .duplicateCategory(let category):
            return "A profile already exists for \(category.formatterDisplayName)."
        }
    }
}

public protocol AIFormatterProfileRepositoryProtocol: Sendable {
    func save(_ profile: AIFormatterProfile) throws
    func fetch(id: UUID) throws -> AIFormatterProfile?
    func fetchAll() throws -> [AIFormatterProfile]
    func fetchEnabled() throws -> [AIFormatterProfile]
    func delete(id: UUID) throws -> Bool
}

public final class AIFormatterProfileRepository: AIFormatterProfileRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ profile: AIFormatterProfile) throws {
        try dbQueue.write { db in
            var copy = try normalizedForWrite(profile, db: db)
            copy.updatedAt = Date()
            try copy.save(db)
        }
    }

    public func fetch(id: UUID) throws -> AIFormatterProfile? {
        try dbQueue.read { db in
            try AIFormatterProfile.fetchOne(db, key: id)
        }
    }

    public func fetchAll() throws -> [AIFormatterProfile] {
        try dbQueue.read { db in
            try AIFormatterProfile
                .order(
                    AIFormatterProfile.Columns.sortOrder.asc,
                    AIFormatterProfile.Columns.name.asc
                )
                .fetchAll(db)
        }
    }

    public func fetchEnabled() throws -> [AIFormatterProfile] {
        try dbQueue.read { db in
            try AIFormatterProfile
                .filter(AIFormatterProfile.Columns.isEnabled == true)
                .order(
                    AIFormatterProfile.Columns.sortOrder.asc,
                    AIFormatterProfile.Columns.name.asc
                )
                .fetchAll(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try AIFormatterProfile.deleteOne(db, key: id)
        }
    }

    private func normalizedForWrite(
        _ profile: AIFormatterProfile,
        db: Database
    ) throws -> AIFormatterProfile {
        var copy = profile
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty else {
            throw AIFormatterProfileRepositoryError.emptyName
        }

        copy.promptTemplate = AIFormatter.normalizedPromptTemplate(copy.promptTemplate)
        copy.bundleIdentifier = AppPromptContext.normalizedBundleIdentifier(copy.bundleIdentifier)
        copy.appDisplayName = AppPromptContext.normalizedDisplayName(copy.appDisplayName)

        switch copy.targetKind {
        case .bundle:
            guard let bundleIdentifier = copy.bundleIdentifier else {
                throw AIFormatterProfileRepositoryError.missingBundleIdentifier
            }
            copy.appCategory = nil
            try assertNoDuplicateBundle(
                bundleIdentifier,
                excluding: copy.id,
                db: db
            )
        case .category:
            guard let appCategory = copy.appCategory else {
                throw AIFormatterProfileRepositoryError.missingCategory
            }
            copy.bundleIdentifier = nil
            copy.appDisplayName = nil
            try assertNoDuplicateCategory(
                appCategory,
                excluding: copy.id,
                db: db
            )
        }

        return copy
    }

    private func assertNoDuplicateBundle(
        _ bundleIdentifier: String,
        excluding id: UUID,
        db: Database
    ) throws {
        let count = try AIFormatterProfile
            .filter(AIFormatterProfile.Columns.targetKind == AIFormatterProfileTargetKind.bundle.rawValue)
            .filter(AIFormatterProfile.Columns.bundleIdentifier == bundleIdentifier)
            .filter(AIFormatterProfile.Columns.id != id)
            .fetchCount(db)
        if count > 0 {
            throw AIFormatterProfileRepositoryError.duplicateExactApp(bundleIdentifier)
        }
    }

    private func assertNoDuplicateCategory(
        _ category: TelemetryAppCategory,
        excluding id: UUID,
        db: Database
    ) throws {
        let count = try AIFormatterProfile
            .filter(AIFormatterProfile.Columns.targetKind == AIFormatterProfileTargetKind.category.rawValue)
            .filter(AIFormatterProfile.Columns.appCategory == category.rawValue)
            .filter(AIFormatterProfile.Columns.id != id)
            .fetchCount(db)
        if count > 0 {
            throw AIFormatterProfileRepositoryError.duplicateCategory(category)
        }
    }
}
