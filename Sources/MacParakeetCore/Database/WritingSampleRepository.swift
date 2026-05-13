import Foundation
import GRDB

public protocol WritingSampleRepositoryProtocol: Sendable {
    func save(_ sample: WritingSample) throws
    func fetch(id: UUID) throws -> WritingSample?
    func fetchAll() throws -> [WritingSample]
    func delete(id: UUID) throws -> Bool
    func deleteAll() throws
}

public final class WritingSampleRepository: WritingSampleRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ sample: WritingSample) throws {
        try dbQueue.write { db in
            try sample.save(db)
        }
    }

    public func fetch(id: UUID) throws -> WritingSample? {
        try dbQueue.read { db in
            try WritingSample.fetchOne(db, key: id)
        }
    }

    public func fetchAll() throws -> [WritingSample] {
        try dbQueue.read { db in
            try WritingSample
                .order(WritingSample.Columns.updatedAt.desc, WritingSample.Columns.title.asc)
                .fetchAll(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try WritingSample.deleteOne(db, key: id)
        }
    }

    public func deleteAll() throws {
        _ = try dbQueue.write { db in
            try WritingSample.deleteAll(db)
        }
    }
}
