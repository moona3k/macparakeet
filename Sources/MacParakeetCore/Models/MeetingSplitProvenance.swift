import Foundation

/// Recorded on a **child** row created by Split and transcribe
/// (`spec/contracts/meeting-splitting.md`). This is plain snapshot data, not a
/// live reference: there is no foreign key back to the source or the
/// operation, so the field survives deletion of either the source recording
/// or sibling parts, and requires no join to read. `nil` for every
/// non-split transcription and for split children created before this field
/// existed.
public struct MeetingSplitProvenance: Codable, Sendable, Equatable {
    /// The `MeetingSplitOperation` that created this child. Informational only
    /// — the operation receipt may itself be discarded/pruned independently.
    public var operationId: UUID
    /// The source recording this part was cut from. The source row may have
    /// since been deleted; this value is a historical snapshot, not a lookup key.
    public var sourceId: UUID
    /// Snapshot of the source's display title at split time, so provenance
    /// remains readable after the source is gone.
    public var sourceTitle: String
    /// User-approved cut boundaries into the source audio, in milliseconds.
    public var approvedStartMs: Int
    public var approvedEndMs: Int
    /// Zero-based position among sibling parts from the same operation.
    public var ordinal: Int
    /// When the split operation created this part (distinct from `createdAt`,
    /// which is backdated to the source's original recording age for
    /// retention purposes).
    public var splitCreatedAt: Date

    public init(
        operationId: UUID,
        sourceId: UUID,
        sourceTitle: String,
        approvedStartMs: Int,
        approvedEndMs: Int,
        ordinal: Int,
        splitCreatedAt: Date
    ) {
        self.operationId = operationId
        self.sourceId = sourceId
        self.sourceTitle = sourceTitle
        self.approvedStartMs = approvedStartMs
        self.approvedEndMs = approvedEndMs
        self.ordinal = ordinal
        self.splitCreatedAt = splitCreatedAt
    }
}
