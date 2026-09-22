import Foundation
import GRDB
import OSLog

public enum MeetingClassificationServiceError: Error, LocalizedError, Equatable {
    case transcriptionNotFound(UUID)
    case meetingTypeUnavailable(UUID)
    case meetingLabelsUnavailable(Set<UUID>)

    public var errorDescription: String? {
        switch self {
        case .transcriptionNotFound:
            return "The transcription could not be found."
        case .meetingTypeUnavailable:
            return "The selected meeting type does not exist or is archived."
        case .meetingLabelsUnavailable:
            return "One or more selected meeting labels do not exist or are archived."
        }
    }
}

public protocol MeetingClassificationArtifactRefreshing: Sendable {
    func refreshArtifact(
        for transcription: Transcription,
        classification: MeetingClassification
    ) async throws
}

public final class MeetingArtifactClassificationRefresher: MeetingClassificationArtifactRefreshing,
    @unchecked Sendable
{
    private let promptResultRepository: any PromptResultRepositoryProtocol
    private let artifactStore: any MeetingArtifactStoring
    private let speakerAttributionReader: any SpeakerAttributionReading

    public init(
        promptResultRepository: any PromptResultRepositoryProtocol,
        speakerAttributionReader: any SpeakerAttributionReading,
        artifactStore: any MeetingArtifactStoring = MeetingArtifactStore()
    ) {
        self.promptResultRepository = promptResultRepository
        self.speakerAttributionReader = speakerAttributionReader
        self.artifactStore = artifactStore
    }

    public func refreshArtifact(
        for transcription: Transcription,
        classification: MeetingClassification
    ) async throws {
        // Classification commits may be followed by notes, title, speaker,
        // or deletion edits before this asynchronous refresh starts. Derived
        // files must reflect the current row, not the mutation's old receipt.
        guard let projection = try speakerAttributionReader.resolve(transcriptionId: transcription.id),
            projection.automaticTranscription.sourceType == .meeting
        else { return }
        let promptResults = try promptResultRepository.fetchAll(transcriptionId: transcription.id)
        _ = try await artifactStore.materialize(
            projection: projection,
            promptResults: promptResults,
            classification: MeetingArtifactClassificationSnapshot(classification)
        )
    }
}

public protocol MeetingClassificationServiceProtocol: Sendable {
    func classification(for transcriptionId: UUID) throws -> MeetingClassification
    func setMeetingType(_ meetingTypeId: UUID?, for transcriptionId: UUID) async throws
    func replaceLabels(_ labelIds: Set<UUID>, for transcriptionId: UUID) async throws
    func update(
        meetingTypeId: UUID?,
        labelIds: Set<UUID>,
        for transcriptionId: UUID
    ) async throws
}

