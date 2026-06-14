import Foundation

/// Pure auto-stop policy for ADR-023. No AppKit, timers, audio APIs, or UI.
/// The app coordinator owns signal observation, grace clocks, and countdown UI;
/// this policy only decides whether the current observation is stop-eligible.
public enum MeetingAutoStopPolicy {
    public struct MeetingContext: Sendable, Equatable {
        /// Recognized meeting apps observed running at or after recording start.
        public var observedMeetingAppBundleIDs: Set<String>
        public var startedAt: Date

        public init(observedMeetingAppBundleIDs: Set<String>, startedAt: Date) {
            self.observedMeetingAppBundleIDs = observedMeetingAppBundleIDs
            self.startedAt = startedAt
        }
    }

    public struct Observation: Sendable, Equatable {
        public var now: Date
        public var isRecording: Bool
        public var isPaused: Bool
        public var runningMeetingAppBundleIDs: Set<String>
        /// Continuous seconds where both meeting channels have stayed below
        /// the coordinator's silence threshold.
        public var continuousSilenceSeconds: TimeInterval

        public init(
            now: Date,
            isRecording: Bool,
            isPaused: Bool,
            runningMeetingAppBundleIDs: Set<String>,
            continuousSilenceSeconds: TimeInterval
        ) {
            self.now = now
            self.isRecording = isRecording
            self.isPaused = isPaused
            self.runningMeetingAppBundleIDs = runningMeetingAppBundleIDs
            self.continuousSilenceSeconds = continuousSilenceSeconds
        }
    }

    public struct Config: Sendable, Equatable {
        public var appQuitEnabled: Bool
        public var silenceEnabled: Bool
        /// Read by the app coordinator before it calls the policy for an
        /// app-quit proposal. Stored here so one config object describes the
        /// complete ADR-023 posture.
        public var appQuitGraceSeconds: TimeInterval
        public var silenceGraceSeconds: TimeInterval

        public init(
            appQuitEnabled: Bool = true,
            silenceEnabled: Bool = true,
            appQuitGraceSeconds: TimeInterval = 15,
            silenceGraceSeconds: TimeInterval = 240
        ) {
            self.appQuitEnabled = appQuitEnabled
            self.silenceEnabled = silenceEnabled
            self.appQuitGraceSeconds = appQuitGraceSeconds
            self.silenceGraceSeconds = silenceGraceSeconds
        }

        public static let `default` = Config()
    }

    public enum StopReason: Sendable, Equatable, Hashable {
        case meetingAppClosed(bundleID: String)
        case prolongedSilence

        public var telemetryReason: TelemetryMeetingAutoStopReason {
            switch self {
            case .meetingAppClosed:
                return .meetingAppClosed
            case .prolongedSilence:
                return .prolongedSilence
            }
        }
    }

    public enum Decision: Sendable, Equatable {
        case keepRecording
        case proposeStop(reason: StopReason)
    }

    public static func evaluate(
        context: MeetingContext,
        observation: Observation,
        config: Config
    ) -> Decision {
        guard observation.isRecording, !observation.isPaused else {
            return .keepRecording
        }

        if config.appQuitEnabled,
           let closedBundleID = closedObservedMeetingApp(
               observed: context.observedMeetingAppBundleIDs,
               running: observation.runningMeetingAppBundleIDs
           ) {
            return .proposeStop(reason: .meetingAppClosed(bundleID: closedBundleID))
        }

        if config.silenceEnabled,
           observation.continuousSilenceSeconds >= config.silenceGraceSeconds {
            return .proposeStop(reason: .prolongedSilence)
        }

        return .keepRecording
    }

    private static func closedObservedMeetingApp(
        observed: Set<String>,
        running: Set<String>
    ) -> String? {
        observed
            .subtracting(running)
            .sorted()
            .first
    }
}
