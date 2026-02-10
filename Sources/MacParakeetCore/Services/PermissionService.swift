import AVFoundation
import ApplicationServices
import Foundation

public protocol PermissionServiceProtocol: Sendable {
    func checkMicrophonePermission() async -> PermissionStatus
    func requestMicrophonePermission() async -> Bool
    func checkAccessibilityPermission() -> Bool
    func requestAccessibilityPermission(prompt: Bool) -> Bool
}

public enum PermissionStatus: Sendable {
    case granted
    case denied
    case notDetermined
}

public final class PermissionService: PermissionServiceProtocol, Sendable {
    public init() {}

    public func checkMicrophonePermission() async -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    public func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func checkAccessibilityPermission() -> Bool {
        // AXIsProcessTrusted() checks if the app has Accessibility permission
        return AXIsProcessTrusted()
    }

    public func requestAccessibilityPermission(prompt: Bool = true) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [promptKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
