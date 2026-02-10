import Foundation

public protocol KeyValueStore: Sendable {
    func getString(_ key: String) throws -> String?
    func setString(_ value: String, forKey key: String) throws
    func delete(_ key: String) throws
}

public enum KeyValueStoreError: Error, LocalizedError {
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Key-value store operation is unsupported."
        }
    }
}

