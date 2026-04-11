import Foundation

public enum MeetingMicProcessingMode: Sendable, Equatable {
    case vpioPreferred
    case vpioRequired
    case raw
}

public enum MeetingMicProcessingEffectiveMode: String, Sendable, Equatable {
    case vpio
    case raw
}

public struct MeetingMicrophoneCaptureStartReport: Sendable, Equatable {
    public let requestedMode: MeetingMicProcessingMode
    public let effectiveMode: MeetingMicProcessingEffectiveMode

    public init(
        requestedMode: MeetingMicProcessingMode,
        effectiveMode: MeetingMicProcessingEffectiveMode
    ) {
        self.requestedMode = requestedMode
        self.effectiveMode = effectiveMode
    }

    public var fellBackToRaw: Bool {
        requestedMode != .raw && effectiveMode == .raw
    }
}

public struct MeetingAudioCaptureStartReport: Sendable, Equatable {
    public let microphone: MeetingMicrophoneCaptureStartReport

    public init(microphone: MeetingMicrophoneCaptureStartReport) {
        self.microphone = microphone
    }
}
