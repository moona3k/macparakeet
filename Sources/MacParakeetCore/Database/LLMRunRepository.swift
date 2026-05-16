import Foundation
import GRDB

public protocol LLMRunRepositoryProtocol: Sendable {
    func save(_ run: LLMRun) async throws
    func fetchRecent(limit: Int) throws -> [LLMRun]
    func fetchForDictation(id: UUID) throws -> [LLMRun]
    func fetchForTranscription(id: UUID) throws -> [LLMRun]
    func fetchForPromptResult(id: UUID) throws -> [LLMRun]
    func fetchForChatConversation(id: UUID) throws -> [LLMRun]
    func fetchForTransformHistory(id: UUID) throws -> [LLMRun]
    func count() throws -> Int
    func deleteAll() throws
}

public extension LLMRunRepositoryProtocol {
    func fetchRecent() throws -> [LLMRun] {
        try fetchRecent(limit: 200)
    }
}

public final class LLMRunRepository: LLMRunRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ run: LLMRun) async throws {
        try await dbQueue.write { db in
            try run.save(db)
        }
    }

    public func fetchRecent(limit: Int = 200) throws -> [LLMRun] {
        try dbQueue.read { db in
            try LLMRun
                .order(LLMRun.Columns.createdAt.desc)
                .limit(max(0, limit))
                .fetchAll(db)
        }
    }

    public func fetchForDictation(id: UUID) throws -> [LLMRun] {
        try dbQueue.read { db in
            try LLMRun
                .filter(LLMRun.Columns.dictationId == id)
                .order(LLMRun.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func fetchForTranscription(id: UUID) throws -> [LLMRun] {
        try dbQueue.read { db in
            try LLMRun
                .filter(LLMRun.Columns.transcriptionId == id)
                .order(LLMRun.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func fetchForPromptResult(id: UUID) throws -> [LLMRun] {
        try dbQueue.read { db in
            try LLMRun
                .filter(LLMRun.Columns.promptResultId == id)
                .order(LLMRun.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func fetchForChatConversation(id: UUID) throws -> [LLMRun] {
        try dbQueue.read { db in
            try LLMRun
                .filter(LLMRun.Columns.chatConversationId == id)
                .order(LLMRun.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func fetchForTransformHistory(id: UUID) throws -> [LLMRun] {
        try dbQueue.read { db in
            try LLMRun
                .filter(LLMRun.Columns.transformHistoryId == id)
                .order(LLMRun.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in
            try LLMRun.fetchCount(db)
        }
    }

    public func deleteAll() throws {
        _ = try dbQueue.write { db in
            try LLMRun.deleteAll(db)
        }
    }
}
