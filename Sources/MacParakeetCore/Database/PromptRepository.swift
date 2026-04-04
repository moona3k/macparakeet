import Foundation
import GRDB

public protocol PromptRepositoryProtocol: Sendable {
    func save(_ prompt: Prompt) throws
    func fetch(id: UUID) throws -> Prompt?
    func fetchAll() throws -> [Prompt]
    func fetchVisible(category: Prompt.Category?) throws -> [Prompt]
    func delete(id: UUID) throws -> Bool
    func toggleVisibility(id: UUID) throws
    func restoreDefaults() throws
}

public final class PromptRepository: PromptRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ prompt: Prompt) throws {
        try dbQueue.write { db in
            try prompt.save(db)
        }
    }

    public func fetch(id: UUID) throws -> Prompt? {
        try dbQueue.read { db in
            try Prompt.fetchOne(db, key: id)
        }
    }

    public func fetchAll() throws -> [Prompt] {
        try dbQueue.read { db in
            try Prompt
                .order(Prompt.Columns.sortOrder.asc, Prompt.Columns.name.asc)
                .fetchAll(db)
        }
    }

    public func fetchVisible(category: Prompt.Category? = nil) throws -> [Prompt] {
        try dbQueue.read { db in
            var request = Prompt
                .filter(Prompt.Columns.isVisible == true)
                .order(Prompt.Columns.sortOrder.asc, Prompt.Columns.name.asc)
            if let category {
                request = request.filter(Prompt.Columns.category == category.rawValue)
            }
            return try request.fetchAll(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            guard let prompt = try Prompt.fetchOne(db, key: id) else { return false }
            guard !prompt.isBuiltIn else { return false }
            return try Prompt.deleteOne(db, key: id)
        }
    }

    public func toggleVisibility(id: UUID) throws {
        try dbQueue.write { db in
            guard var prompt = try Prompt.fetchOne(db, key: id) else { return }
            prompt.isVisible.toggle()
            prompt.updatedAt = Date()
            try prompt.update(db)
        }
    }

    public func restoreDefaults() throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE prompts
                    SET isVisible = 1, updatedAt = ?
                    WHERE isBuiltIn = 1
                    """,
                arguments: [Date()]
            )
        }
    }
}
