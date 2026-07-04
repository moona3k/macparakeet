import Foundation

public struct MeetingSourceHealth: Sendable, Equatable, Codable {
    public enum Source: String, Sendable, Equatable, Codable {
        case microphone
        case system

        init(_ source: AudioSource) {
            switch source {
            case .microphone:
                self = .microphone
            case .system:
                self = .system
            }
        }
    }

    public enum Status: String, Sendable, Equatable, Codable {
        case notSelected
        case starting
        case live
        case muted
        case silent
        case stalled
        case interrupted
        case unavailable

        public var isDegraded: Bool {
            switch self {
            case .muted, .silent, .stalled, .interrupted, .unavailable:
                return true
            case .notSelected, .starting, .live:
                return false
            }
        }
    }

    public enum RecoveryAction: String, Sendable, Equatable, Codable {
        case changeSourceMode
        case unmuteMicrophone
        case checkMicrophoneInput
        case openMicrophoneSettings
        case openSystemAudioSettings
        case restartRecording
    }

    public var source: Source
    public var status: Status
    public var level: Float
    public var lastBufferAt: Date?
    public var detail: String?
    public var recoveryAction: RecoveryAction?

    public init(
        source: Source,
        status: Status,
        level: Float = 0,
        lastBufferAt: Date? = nil,
        detail: String? = nil,
        recoveryAction: RecoveryAction? = nil
    ) {
        self.source = source
        self.status = status
        self.level = level
        self.lastBufferAt = lastBufferAt
        self.detail = detail
        self.recoveryAction = recoveryAction
    }

    public var label: String {
        switch (source, status) {
        case (.microphone, .notSelected):
            return "Mic not recorded"
        case (.system, .notSelected):
            return "System not recorded"
        case (.microphone, .starting):
            return "Mic starting"
        case (.system, .starting):
            return "System starting"
        case (.microphone, .live):
            return "Mic live"
        case (.system, .live):
            return "System live"
        case (.microphone, .muted):
            return "Mic muted"
        case (.system, .muted):
            return "System muted"
        case (.microphone, .silent):
            return "Mic may be silent"
        case (.system, .silent):
            return "System may be silent"
        case (.microphone, .stalled):
            return "Mic may be stalled"
        case (.system, .stalled):
            return "System may be stalled"
        case (.microphone, .interrupted):
            return "Mic interrupted"
        case (.system, .interrupted):
            return "System audio interrupted"
        case (.microphone, .unavailable):
            return "Mic unavailable"
        case (.system, .unavailable):
            return "System unavailable"
        }
    }

    var degradationPriority: Int? {
        switch status {
        case .unavailable:
            return 0
        case .interrupted:
            return 1
        case .stalled:
            return 2
        case .muted:
            return 3
        case .silent:
            return 4
        case .notSelected, .starting, .live:
            return nil
        }
    }
}

public struct MeetingCaptureHealthSummary: Sendable, Equatable, Codable {
    public var sourceMode: MeetingAudioSourceMode
    public var microphone: MeetingSourceHealth
    public var system: MeetingSourceHealth

    public init(
        sourceMode: MeetingAudioSourceMode,
        microphone: MeetingSourceHealth,
        system: MeetingSourceHealth
    ) {
        self.sourceMode = sourceMode
        self.microphone = microphone
        self.system = system
    }

    public static let notRecording = MeetingCaptureHealthSummary(
        sourceMode: .microphoneAndSystem,
        microphone: MeetingSourceHealth(source: .microphone, status: .notSelected),
        system: MeetingSourceHealth(source: .system, status: .notSelected)
    )

    public static func starting(sourceMode: MeetingAudioSourceMode) -> MeetingCaptureHealthSummary {
        MeetingCaptureHealthSummary(
            sourceMode: sourceMode,
            microphone: MeetingSourceHealth(
                source: .microphone,
                status: sourceMode.capturesMicrophone ? .starting : .notSelected,
                recoveryAction: sourceMode.capturesMicrophone ? nil : .changeSourceMode
            ),
            system: MeetingSourceHealth(
                source: .system,
                status: sourceMode.capturesSystemAudio ? .starting : .notSelected,
                recoveryAction: sourceMode.capturesSystemAudio ? nil : .changeSourceMode
            )
        )
    }

    public var isDegraded: Bool {
        microphone.status.isDegraded || system.status.isDegraded
    }

    public var primaryMessage: String? {
        primaryDegradedSource?.label
    }

    public var primaryDegradedSource: MeetingSourceHealth? {
        [microphone, system]
            .filter { $0.status.isDegraded }
            .sorted { lhs, rhs in
                (lhs.degradationPriority ?? Int.max) < (rhs.degradationPriority ?? Int.max)
            }
            .first
    }

