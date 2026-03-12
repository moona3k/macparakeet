import Foundation
import ServiceManagement

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unsupported

    public var isEnabled: Bool {
        switch self {
        case .enabled, .requiresApproval:
            return true
        case .disabled, .unsupported:
            return false
        }
    }

    public var detailText: String {
        switch self {
        case .enabled:
            return "MacParakeet will open automatically when you sign in."
        case .disabled:
            return ""
        case .requiresApproval:
            return "Finish enabling this in System Settings > General > Login Items."
        case .unsupported:
            return "Launch at login is only available from the signed app bundle."
        }
    }
}

public enum LaunchAtLoginError: Error, LocalizedError, Equatable {
    case unsupportedEnvironment
    case requiresApproval
    case invalidSignature
    case deniedByUser
    case serviceUnavailable
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedEnvironment:
            return "Launch at login is unavailable in this build."
        case .requiresApproval:
            return "macOS requires approval in System Settings > General > Login Items."
        case .invalidSignature:
            return "Launch at login requires a properly signed MacParakeet app."
        case .deniedByUser:
            return "macOS blocked launch at login. Enable MacParakeet in System Settings > General > Login Items."
        case .serviceUnavailable:
            return "Launch at login is temporarily unavailable. Try again in a moment."
        case .operationFailed(let message):
            return message
        }
    }
}

public protocol LaunchAtLoginControlling {
    func currentStatus() -> LaunchAtLoginStatus
    func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginStatus
}

public final class LaunchAtLoginService: LaunchAtLoginControlling {
    private let bundle: Bundle
    private let serviceProvider: () -> SMAppService

    public init(
        bundle: Bundle = .main,
        serviceProvider: @escaping () -> SMAppService = { SMAppService.mainApp }
    ) {
        self.bundle = bundle
        self.serviceProvider = serviceProvider
    }

    public func currentStatus() -> LaunchAtLoginStatus {
        guard isSupportedEnvironment else { return .unsupported }

        switch serviceProvider().status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unsupported
        @unknown default:
            return .unsupported
        }
    }

    public func setEnabled(_ enabled: Bool) throws -> LaunchAtLoginStatus {
        guard isSupportedEnvironment else {
            throw LaunchAtLoginError.unsupportedEnvironment
        }

        let service = serviceProvider()
        let current = currentStatus()
        if enabled, current == .enabled || current == .requiresApproval {
            return current
        }
        if !enabled, current == .disabled {
            return current
        }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            let nsError = error as NSError
            if enabled, nsError.code == kSMErrorAlreadyRegistered {
                return currentStatus()
            }
            if !enabled, nsError.code == kSMErrorJobNotFound {
                return currentStatus()
            }
            throw mapError(nsError)
        }

        let updated = currentStatus()
        if enabled, updated == .requiresApproval {
            throw LaunchAtLoginError.requiresApproval
        }
        return updated
    }

    private var isSupportedEnvironment: Bool {
        bundle.bundleURL.pathExtension == "app"
    }

    private func mapError(_ error: NSError) -> LaunchAtLoginError {
        switch error.code {
        case kSMErrorLaunchDeniedByUser:
            return .deniedByUser
        case kSMErrorInvalidSignature:
            return .invalidSignature
        case kSMErrorServiceUnavailable:
            return .serviceUnavailable
        default:
            return .operationFailed(error.localizedDescription)
        }
    }
}
