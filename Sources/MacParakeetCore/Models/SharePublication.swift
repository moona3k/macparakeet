import Foundation
import GRDB

/// The local, durable projection of one `share.macparakeet.com` share, per
/// Share Service v1's "Local lifecycle invariant". This row is the only
/// source of remote identity, locator, and lifecycle receipts for a share; it
/// is never cascaded from its optional local `transcriptionId` association so
/// deleting a source can never silently drop revocation authority.
public struct SharePublication: Codable, Identifiable, Sendable, Equatable {
    /// Mirrors the contract's `accessState`. `nil` means the coordinator has
    /// never received a confirmed create receipt yet — a still-pending
    /// creation, not a guessed state.
    public enum AccessState: String, Codable, Sendable, Equatable {
        case active
        case expired
        case stopped
    }

    public enum DeletionState: String, Codable, Sendable, Equatable {
        case retained
        case pending
        case complete
    }

    /// Local row identity. Distinct from `remoteShareId`, which is the
    /// client-generated identifier the service also knows.
    public var id: UUID

    /// The 22-character client-generated share id sent as `{share-id}` in
    /// every owner resource path.
    public var remoteShareId: String

    /// The 22-character public locator. Kept only on the originating device;
    /// the service never returns it after creation.
    public var locator: String?

    /// The 43-character locator commitment. Computed locally before the
    /// first network call so a lost create response and terminal delete can
    /// both be reconciled without the plaintext locator.
    public var locatorCommitment: String

    /// The owner this share was created under.
    public var ownerId: String

    /// The credential generation active at creation time. A later recovery
    /// generation may still list, expire, and stop this share, but content
    /// updates require the current generation to match this value.
    public var createdCredentialGeneration: Int

    public var contentRevision: Int

    /// The server's ETag-bearing `version`. `nil` until the first confirmed
    /// receipt.
    public var version: Int?

    /// Last confirmed value only; never inferred locally.
    public var accessState: AccessState?

    public var deletionState: DeletionState

    /// Last confirmed value only, mirrors the contract's `contentWritable`.
    public var contentWritable: Bool

    /// Local intent time. Never rewritten after the row is created.
    public var createdAt: Date

    public var updatedAt: Date

    /// The currently requested/confirmed expiration.
    public var expiresAt: Date

    /// Fixed at local creation time and never moved afterward.
    public var maxExpiresAt: Date

    /// Confirmed terminal instant, `nil` while active.
    public var terminalAt: Date?

    /// Nullable local association; cleared by detach.
    public var transcriptionId: UUID?

    /// JSON-encoded selected-section manifest driving exact-preview
    /// re-derivation. Content-derived; cleared by detach.
    public var projectionManifest: Data?

    /// Hash of the current local projection used for staleness detection.
    /// Content-derived; cleared by detach.
    public var contentDigest: String?

    /// Set once, permanently, the moment a source deletion detaches this
    /// share. Distinct from `transcriptionId == nil`, which is also true for
    /// a share that never had a source association — that case must never
    /// trigger detach-only cleanup such as retrying Keychain content-key
    /// removal.
    public var isDetached: Bool

    public init(
        id: UUID = UUID(),
        remoteShareId: String,
        locator: String?,
        locatorCommitment: String,
        ownerId: String,
        createdCredentialGeneration: Int,
        contentRevision: Int = 1,
        version: Int? = nil,
        accessState: AccessState? = nil,
        deletionState: DeletionState = .retained,
        contentWritable: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date,
        maxExpiresAt: Date,
        terminalAt: Date? = nil,
        transcriptionId: UUID? = nil,
        projectionManifest: Data? = nil,
        contentDigest: String? = nil,
        isDetached: Bool = false
    ) {
        self.id = id
        self.remoteShareId = remoteShareId
        self.locator = locator
        self.locatorCommitment = locatorCommitment
        self.ownerId = ownerId
        self.createdCredentialGeneration = createdCredentialGeneration
        self.contentRevision = contentRevision
        self.version = version
        self.accessState = accessState
        self.deletionState = deletionState
        self.contentWritable = contentWritable
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.maxExpiresAt = maxExpiresAt
        self.terminalAt = terminalAt
        self.transcriptionId = transcriptionId
        self.projectionManifest = projectionManifest
        self.contentDigest = contentDigest
        self.isDetached = isDetached
    }

    /// A confirmed create receipt has arrived. Before this, the share only
    /// exists as local intent plus a queued outbox operation.
    public var isConfirmed: Bool { version != nil }

    public var isTerminal: Bool {
        accessState == .expired || accessState == .stopped
    }

    /// A per-share content key is required in addition to this being true.
    public var isContentUpdateEligibleLocally: Bool {
        isConfirmed && contentWritable && !isTerminal && !isDetached && deletionState == .retained
    }
}

extension SharePublication: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "share_publications"

    public enum Columns: String, ColumnExpression {
        case id
        case remoteShareId
        case locator
        case locatorCommitment
        case ownerId
        case createdCredentialGeneration
        case contentRevision
        case version
        case accessState
        case deletionState
        case contentWritable
        case createdAt
        case updatedAt
        case expiresAt
        case maxExpiresAt
        case terminalAt
        case transcriptionId
        case projectionManifest
        case contentDigest
        case isDetached
    }
}

/// One durable, ordered outbox entry for a share. Operations are processed in
/// `sequence` order per share so a create is always reconciled before any
/// later mutation for the same share is attempted.
public struct ShareOutboxOperation: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case create
        case contentUpdate
        case expiryChange
        /// The one terminal operation kind. At most one non-dequeued `delete`
        /// row may exist per share (enforced by a partial unique index).
        case delete
    }

    public var id: UUID
    public var sharePublicationId: UUID
    public var sequence: Int
    public var kind: Kind

    /// Stable across every retry of this exact operation.
    public var idempotencyKey: String

    /// JSON-encoded request body for this operation's `kind` (one of
    /// `ShareCreateOrUpdateRequestBody`, `ShareExpiryChangeRequestBody`, or
    /// `ShareDeleteRequestBody`). May contain ciphertext, but never
    /// plaintext, a content key, or a complete URL.
    public var requestBody: Data
    /// Frozen with the request. Never derived again from a later receipt.
    public var ifMatch: String?
    public var projectionManifest: Data?
    public var contentDigest: String?

    public var createdAt: Date
    public var lastAttemptAt: Date?

    public init(
        id: UUID = UUID(),
        sharePublicationId: UUID,
        sequence: Int,
        kind: Kind,
        idempotencyKey: String,
        requestBody: Data,
        ifMatch: String? = nil,
        projectionManifest: Data? = nil,
        contentDigest: String? = nil,
        createdAt: Date = Date(),
        lastAttemptAt: Date? = nil
    ) {
        self.id = id
        self.sharePublicationId = sharePublicationId
        self.sequence = sequence
        self.kind = kind
        self.idempotencyKey = idempotencyKey
        self.requestBody = requestBody
        self.ifMatch = ifMatch
        self.projectionManifest = projectionManifest
        self.contentDigest = contentDigest
        self.createdAt = createdAt
        self.lastAttemptAt = lastAttemptAt
    }
}

extension ShareOutboxOperation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "share_outbox_operations"

    public enum Columns: String, ColumnExpression {
        case id
        case sharePublicationId
        case sequence
        case kind
        case idempotencyKey
        case requestBody
        case ifMatch
        case projectionManifest
        case contentDigest
        case createdAt
        case lastAttemptAt
    }
}
