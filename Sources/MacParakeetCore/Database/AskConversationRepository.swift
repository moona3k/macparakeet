import Foundation
import GRDB

public enum AskConversationRepositoryError: LocalizedError, Equatable {
    case missing
    case conflict
    case runInProgress
    case runLeaseLost
    case invalidConversation
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .missing: return "This conversation was deleted."
        case .conflict: return "This conversation changed elsewhere. Reload it before continuing."
        case .runInProgress:
            return "An answer is already running in this conversation. Stop it or wait for it to finish."
        case .runLeaseLost: return "This answer lost ownership of the conversation. Reload before asking again."
        case .invalidConversation: return "This conversation contains invalid source or message references."
        case .tooLarge: return "This conversation is full. Start a new conversation to continue."
        }
    }
}

public protocol AskConversationRepositoryProtocol: Sendable {
    func create(_ conversation: AskConversation) throws -> AskConversation
    func fetch(id: UUID) throws -> AskConversation?
    func fetchAll() throws -> [AskConversation]
    func save(
        _ conversation: AskConversation,
        expectedRevision: Int,
        runToken: UUID?,
        sourceRevisions: [UUID: String]?,
        summaryReceipts: [AskSummary]
    ) throws -> AskConversation
    func delete(id: UUID) throws -> Bool
    func acquireRun(id: UUID, expectedRevision: Int, token: UUID, leaseUntil: Date) throws -> Bool
    func renewRun(id: UUID, token: UUID, leaseUntil: Date) throws -> Bool
    func releaseRun(id: UUID, token: UUID) throws -> Bool
}

public extension AskConversationRepositoryProtocol {
    func save(_ conversation: AskConversation, expectedRevision: Int) throws -> AskConversation {
        try save(
            conversation, expectedRevision: expectedRevision, runToken: nil, sourceRevisions: nil, summaryReceipts: [])
    }

    func save(
        _ conversation: AskConversation,
        expectedRevision: Int,
        runToken: UUID?
    ) throws -> AskConversation {
        try save(
            conversation, expectedRevision: expectedRevision, runToken: runToken, sourceRevisions: nil,
            summaryReceipts: [])
    }
}

