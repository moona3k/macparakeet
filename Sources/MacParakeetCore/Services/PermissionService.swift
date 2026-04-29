import AVFoundation
import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

public protocol PermissionServiceProtocol: Sendable {
    func checkMicrophonePermission() async -> PermissionStatus
    func requestMicrophonePermission() async -> Bool
    func checkScreenRecordingPermission() -> Bool
    func requestScreenRecordingPermission() -> Bool
    func openMicrophoneSettings()
    func openScreenRecordingSettings()
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

    public func checkScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    public func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    public func checkAccessibilityPermission() -> Bool {
        // AXIsProcessTrusted() checks if the app has Accessibility permission
        return AXIsProcessTrusted()
    }

    public func requestAccessibilityPermission(prompt: Bool = true) -> Bool {
        let options: CFDictionary = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
