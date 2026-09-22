import Foundation

/// Audio source for speaker attribution from the dual-stream meeting capture pipeline.
public enum AudioSource: String, Codable, Sendable, Hashable {
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

    /// Meeting `microphone` / `system` rows are capture channels, not diarized
    /// people. Voice identity must not attach to them: a link on `Me` would
    /// hide that voice from the real clusters in the same transcript.
    public static func isMeetingCaptureTrack(_ speakerId: String) -> Bool {
        Self(rawValue: speakerId) != nil
    }
}
