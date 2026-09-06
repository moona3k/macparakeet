import Foundation
import GRDB

public enum MeetingClassificationRepositoryError: Error, LocalizedError, Equatable {
    case emptyName
    case invalidPolicyScope

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Meeting classification names cannot be empty."
        case .invalidPolicyScope:
            return "A meeting prompt policy must target either all meetings or exactly one meeting type."
        }
    }
}

public protocol MeetingTypeRepositoryProtocol: Sendable {
    func save(_ meetingType: MeetingType) throws
    func fetch(id: UUID) throws -> MeetingType?
    func fetchAll(includeArchived: Bool) throws -> [MeetingType]
    func setArchived(id: UUID, isArchived: Bool) throws
    func delete(id: UUID) throws -> Bool
}

public extension MeetingTypeRepositoryProtocol {
    func fetchAll() throws -> [MeetingType] {
        try fetchAll(includeArchived: false)
    }
}

public final class MeetingTypeRepository: MeetingTypeRepositoryProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ meetingType: MeetingType) throws {
        var normalized = meetingType
        normalized.name = try Self.normalizedName(meetingType.name)
        normalized.colorToken = Self.normalizedOptional(meetingType.colorToken)
        normalized.iconName = Self.normalizedOptional(meetingType.iconName)
        try dbQueue.write { db in
            try normalized.save(db)
        }
    }

    public func fetch(id: UUID) throws -> MeetingType? {
        try dbQueue.read { db in
            try MeetingType.fetchOne(db, key: id)
        }
    }

    public func fetchAll(includeArchived: Bool) throws -> [MeetingType] {
        try dbQueue.read { db in
            var request = MeetingType.all()
            if !includeArchived {
                request = request.filter(MeetingType.Columns.isArchived == false)
            }
            return
                try request
                .order(MeetingType.Columns.sortOrder.asc, MeetingType.Columns.name.collating(.nocase).asc)
                .fetchAll(db)
        }
    }

    public func setArchived(id: UUID, isArchived: Bool) throws {
        try dbQueue.write { db in
            guard var meetingType = try MeetingType.fetchOne(db, key: id) else { return }
            meetingType.isArchived = isArchived
            meetingType.updatedAt = Date()
            try meetingType.update(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            let transcriptionReference =
                try Int.fetchOne(
                    db,
                    sql: "SELECT 1 FROM transcriptions WHERE meetingTypeId = ? LIMIT 1",
                    arguments: [id]
                ) != nil
            let policyReference =
                try Int.fetchOne(
                    db,
                    sql: "SELECT 1 FROM prompt_meeting_policies WHERE meetingTypeId = ? LIMIT 1",
                    arguments: [id]
                ) != nil
            guard !transcriptionReference, !policyReference else { return false }
            return try MeetingType.deleteOne(db, key: id)
        }
    }

    private static func normalizedName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MeetingClassificationRepositoryError.emptyName }
        return trimmed
    }

    static func normalizedOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
