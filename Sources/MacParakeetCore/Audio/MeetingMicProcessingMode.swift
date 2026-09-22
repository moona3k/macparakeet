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

/// Readiness belongs to delivered audio, independently of a native start call
/// returning its processing report. An unavailable pending source may join the
/// same live session later; terminal interruption is a separate capture event.
public enum MeetingAudioCaptureSourceStartupState: Sendable, Equatable {
    case notSelected
    case starting
    case ready
    case unavailable
}

public struct MeetingAudioCaptureStartReport: Sendable, Equatable {
    public let sourceMode: MeetingAudioSourceMode
    public let microphone: MeetingMicrophoneCaptureStartReport
    public let microphoneStarted: Bool
    public let microphoneState: MeetingAudioCaptureSourceStartupState
    public let systemState: MeetingAudioCaptureSourceStartupState

    public init(microphone: MeetingMicrophoneCaptureStartReport) {
        self.sourceMode = .microphoneAndSystem
        self.microphone = microphone
        self.microphoneStarted = true
        self.microphoneState = .ready
        self.systemState = .ready
    }

    public init(
        sourceMode: MeetingAudioSourceMode,
        microphone: MeetingMicrophoneCaptureStartReport? = nil,
        microphoneState: MeetingAudioCaptureSourceStartupState? = nil,
        systemState: MeetingAudioCaptureSourceStartupState? = nil
    ) {
        self.sourceMode = sourceMode
        self.microphone =
            microphone
            ?? MeetingMicrophoneCaptureStartReport(
                requestedMode: .raw,
                effectiveMode: .raw
            )
        self.microphoneStarted = microphone != nil
        self.microphoneState =
            microphoneState
            ?? (sourceMode.capturesMicrophone ? (microphone != nil ? .ready : .unavailable) : .notSelected)
        self.systemState = systemState ?? (sourceMode.capturesSystemAudio ? .ready : .notSelected)
    }
}