    public static func reduce(
        sourceMode: MeetingAudioSourceMode,
        microphoneLevel: Float,
        systemLevel: Float,
        lastBufferAt: [AudioSource: Date],
        isMicrophoneMuted: Bool,
        microphoneStarted: Bool,
        interruptedSources: Set<AudioSource>,
        activeMicrophoneStall: MeetingMicHealthMonitor.StallSignature?,
        captureFailed: Bool
    ) -> MeetingCaptureHealthSummary {
        let microphone = sourceHealth(
            source: .microphone,
            sourceMode: sourceMode,
            level: microphoneLevel,
            lastBufferAt: lastBufferAt[.microphone],
            isMicrophoneMuted: isMicrophoneMuted,
            microphoneStarted: microphoneStarted,
            interruptedSources: interruptedSources,
            activeMicrophoneStall: activeMicrophoneStall,
            captureFailed: captureFailed
        )
        let system = sourceHealth(
            source: .system,
            sourceMode: sourceMode,
            level: systemLevel,
            lastBufferAt: lastBufferAt[.system],
            isMicrophoneMuted: isMicrophoneMuted,
            microphoneStarted: microphoneStarted,
            interruptedSources: interruptedSources,
            activeMicrophoneStall: activeMicrophoneStall,
            captureFailed: captureFailed
        )
        return MeetingCaptureHealthSummary(
            sourceMode: sourceMode,
            microphone: microphone,
            system: system
        )
    }

    private static func sourceHealth(
        source: AudioSource,
        sourceMode: MeetingAudioSourceMode,
        level: Float,
        lastBufferAt: Date?,
        isMicrophoneMuted: Bool,
        microphoneStarted: Bool,
        interruptedSources: Set<AudioSource>,
        activeMicrophoneStall: MeetingMicHealthMonitor.StallSignature?,
        captureFailed: Bool
    ) -> MeetingSourceHealth {
        let selected = source == .microphone
            ? sourceMode.capturesMicrophone
            : sourceMode.capturesSystemAudio
        guard selected else {
            return MeetingSourceHealth(
                source: MeetingSourceHealth.Source(source),
                status: .notSelected,
                detail: "The selected meeting source mode does not record this channel.",
                recoveryAction: .changeSourceMode
            )
        }

        if captureFailed {
            let status: MeetingSourceHealth.Status = interruptedSources.contains(source)
                ? .interrupted
                : .unavailable
            return MeetingSourceHealth(
                source: MeetingSourceHealth.Source(source),
                status: status,
                level: 0,
                lastBufferAt: lastBufferAt,
                recoveryAction: recoveryAction(for: source, status: status)
            )
        }

        if interruptedSources.contains(source) {
            return MeetingSourceHealth(
                source: MeetingSourceHealth.Source(source),
                status: .interrupted,
                level: 0,
                lastBufferAt: lastBufferAt,
                recoveryAction: .restartRecording
            )
        }

        if source == .microphone, isMicrophoneMuted {
            return MeetingSourceHealth(
                source: .microphone,
                status: .muted,
                level: 0,
                lastBufferAt: lastBufferAt,
                recoveryAction: .unmuteMicrophone
            )
        }

        if source == .microphone, activeMicrophoneStall != nil {
            return MeetingSourceHealth(
                source: .microphone,
                status: .stalled,
                level: level,
                lastBufferAt: lastBufferAt,
                recoveryAction: .checkMicrophoneInput
            )
        }

        if source == .microphone, !microphoneStarted, lastBufferAt == nil {
            return MeetingSourceHealth(
                source: .microphone,
                status: .unavailable,
                level: 0,
                recoveryAction: .openMicrophoneSettings
            )
        }

        guard let lastBufferAt else {
            return MeetingSourceHealth(
                source: MeetingSourceHealth.Source(source),
                status: .starting,
                level: 0
            )
        }

        let clampedLevel = max(0, min(1, level))
        let status: MeetingSourceHealth.Status = clampedLevel < AudioCaptureHealth.silentInputMaximumLevel
            ? .silent
            : .live
        return MeetingSourceHealth(
            source: MeetingSourceHealth.Source(source),
            status: status,
            level: clampedLevel,
            lastBufferAt: lastBufferAt,
            recoveryAction: recoveryAction(for: source, status: status)
        )
    }

    private static func recoveryAction(
        for source: AudioSource,
        status: MeetingSourceHealth.Status
    ) -> MeetingSourceHealth.RecoveryAction? {
        switch (source, status) {
        case (.microphone, .silent):
            return .checkMicrophoneInput
        case (.system, .silent):
            return .openSystemAudioSettings
        case (.microphone, .unavailable):
            return .openMicrophoneSettings
        case (.system, .unavailable):
            return .openSystemAudioSettings
        case (_, .interrupted):
            return .restartRecording
        case (.microphone, .muted):
            return .unmuteMicrophone
        default:
            return nil
        }
    }
}
