import Foundation

/// Audio source for speaker attribution from the dual-stream meeting capture pipeline.
public enum AudioSource: String, Codable, Sendable {
    case microphone
    case system

    public var displayLabel: String {
        switch self {
        case .microphone:
            return "Me"
        case .system:
            return "Others"
        }
    }
}
