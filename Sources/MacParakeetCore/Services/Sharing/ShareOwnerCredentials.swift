import CryptoKit
import Foundation
import Security

/// Cryptographically secure random bytes for identifiers, secrets, and
/// idempotency keys. `SecRandomCopyBytes` is the same primitive already used
/// by the Security-framework-backed Keychain store in this repo.
enum ShareRandom {
    static func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        return data
    }
}

/// Domain-separated verifier hashes from Share Service v1's "Owner and
/// recovery credentials" section. The service only ever stores these
/// digests, never the underlying secret.
enum ShareVerifier {
    static func device(selector: Data, secret: Data) -> String {
        digest(domain: "mp-device-v1", parts: [selector, secret])
    }

    static func recovery(ownerId: Data, secret: Data) -> String {
        digest(domain: "mp-recovery-v1", parts: [ownerId, secret])
    }

    static func locator(_ locator: ShareLocator) -> String {
        digest(domain: "mp-locator-v1", parts: [locator.bytes])
    }

    private static func digest(domain: String, parts: [Data]) -> String {
        var input = Data(domain.utf8)
        input.append(0)
        for part in parts { input.append(part) }
        return ShareBase64URL.encode(Data(SHA256.hash(data: input)))
    }
}

public enum ShareIdentifiers {
    /// 16 random bytes, base64url encoded — the shape shared by `ownerId`
    /// and a client-generated share `id`.
    public static func generate16ByteIdentifier() -> String {
        ShareBase64URL.encode(ShareRandom.bytes(16))
    }

    /// 128-bit `Idempotency-Key` value required by every owner enrollment,
    /// recovery, and share mutation request.
    public static func generateIdempotencyKey() -> String {
        ShareBase64URL.encode(ShareRandom.bytes(16))
    }

    /// A deterministic (not secret) 128-bit key derived from `ownerId`, used
    /// only for the owner-enrollment retry: it lets `ShareCoordinator` retry
    /// the exact same enrollment request after a restart without persisting
    /// a separate idempotency key alongside the credential.
    public static func deriveEnrollmentIdempotencyKey(ownerId: String) -> String {
        var input = Data("mp-enroll-idempotency-v1\u{0}".utf8)
        input.append(Data(ownerId.utf8))
        let digest = Data(SHA256.hash(data: input))
        return ShareBase64URL.encode(digest.prefix(16))
    }
}

public enum ShareCredentialTokenError: Error, Sendable, Equatable {
    case malformed
}

/// `mpd1.<16-byte-device-selector-base64url>.<32-byte-device-secret-base64url>`.
/// Authenticates owner operations via `Authorization: Bearer <token>`.
public struct ShareDeviceToken: Sendable, Equatable {
    public static let scheme = "mpd1"

    public let selector: Data
    public let secret: Data

    public init(selector: Data, secret: Data) {
        precondition(selector.count == 16 && secret.count == 32)
        self.selector = selector
        self.secret = secret
    }

    public init(rawValue: String) throws {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == Self.scheme,
            let selector = ShareBase64URL.decode(String(parts[1])), selector.count == 16,
            let secret = ShareBase64URL.decode(String(parts[2])), secret.count == 32
        else {
            throw ShareCredentialTokenError.malformed
        }
        self.selector = selector
        self.secret = secret
    }

    public static func generate() -> ShareDeviceToken {
        ShareDeviceToken(selector: ShareRandom.bytes(16), secret: ShareRandom.bytes(32))
    }

    public var rawValue: String {
        "\(Self.scheme).\(ShareBase64URL.encode(selector)).\(ShareBase64URL.encode(secret))"
    }

    public var authorizationHeaderValue: String { "Bearer \(rawValue)" }

    var selectorBase64URL: String { ShareBase64URL.encode(selector) }
    var secretBase64URL: String { ShareBase64URL.encode(secret) }

    public var verifier: String { ShareVerifier.device(selector: selector, secret: secret) }
}

/// `mpr1.<16-byte-owner-id-base64url>.<32-byte-recovery-secret-base64url>`.
/// One-time use: the server invalidates it atomically on recovery.
public struct ShareRecoveryToken: Sendable, Equatable {
    public static let scheme = "mpr1"

    public let ownerId: Data
    public let secret: Data

    public init(ownerId: Data, secret: Data) {
        precondition(ownerId.count == 16 && secret.count == 32)
        self.ownerId = ownerId
        self.secret = secret
    }

    public init(rawValue: String) throws {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == Self.scheme,
            let ownerId = ShareBase64URL.decode(String(parts[1])), ownerId.count == 16,
            let secret = ShareBase64URL.decode(String(parts[2])), secret.count == 32
        else {
            throw ShareCredentialTokenError.malformed
        }
        self.ownerId = ownerId
        self.secret = secret
    }

    public static func generate(ownerId: Data) -> ShareRecoveryToken {
        precondition(ownerId.count == 16)
        return ShareRecoveryToken(ownerId: ownerId, secret: ShareRandom.bytes(32))
    }

    public var rawValue: String {
        "\(Self.scheme).\(ShareBase64URL.encode(ownerId)).\(ShareBase64URL.encode(secret))"
    }

    public var authorizationHeaderValue: String { "Recovery \(rawValue)" }

    public var verifier: String { ShareVerifier.recovery(ownerId: ownerId, secret: secret) }
}
