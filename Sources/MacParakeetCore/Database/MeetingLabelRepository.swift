import Foundation
import GRDB

public protocol MeetingLabelRepositoryProtocol: Sendable {
    func save(_ label: MeetingLabel) throws
    func fetch(id: UUID) throws -> MeetingLabel?
    func fetchAll(includeArchived: Bool) throws -> [MeetingLabel]
    func setArchived(id: UUID, isArchived: Bool) throws
    func delete(id: UUID) throws -> Bool
}

public extension MeetingLabelRepositoryProtocol {
    func fetchAll() throws -> [MeetingLabel] {
        try fetchAll(includeArchived: false)
    }
}

public final class MeetingLabelRepository: MeetingLabelRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ label: MeetingLabel) throws {
        var normalized = label
        let trimmed = label.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MeetingClassificationRepositoryError.emptyName }
        normalized.name = trimmed
        normalized.colorToken = MeetingTypeRepository.normalizedOptional(label.colorToken)
        try dbQueue.write { db in
            try normalized.save(db)
        }
    }

    public func fetch(id: UUID) throws -> MeetingLabel? {
        try dbQueue.read { db in
            try MeetingLabel.fetchOne(db, key: id)
        }
    }

    public func fetchAll(includeArchived: Bool) throws -> [MeetingLabel] {
        try dbQueue.read { db in
            var request = MeetingLabel.all()
            if !includeArchived {
                request = request.filter(MeetingLabel.Columns.isArchived == false)
            }
            return
                try request
                .order(MeetingLabel.Columns.sortOrder.asc, MeetingLabel.Columns.name.collating(.nocase).asc)
                .fetchAll(db)
        }
    }

    public func setArchived(id: UUID, isArchived: Bool) throws {
        try dbQueue.write { db in
            guard var label = try MeetingLabel.fetchOne(db, key: id) else { return }
            label.isArchived = isArchived
            label.updatedAt = Date()
            try label.update(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            let isAssigned =
                try Int.fetchOne(
                    db,
                    sql: "SELECT 1 FROM transcription_meeting_labels WHERE labelId = ? LIMIT 1",
                    arguments: [id]
                ) != nil
            guard !isAssigned else { return false }
            return try MeetingLabel.deleteOne(db, key: id)
        }
    }
}
