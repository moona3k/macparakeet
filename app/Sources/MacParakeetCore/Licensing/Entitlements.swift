import Foundation

public struct LicensingConfig: Sendable {
    /// Optional checkout URL used by the UI ("Buy" button).
    public let checkoutURL: URL?

    /// Optional: if set, we require the activated license to match this variant/product.
    public let expectedVariantID: Int?

    public init(checkoutURL: URL?, expectedVariantID: Int?) {
        self.checkoutURL = checkoutURL
        self.expectedVariantID = expectedVariantID
    }
}

public struct EntitlementsState: Sendable, Equatable {
    public enum Access: Sendable, Equatable {
        case unlocked
        case trialActive(daysRemaining: Int, endsAt: Date)
        case trialExpired(endedAt: Date)
    }

    public let access: Access
    public let licenseKeyMasked: String?
    public let lastValidatedAt: Date?

    public init(access: Access, licenseKeyMasked: String?, lastValidatedAt: Date?) {
        self.access = access
        self.licenseKeyMasked = licenseKeyMasked
        self.lastValidatedAt = lastValidatedAt
    }
}

public protocol EntitlementsChecking: Sendable {
    func assertCanTranscribe(now: Date) async throws
    func currentState(now: Date) async -> EntitlementsState
}

public enum EntitlementsError: Error, LocalizedError, Sendable {
    case trialExpired
    case activationFailed(String)
    case invalidLicense(String)
    case network(String)
    case configuration(String)

    public var errorDescription: String? {
        switch self {
        case .trialExpired:
            return "Your 7-day trial has ended. Unlock MacParakeet to continue transcribing."
        case .activationFailed(let msg):
            return msg
        case .invalidLicense(let msg):
            return msg
        case .network(let msg):
            return msg
        case .configuration(let msg):
            return msg
        }
    }
}