public final class MeetingClassificationService: MeetingClassificationServiceProtocol, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let artifactRefresher: (any MeetingClassificationArtifactRefreshing)?
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingClassification")

    public init(
        dbQueue: DatabaseQueue,
        artifactRefresher: (any MeetingClassificationArtifactRefreshing)? = nil
    ) {
        self.dbQueue = dbQueue
        self.artifactRefresher = artifactRefresher
    }

    public func classification(for transcriptionId: UUID) throws -> MeetingClassification {
        try dbQueue.read { db in
            let transcription = try Self.requireTranscription(id: transcriptionId, in: db)
            let meetingType = try transcription.meetingTypeId.flatMap {
                try MeetingType.fetchOne(db, key: $0)
            }
            let labels = try MeetingLabel.fetchAll(
                db,
                sql: """
                    SELECT ml.*
                    FROM meeting_labels ml
                    JOIN transcription_meeting_labels tml ON tml.labelId = ml.id
                    WHERE tml.transcriptionId = ?
                    ORDER BY ml.sortOrder ASC, ml.name COLLATE NOCASE ASC
                    """,
                arguments: [transcriptionId]
            )
            return MeetingClassification(meetingType: meetingType, labels: labels)
        }
    }

    public func setMeetingType(_ meetingTypeId: UUID?, for transcriptionId: UUID) async throws {
        let transcription = try await dbQueue.write { db in
            var transcription = try Self.requireTranscription(id: transcriptionId, in: db)
            if meetingTypeId != transcription.meetingTypeId {
                try Self.validate(meetingTypeId: meetingTypeId, in: db)
            }
            transcription.meetingTypeId = meetingTypeId
            transcription.updatedAt = Date()
            try transcription.update(db)
            return transcription
        }
        await refreshArtifactIfConfigured(for: transcription)
    }

    public func replaceLabels(_ labelIds: Set<UUID>, for transcriptionId: UUID) async throws {
        let transcription = try await dbQueue.write { db in
            let transcription = try Self.requireTranscription(id: transcriptionId, in: db)
            let currentLabelIds = try Set(
                TranscriptionMeetingLabel
                    .filter(TranscriptionMeetingLabel.Columns.transcriptionId == transcriptionId)
                    .fetchAll(db)
                    .map(\.labelId)
            )
            try Self.validate(labelIds: labelIds.subtracting(currentLabelIds), in: db)
            try TranscriptionMeetingLabelRepository.replaceLabels(
                in: db,
                for: transcriptionId,
                with: labelIds
            )
            return transcription
        }
        await refreshArtifactIfConfigured(for: transcription)
    }

    public func update(
        meetingTypeId: UUID?,
        labelIds: Set<UUID>,
        for transcriptionId: UUID
    ) async throws {
        let transcription = try await dbQueue.write { db in
            var transcription = try Self.requireTranscription(id: transcriptionId, in: db)
            if meetingTypeId != transcription.meetingTypeId {
                try Self.validate(meetingTypeId: meetingTypeId, in: db)
            }
            let currentLabelIds = try Set(
                TranscriptionMeetingLabel
                    .filter(TranscriptionMeetingLabel.Columns.transcriptionId == transcriptionId)
                    .fetchAll(db)
                    .map(\.labelId)
            )
            try Self.validate(labelIds: labelIds.subtracting(currentLabelIds), in: db)
            transcription.meetingTypeId = meetingTypeId
            transcription.updatedAt = Date()
            try transcription.update(db)
            try TranscriptionMeetingLabelRepository.replaceLabels(
                in: db,
                for: transcriptionId,
                with: labelIds
            )
            return transcription
        }
        await refreshArtifactIfConfigured(for: transcription)
    }

    private func refreshArtifactIfConfigured(for transcription: Transcription) async {
        guard transcription.sourceType == .meeting, let artifactRefresher else { return }
        do {
            let currentClassification = try classification(for: transcription.id)
            try await artifactRefresher.refreshArtifact(
                for: transcription,
                classification: currentClassification
            )
        } catch {
            logger.error(
                "Classification committed but artifact refresh failed for \(transcription.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private static func requireTranscription(id: UUID, in db: Database) throws -> Transcription {
        guard let transcription = try Transcription.fetchOne(db, key: id) else {
            throw MeetingClassificationServiceError.transcriptionNotFound(id)
        }
        return transcription
    }

    private static func validate(meetingTypeId: UUID?, in db: Database) throws {
        guard let meetingTypeId else { return }
        guard let meetingType = try MeetingType.fetchOne(db, key: meetingTypeId),
            !meetingType.isArchived
        else {
            throw MeetingClassificationServiceError.meetingTypeUnavailable(meetingTypeId)
        }
    }

    private static func validate(labelIds: Set<UUID>, in db: Database) throws {
        guard !labelIds.isEmpty else { return }
        let available =
            try MeetingLabel
            .filter(labelIds.contains(MeetingLabel.Columns.id))
            .filter(MeetingLabel.Columns.isArchived == false)
            .fetchAll(db)
        let unavailable = labelIds.subtracting(available.map(\.id))
        guard unavailable.isEmpty else {
            throw MeetingClassificationServiceError.meetingLabelsUnavailable(unavailable)
        }
    }
}
