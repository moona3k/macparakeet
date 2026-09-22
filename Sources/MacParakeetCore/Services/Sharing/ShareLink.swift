import CryptoKit
import Foundation

/// Base64url (unpadded) helpers shared by the sharing types. Every decode
/// round-trips through re-encoding so non-canonical encodings (wrong padding,
/// stray bits) fail closed instead of silently accepting them.
enum ShareBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        guard !string.isEmpty,
            string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else {
            return nil
        }

        var base64 =
            string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64), encode(data) == string else {
            return nil
        }
        return data
    }
}

public enum ShareLinkError: Error, Sendable, Equatable {
    case invalidLocatorEncoding
    case invalidContentKeyEncoding
    case invalidScheme
    case invalidHost
    case invalidPath
    case missingFragment
    case invalidFragmentVersion
}

/// The 16-byte random public locator in a share URL's path.
public struct ShareLocator: Sendable, Equatable, Hashable {
    public static let byteCount = 16
    public static let encodedLength = 22

    public let rawValue: String
    public let bytes: Data

    public init(rawValue: String) throws {
        guard rawValue.count == Self.encodedLength,
            let data = ShareBase64URL.decode(rawValue),
            data.count == Self.byteCount
        else {
            throw ShareLinkError.invalidLocatorEncoding
        }
        self.rawValue = rawValue
        self.bytes = data
    }

    init(bytes: Data) {
        precondition(bytes.count == Self.byteCount, "ShareLocator requires exactly \(Self.byteCount) bytes")
        self.bytes = bytes
        self.rawValue = ShareBase64URL.encode(bytes)
    }

    public static func generate() -> ShareLocator {
        let key = SymmetricKey(size: SymmetricKeySize(bitCount: byteCount * 8))
        return ShareLocator(bytes: key.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) })
    }
}

/// The 32-byte random content key carried only in a share URL's fragment.
public struct ShareContentKey: Sendable, Equatable {
    public static let byteCount = 32
    public static let encodedLength = 43

    public let rawValue: String
    public let bytes: Data

    public init(rawValue: String) throws {
        guard rawValue.count == Self.encodedLength,
            let data = ShareBase64URL.decode(rawValue),
            data.count == Self.byteCount
        else {
            throw ShareLinkError.invalidContentKeyEncoding
        }
        self.rawValue = rawValue
        self.bytes = data
    }

    init(bytes: Data) {
        precondition(bytes.count == Self.byteCount, "ShareContentKey requires exactly \(Self.byteCount) bytes")
        self.bytes = bytes
        self.rawValue = ShareBase64URL.encode(bytes)
    }

    public static func generate() -> ShareContentKey {
        let key = SymmetricKey(size: SymmetricKeySize(bitCount: byteCount * 8))
        return ShareContentKey(bytes: key.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) })
    }
}

/// The complete recipient link defined by Share Link and Bundle v1:
/// `https://share.macparakeet.com/s/<locator>#v1.<content-key>`.
public struct ShareLink: Sendable, Equatable {
    public static let host = "share.macparakeet.com"
    public static let fragmentVersion = "v1"

    public var locator: ShareLocator
    public var contentKey: ShareContentKey

    public init(locator: ShareLocator, contentKey: ShareContentKey) {
        self.locator = locator
        self.contentKey = contentKey
    }

    public static func generate() -> ShareLink {
        ShareLink(locator: .generate(), contentKey: .generate())
    }

    /// The complete URL, including the fragment. Only copy and the macOS
    /// share sheet should use this value.
    public var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = "/s/\(locator.rawValue)"
        components.fragment = "\(Self.fragmentVersion).\(contentKey.rawValue)"
        guard let url = components.url else {
            preconditionFailure("ShareLink produced an unconstructable URL")
        }
        return url
    }

    /// The same URL with its fragment stripped. Every actual network request
    /// must use this value instead of `url`, since the fragment is never sent
    /// to the service.
    public var requestURL: URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.fragment = nil
        guard let url = components.url else {
            preconditionFailure("ShareLink produced an unconstructable request URL")
        }
        return url
    }

    public init(url: URL) throws {
        guard url.scheme == "https" else { throw ShareLinkError.invalidScheme }
        guard url.host == Self.host, url.port == nil, url.user == nil, url.password == nil else {
            throw ShareLinkError.invalidHost
        }
        guard url.query == nil else { throw ShareLinkError.invalidPath }

        let pathComponents = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard pathComponents.count == 2, pathComponents[0] == "s" else {
            throw ShareLinkError.invalidPath
        }
        let locator = try ShareLocator(rawValue: String(pathComponents[1]))
        guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/s/\(locator.rawValue)"
        else {
            throw ShareLinkError.invalidPath
        }

        guard let fragment = url.fragment, !fragment.isEmpty else {
            throw ShareLinkError.missingFragment
        }
        let fragmentParts = fragment.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard fragmentParts.count == 2, fragmentParts[0] == Self.fragmentVersion else {
            throw ShareLinkError.invalidFragmentVersion
        }
        let contentKey = try ShareContentKey(rawValue: String(fragmentParts[1]))

        self.init(locator: locator, contentKey: contentKey)
    }
}
