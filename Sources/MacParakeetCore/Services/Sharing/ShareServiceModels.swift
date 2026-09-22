import Foundation

/// Wire DTOs for Share Service v1 (`spec/contracts/share-service-v1.md`).
/// This file owns only transport shapes; it never carries plaintext, a
/// content key, or a complete recipient URL.
enum ShareServiceJSON {
    /// Every contract timestamp is RFC 3339 UTC at whole-second precision.
    /// Reuses `ShareBundle`'s `ISO8601DateFormatter` so every sharing type
    /// serializes dates identically. `JSONEncoder`'s built-in `.formatted`
    /// strategy only accepts a `Foundation.DateFormatter`, not
    /// `ISO8601DateFormatter`, hence the `.custom` strategies below.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ShareBundle.dateFormatter.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = ShareBundle.dateFormatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Invalid RFC 3339 date: \(string)")
            }
            return date
        }
        return decoder
    }
}

public struct ShareCapabilities: Codable, Sendable, Equatable {
    public var envelopeVersions: [Int]
    public var bundleVersions: [Int]
    public var maxPlaintextBytes: Int
    public var maxCiphertextAndTagBytes: Int
    public var maxLifetimeSeconds: Int
}

struct ShareOwnerEnrollmentRequestBody: Encodable {
    var ownerId: String
    var deviceSelector: String
    var deviceVerifier: String
    var recoveryVerifier: String?
}

struct ShareRecoveryRequestBody: Encodable {
    var deviceSelector: String
    var deviceVerifier: String
    var recoveryVerifier: String?
}

/// Recovery configuration always sends the `recoveryVerifier` key, using an
/// explicit JSON `null` to remove the verifier rather than omitting the
/// field — omission and `null` are different requests on the wire.
struct ShareRecoveryConfigurationRequestBody: Encodable {
    var recoveryVerifier: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let recoveryVerifier {
            try container.encode(recoveryVerifier, forKey: .recoveryVerifier)
        } else {
            try container.encodeNil(forKey: .recoveryVerifier)
        }
    }

    private enum CodingKeys: String, CodingKey { case recoveryVerifier }
}

public struct ShareOwnerMetadata: Codable, Sendable, Equatable {
    public var ownerId: String
    public var credentialGeneration: Int
    public var recoveryVerifier: String?
    public init(ownerId: String, credentialGeneration: Int, recoveryVerifier: String?) {
        self.ownerId = ownerId
        self.credentialGeneration = credentialGeneration
        self.recoveryVerifier = recoveryVerifier
    }
}

public struct ShareResource: Codable, Sendable, Equatable {
    public var id: String
    public var locatorCommitment: String
    public var contentRevision: Int
    public var version: Int
    public var contentWritable: Bool
    public var accessState: SharePublication.AccessState
    public var deletionState: SharePublication.DeletionState
    public var ciphertextBytes: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var expiresAt: Date
    public var maxExpiresAt: Date
    public var terminalAt: Date?
}

public struct ShareListPage: Codable, Sendable, Equatable {
    public var shares: [ShareResource]
    public var nextCursor: String?
}

struct ShareCreateOrUpdateRequestBody: Codable {
    var locator: String
    var contentRevision: Int
    var expiresAt: Date?
    var envelope: ShareEnvelope
}

struct ShareExpiryChangeRequestBody: Codable {
    var expiresAt: Date
}

struct ShareDeleteRequestBody: Codable {
    var locatorCommitment: String
}

public struct ShareDeletionReceipt: Codable, Sendable, Equatable {
    public var id: String
    public var locatorCommitment: String
    public var accessState: SharePublication.AccessState
    public var deletionState: SharePublication.DeletionState
}

struct ShareErrorEnvelope: Decodable {
    struct Body: Decodable {
        var code: String
        var retryable: Bool
        var requestId: String?
    }
    var error: Body
}

/// Stable error codes from the contract's "Error contract" section. `message`
/// is deliberately not modeled: it is non-stable display copy the contract
/// says the client should not rely on, and dropping it keeps sterile local
/// diagnostics an invariant rather than a discipline.
public enum ShareServiceErrorCode: String, Sendable, Equatable {
    case invalidRequest = "invalid_request"
    case unauthorized
    case contentNotWritable = "content_not_writable"
    case notFound = "not_found"
    case shareUnavailable = "share_unavailable"
    case enrollmentConflict = "enrollment_conflict"
    case locatorConflict = "locator_conflict"
    case idempotencyConflict = "idempotency_conflict"
    case payloadTooLarge = "payload_too_large"
    case versionConflict = "version_conflict"
    case preconditionRequired = "precondition_required"
    case unsupportedVersion = "unsupported_version"
    case invalidExpiry = "invalid_expiry"
    case quotaExceeded = "quota_exceeded"
    case rateLimited = "rate_limited"
    case serviceUnavailable = "service_unavailable"
    case internalError = "internal_error"
    /// Additive codes the client doesn't yet know about fail closed instead
    /// of crashing a decode.
    case unrecognized
}

public struct ShareAPIError: Error, Sendable, Equatable {
    public let code: ShareServiceErrorCode
    public let retryable: Bool
    public let requestId: String?
}

/// Transport- and origin-level failures that never reached a decodable
/// service response. Sterile by construction: no case carries a URL, body,
/// or header value.
public enum ShareClientError: Error, Sendable, Equatable {
    case unapprovedOrigin
    case network
    case unexpectedResponse
    case api(ShareAPIError)
}
