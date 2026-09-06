import Foundation
import GRDB

public struct TranscriptFingerprint: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension TranscriptFingerprint: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        rawValue.databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> TranscriptFingerprint? {
        String.fromDatabaseValue(dbValue).map(TranscriptFingerprint.init(rawValue:))
    }
}

public enum SpeakerAssignment: Codable, Hashable, Sendable {
    case speaker(id: String)
    case unassigned

    private enum CodingKeys: String, CodingKey {
        case kind, speakerId
    }

    private enum Kind: String, Codable {
        case speaker, unassigned
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .speaker:
            self = .speaker(id: try container.decode(String.self, forKey: .speakerId))
        case .unassigned:
            self = .unassigned
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .speaker(let id):
            try container.encode(Kind.speaker, forKey: .kind)
            try container.encode(id, forKey: .speakerId)
        case .unassigned:
            try container.encode(Kind.unassigned, forKey: .kind)
        }
    }
}

public struct ManualSpeaker: Codable, Hashable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct SpeakerCorrectionTarget: Codable, Hashable, Sendable {
    public let anchorTranscriptSegmentIDs: [UUID]
    public let wordRange: TranscriptSegmentWordRange

    public init(
        anchorTranscriptSegmentIDs: [UUID],
        wordRange: TranscriptSegmentWordRange
    ) {
        self.anchorTranscriptSegmentIDs = anchorTranscriptSegmentIDs
        self.wordRange = wordRange
    }
}

public struct SpeakerSplitBoundary: Codable, Hashable, Sendable {
    public let target: SpeakerCorrectionTarget
    public let wordIndex: Int

    public init(target: SpeakerCorrectionTarget, wordIndex: Int) {
        self.target = target
        self.wordIndex = wordIndex
    }
}

public enum SpeakerCorrectionCommand: Hashable, Sendable {
    case rename(speakerID: String, label: String)
    case add(speaker: ManualSpeaker, assigning: [SpeakerCorrectionTarget])
    case assign(targets: [SpeakerCorrectionTarget], to: SpeakerAssignment)
    case split(target: SpeakerCorrectionTarget, atWordIndex: Int)
    case removeSplit(boundary: SpeakerSplitBoundary, joinedAssignment: SpeakerAssignment?)
    case merge(sourceSpeakerID: String, targetSpeakerID: String)
    case remove(speakerID: String, reassignTo: SpeakerAssignment?)
    case reset

    public var operation: SpeakerCorrectionOperation {
        switch self {
        case .rename: .rename
        case .add: .add
        case .assign: .assign
        case .split: .split
        case .removeSplit: .unsplit
        case .merge: .merge
        case .remove: .remove
        case .reset: .reset
        }
    }
}

