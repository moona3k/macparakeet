import Foundation
import GRDB

public protocol PromptVersionRepositoryProtocol: Sendable {
    func fetch(id: UUID) throws -> PromptVersion?
    func fetchAll(promptId: UUID) throws -> [PromptVersion]
    func fetchActive(promptId: UUID) throws -> PromptVersion?
}

public final class PromptVersionRepository: PromptVersionRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func fetch(id: UUID) throws -> PromptVersion? {
        try dbQueue.read { db in
            try PromptVersion.fetchOne(db, key: id)
        }
    }

    public func fetchAll(promptId: UUID) throws -> [PromptVersion] {
        try dbQueue.read { db in
            try PromptVersion
                .filter(PromptVersion.Columns.promptId == promptId)
                .order(PromptVersion.Columns.versionNumber.desc)
                .fetchAll(db)
        }
    }

    public func fetchActive(promptId: UUID) throws -> PromptVersion? {
        try dbQueue.read { db in
            try PromptVersion.fetchOne(
                db,
                sql: """
                    SELECT v.*
                    FROM prompt_versions v
                    JOIN prompts p ON p.activeVersionId = v.id
                    WHERE p.id = ? AND v.promptId = p.id
                    """,
                arguments: [promptId]
            )
        }
    }
}