/// One bounded Codable payload keeps section and message edits atomic. The
/// revision and lease remain SQL columns so competing processes can arbitrate.
public final class AskConversationRepository: AskConversationRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private static let maxPayloadBytes = 8 * 1_024 * 1_024
    private static let maxRunLease: TimeInterval = 45

    public init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    public func create(_ conversation: AskConversation) throws -> AskConversation {
        guard conversation.revision == 0 else { throw AskConversationRepositoryError.invalidConversation }
        try Self.validate(conversation)
        let data = try Self.encode(conversation)
        try dbQueue.write { db in
            let row = RowRecord(
                id: conversation.id,
                payload: data,
                revision: 0,
                createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt,
                runToken: nil,
                runLeaseUntil: nil
            )
            // Fresh insert only. A deleted conversation can never be revived
            // by a late save that still holds an in-memory copy.
            try row.insert(db)
        }
        return conversation
    }

    public func fetch(id: UUID) throws -> AskConversation? {
        try dbQueue.read { db in
            try RowRecord.fetchOne(db, key: id).map(Self.decode)
        }
    }

    public func fetchAll() throws -> [AskConversation] {
        try dbQueue.read { db in
            try RowRecord.order(Column("updatedAt").desc).fetchAll(db).map(Self.decode)
        }
    }

    public func save(
        _ conversation: AskConversation,
        expectedRevision: Int,
        runToken: UUID? = nil,
        sourceRevisions: [UUID: String]? = nil,
        summaryReceipts: [AskSummary] = []
    ) throws -> AskConversation {
        guard conversation.revision == expectedRevision else {
            throw AskConversationRepositoryError.conflict
        }
        try Self.validate(conversation)
        return try dbQueue.write { db in
            guard var row = try RowRecord.fetchOne(db, key: conversation.id) else {
                throw AskConversationRepositoryError.missing
            }
            guard row.revision == expectedRevision else { throw AskConversationRepositoryError.conflict }
            let now = Date()
            if let runToken {
                guard row.runToken == runToken, let until = row.runLeaseUntil, until > now else {
                    throw AskConversationRepositoryError.runLeaseLost
                }
            } else if row.runToken != nil, (row.runLeaseUntil ?? .distantPast) > now {
                throw AskConversationRepositoryError.runInProgress
            }
            if let sourceRevisions {
                try AskSourceService.validateRevisions(sourceRevisions, in: db)
            }
            try AskSourceService.validateSummaries(summaryReceipts, in: db)
            var next = conversation
            next.revision = expectedRevision + 1
            next.createdAt = row.createdAt
            next.updatedAt = now
            row.payload = try Self.encode(next)
            row.revision = next.revision
            row.updatedAt = now
            try row.update(db)
            return next
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try RowRecord.deleteOne(db, key: id)
        }
    }

    public func acquireRun(
        id: UUID,
        expectedRevision: Int,
        token: UUID,
        leaseUntil: Date
    ) throws -> Bool {
        try dbQueue.write { db in
            guard var row = try RowRecord.fetchOne(db, key: id) else {
                throw AskConversationRepositoryError.missing
            }
            guard row.revision == expectedRevision else { throw AskConversationRepositoryError.conflict }
            let now = Date()
            guard row.runToken == nil || (row.runLeaseUntil ?? .distantPast) <= now else {
                return false
            }
            guard leaseUntil > now else { return false }
            row.runToken = token
            row.runLeaseUntil = Self.boundedLease(leaseUntil, now: now)
            try row.update(db)
            return true
        }
    }

    public func renewRun(id: UUID, token: UUID, leaseUntil: Date) throws -> Bool {
        try dbQueue.write { db in
            guard var row = try RowRecord.fetchOne(db, key: id),
                row.runToken == token,
                let until = row.runLeaseUntil,
                until > Date()
            else { return false }
            guard leaseUntil > Date() else { return false }
            row.runLeaseUntil = Self.boundedLease(leaseUntil, now: Date())
            try row.update(db)
            return true
        }
    }

    public func releaseRun(id: UUID, token: UUID) throws -> Bool {
        try dbQueue.write { db in
            guard var row = try RowRecord.fetchOne(db, key: id), row.runToken == token else {
                return false
            }
            row.runToken = nil
            row.runLeaseUntil = nil
            try row.update(db)
            return true
        }
    }

    private static func boundedLease(_ requested: Date, now: Date) -> Date {
        min(max(requested, now), now.addingTimeInterval(maxRunLease))
    }

    private static func validate(_ conversation: AskConversation) throws {
        guard !conversation.sections.isEmpty,
            Set(conversation.sections.map(\.id)).count == conversation.sections.count,
            conversation.sections.allSatisfy({
                $0.sourceIDs.count <= 32 && Set($0.sourceIDs).count == $0.sourceIDs.count
            }),
            Set(conversation.messages.map(\.id)).count == conversation.messages.count
        else { throw AskConversationRepositoryError.invalidConversation }
        let sourcesBySection = Dictionary(
            uniqueKeysWithValues: conversation.sections.map { ($0.id, Set($0.sourceIDs)) }
        )
        guard
            conversation.messages.allSatisfy({ message in
                guard let sources = sourcesBySection[message.sectionID] else { return false }
                return Set(message.sourceRevisions.keys).isSubset(of: sources)
                    && message.citations.allSatisfy {
                        sources.contains($0.sourceID)
                            && message.sourceRevisions[$0.sourceID] == $0.sourceRevision
                    }
            })
        else {
            throw AskConversationRepositoryError.invalidConversation
        }
    }

    private static func encode(_ conversation: AskConversation) throws -> Data {
        let data = try JSONEncoder().encode(conversation)
        guard data.count <= maxPayloadBytes else { throw AskConversationRepositoryError.tooLarge }
        return data
    }

    private static func decode(_ row: RowRecord) throws -> AskConversation {
        var conversation = try JSONDecoder().decode(AskConversation.self, from: row.payload)
        conversation.revision = row.revision
        conversation.createdAt = row.createdAt
        conversation.updatedAt = row.updatedAt
        return conversation
    }
}

private struct RowRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ask_conversations"
    var id: UUID
    var payload: Data
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var runToken: UUID?
    var runLeaseUntil: Date?
}
