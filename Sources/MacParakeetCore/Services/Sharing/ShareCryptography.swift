import CryptoKit
import Foundation

public enum ShareCryptographyError: Error, Sendable, Equatable {
    case invalidNonceEncoding
    case invalidNonceLength
    case invalidCiphertextEncoding
    case invalidCiphertextLength
    case invalidContentRevision
    case unknownSchema(String)
    case unknownSchemaVersion(Int)
    case unknownAlgorithm(String)
    case plaintextTooLarge(byteCount: Int)
    case authenticationFailed
    case malformedJSON
}

/// The encrypted envelope stored by the service, matching the
/// `com.macparakeet.share-envelope` wire schema exactly. The service can
/// validate this shape but never has the key needed to open it.
public struct ShareEnvelope: Sendable, Equatable {
    public static let schema = "com.macparakeet.share-envelope"
    public static let schemaVersion = 1
    public static let algorithm = "A256GCM"

    /// GCM tags are always 16 bytes, so this is the floor for a valid
    /// combined ciphertext-and-tag value (an empty plaintext still has a tag).
    private static let tagByteCount = 16

    /// The maximum decoded ciphertext-plus-tag size allowed by the contract.
    public static let maxCiphertextAndTagBytes = 2_097_168

    public let nonce: Data
    public let ciphertextAndTag: Data

    public init(nonce: Data, ciphertextAndTag: Data) throws {
        guard nonce.count == 12 else { throw ShareCryptographyError.invalidNonceLength }
        guard ciphertextAndTag.count >= Self.tagByteCount,
            ciphertextAndTag.count <= Self.maxCiphertextAndTagBytes
        else {
            throw ShareCryptographyError.invalidCiphertextLength
        }
        self.nonce = nonce
        self.ciphertextAndTag = ciphertextAndTag
    }

    var ciphertext: Data { ciphertextAndTag.dropLast(Self.tagByteCount) }
    var tag: Data { ciphertextAndTag.suffix(Self.tagByteCount) }
}

extension ShareEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case schema, schemaVersion, algorithm, nonce, ciphertext
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let schema = try container.decode(String.self, forKey: .schema)
        guard schema == Self.schema else { throw ShareCryptographyError.unknownSchema(schema) }

        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw ShareCryptographyError.unknownSchemaVersion(schemaVersion)
        }

        let algorithm = try container.decode(String.self, forKey: .algorithm)
        guard algorithm == Self.algorithm else { throw ShareCryptographyError.unknownAlgorithm(algorithm) }

        let nonceString = try container.decode(String.self, forKey: .nonce)
        guard let nonce = ShareBase64URL.decode(nonceString) else {
            throw ShareCryptographyError.invalidNonceEncoding
        }

        let ciphertextString = try container.decode(String.self, forKey: .ciphertext)
        guard let ciphertextAndTag = ShareBase64URL.decode(ciphertextString) else {
            throw ShareCryptographyError.invalidCiphertextEncoding
        }

        try self.init(nonce: nonce, ciphertextAndTag: ciphertextAndTag)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schema, forKey: .schema)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(Self.algorithm, forKey: .algorithm)
        try container.encode(ShareBase64URL.encode(nonce), forKey: .nonce)
        try container.encode(ShareBase64URL.encode(ciphertextAndTag), forKey: .ciphertext)
    }

    public func encodedJSON() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decodedFromJSON(_ data: Data) throws -> ShareEnvelope {
        try JSONDecoder().decode(ShareEnvelope.self, from: data)
    }
}

/// AES-256-GCM sealing and opening for share bundles, per Share Link and
/// Bundle v1. Every revision uses a fresh random nonce, and the additional
/// authenticated data binds the ciphertext to one locator and one content
/// revision so a valid envelope can never be replayed under another.
public enum ShareCryptography {
    static func additionalAuthenticatedData(locator: ShareLocator, contentRevision: Int) throws -> Data {
        guard contentRevision >= 1 else { throw ShareCryptographyError.invalidContentRevision }
        let aad = "com.macparakeet.share-envelope\u{0}v1\u{0}\(locator.rawValue)\u{0}\(contentRevision)"
        return Data(aad.utf8)
    }

    public static func seal(
        plaintext: Data,
        contentKey: ShareContentKey,
        locator: ShareLocator,
        contentRevision: Int
    ) throws -> ShareEnvelope {
        guard plaintext.count <= ShareBundle.maxPlaintextBytes else {
            throw ShareCryptographyError.plaintextTooLarge(byteCount: plaintext.count)
        }

        let key = SymmetricKey(data: contentKey.bytes)
        let aad = try additionalAuthenticatedData(locator: locator, contentRevision: contentRevision)
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: aad)

        return try ShareEnvelope(
            nonce: Data(sealedBox.nonce),
            ciphertextAndTag: sealedBox.ciphertext + sealedBox.tag
        )
    }

    public static func open(
        envelope: ShareEnvelope,
        contentKey: ShareContentKey,
        locator: ShareLocator,
        contentRevision: Int
    ) throws -> Data {
        let key = SymmetricKey(data: contentKey.bytes)
        let aad = try additionalAuthenticatedData(locator: locator, contentRevision: contentRevision)

        do {
            let nonce = try AES.GCM.Nonce(data: envelope.nonce)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce, ciphertext: envelope.ciphertext, tag: envelope.tag
            )
            return try AES.GCM.open(sealedBox, using: key, authenticating: aad)
        } catch {
            throw ShareCryptographyError.authenticationFailed
        }
    }
}
