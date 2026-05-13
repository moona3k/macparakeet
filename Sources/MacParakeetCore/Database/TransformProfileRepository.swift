import Foundation
import GRDB

public protocol TransformProfileRepositoryProtocol: Sendable {
    func save(_ profile: TransformProfile) throws
    func fetch(promptId: UUID) throws -> TransformProfile?
    func fetchAll() throws -> [TransformProfile]
    func delete(promptId: UUID) throws -> Bool
}

public final class TransformProfileRepository: TransformProfileRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ profile: TransformProfile) throws {
        try dbQueue.write { db in
            try profile.save(db)
        }
    }

    public func fetch(promptId: UUID) throws -> TransformProfile? {
        try dbQueue.read { db in
            try TransformProfile.fetchOne(db, key: promptId)
        }
    }

    public func fetchAll() throws -> [TransformProfile] {
        try dbQueue.read { db in
            try TransformProfile.fetchAll(db)
        }
    }

    public func delete(promptId: UUID) throws -> Bool {
        try dbQueue.write { db in
            try TransformProfile.deleteOne(db, key: promptId)
        }
    }
}