extension SpeakerCorrectionCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, kind, speakerID, label, speaker, assigning, targets, assignment
        case target, atWordIndex, boundary, joinedAssignment, sourceSpeakerID
        case targetSpeakerID, reassignTo
    }

    private enum Kind: String, Codable {
        case rename, add, assign, split, unsplit, merge, remove, reset
    }

    private static let payloadVersion = 1

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.payloadVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported speaker correction payload version \(version)"
            )
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .rename:
            self = .rename(
                speakerID: try container.decode(String.self, forKey: .speakerID),
                label: try container.decode(String.self, forKey: .label)
            )
        case .add:
            self = .add(
                speaker: try container.decode(ManualSpeaker.self, forKey: .speaker),
                assigning: try container.decode([SpeakerCorrectionTarget].self, forKey: .assigning)
            )
        case .assign:
            self = .assign(
                targets: try container.decode([SpeakerCorrectionTarget].self, forKey: .targets),
                to: try container.decode(SpeakerAssignment.self, forKey: .assignment)
            )
        case .split:
            self = .split(
                target: try container.decode(SpeakerCorrectionTarget.self, forKey: .target),
                atWordIndex: try container.decode(Int.self, forKey: .atWordIndex)
            )
        case .unsplit:
            self = .removeSplit(
                boundary: try container.decode(SpeakerSplitBoundary.self, forKey: .boundary),
                joinedAssignment: try container.decodeIfPresent(
                    SpeakerAssignment.self,
                    forKey: .joinedAssignment
                )
            )
        case .merge:
            self = .merge(
                sourceSpeakerID: try container.decode(String.self, forKey: .sourceSpeakerID),
                targetSpeakerID: try container.decode(String.self, forKey: .targetSpeakerID)
            )
        case .remove:
            self = .remove(
                speakerID: try container.decode(String.self, forKey: .speakerID),
                reassignTo: try container.decodeIfPresent(SpeakerAssignment.self, forKey: .reassignTo)
            )
        case .reset:
            self = .reset
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.payloadVersion, forKey: .version)
        switch self {
        case .rename(let speakerID, let label):
            try container.encode(Kind.rename, forKey: .kind)
            try container.encode(speakerID, forKey: .speakerID)
            try container.encode(label, forKey: .label)
        case .add(let speaker, let assigning):
            try container.encode(Kind.add, forKey: .kind)
            try container.encode(speaker, forKey: .speaker)
            try container.encode(assigning, forKey: .assigning)
        case .assign(let targets, let assignment):
            try container.encode(Kind.assign, forKey: .kind)
            try container.encode(targets, forKey: .targets)
            try container.encode(assignment, forKey: .assignment)
        case .split(let target, let atWordIndex):
            try container.encode(Kind.split, forKey: .kind)
            try container.encode(target, forKey: .target)
            try container.encode(atWordIndex, forKey: .atWordIndex)
        case .removeSplit(let boundary, let joinedAssignment):
            try container.encode(Kind.unsplit, forKey: .kind)
            try container.encode(boundary, forKey: .boundary)
            try container.encodeIfPresent(joinedAssignment, forKey: .joinedAssignment)
        case .merge(let sourceSpeakerID, let targetSpeakerID):
            try container.encode(Kind.merge, forKey: .kind)
            try container.encode(sourceSpeakerID, forKey: .sourceSpeakerID)
            try container.encode(targetSpeakerID, forKey: .targetSpeakerID)
        case .remove(let speakerID, let reassignTo):
            try container.encode(Kind.remove, forKey: .kind)
            try container.encode(speakerID, forKey: .speakerID)
            try container.encodeIfPresent(reassignTo, forKey: .reassignTo)
        case .reset:
            try container.encode(Kind.reset, forKey: .kind)
        }
    }
}

public enum SpeakerCorrectionOperation: String, Codable, Sendable {
    case rename, add, assign, split, unsplit, merge, remove, reset
}

public enum SpeakerCorrectionBranchState: String, Codable, Sendable {
    case current, redo, abandoned
}

public struct SpeakerCorrection: Codable, FetchableRecord, PersistableRecord, Identifiable,
    Sendable, Equatable
{
    public static let databaseTableName = "speaker_corrections"

    public var id: UUID
    public var transcriptionId: UUID
    public var parentId: UUID?
    public var sequence: Int
    public var transcriptFingerprint: TranscriptFingerprint
    public var operation: SpeakerCorrectionOperation
    public var payload: SpeakerCorrectionCommand
    public var branchState: SpeakerCorrectionBranchState
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        transcriptionId: UUID,
        parentId: UUID?,
        sequence: Int,
        transcriptFingerprint: TranscriptFingerprint,
        payload: SpeakerCorrectionCommand,
        branchState: SpeakerCorrectionBranchState = .current,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.transcriptionId = transcriptionId
        self.parentId = parentId
        self.sequence = sequence
        self.transcriptFingerprint = transcriptFingerprint
        self.operation = payload.operation
        self.payload = payload
        self.branchState = branchState
        self.createdAt = createdAt
    }
}

public struct SpeakerCorrectionState: Codable, FetchableRecord, PersistableRecord, Sendable,
    Equatable
{
    public static let databaseTableName = "speaker_correction_states"

    public var transcriptionId: UUID
    public var transcriptFingerprint: String
    public var headId: UUID?
    public var revision: Int
    public var updatedAt: Date

    public init(
        transcriptionId: UUID,
        transcriptFingerprint: String,
        headId: UUID?,
        revision: Int,
        updatedAt: Date = Date()
    ) {
        self.transcriptionId = transcriptionId
        self.transcriptFingerprint = transcriptFingerprint
        self.headId = headId
        self.revision = revision
        self.updatedAt = updatedAt
    }
}
