import Foundation

/// Whether the system-audio tap actually carried any signal during a meeting.
///
/// ScreenCaptureKit can keep a healthy-looking stream running while every sample
/// it hands back is zero. Buffers keep arriving, frames keep being written, and
/// the stall watchdogs in `SystemAudioStream` stay quiet because they only look
/// for buffers going *absent*, never for buffers being *empty*. The far side of
/// the call is lost for the whole meeting and every stop stage still reports
/// success.
///
/// The per-buffer level is already computed on the capture path, so the highest
/// one seen over a session is enough to tell the two cases apart after the fact.
public enum MeetingSystemAudioSignalVerdict: String, Sendable, Equatable {
    /// System audio was not part of this recording, or never produced a buffer.
    case notCaptured = "not_captured"
    /// The system track carried signal at some point.
    case present
    /// The system track was digital silence from start to finish.
    case silent

    /// - Parameter systemBufferObserved: whether any system buffer reached the
    ///   recording. Deliberately not `systemFirstBufferSeen`, which is only set
    ///   for buffers carrying a valid host time; tying the verdict to timestamp
    ///   validity would report a broken tap as `notCaptured` and swallow the
    ///   warning this type exists to raise.
    public static func evaluate(
        capturesSystemAudio: Bool,
        systemBufferObserved: Bool,
        systemPeakLevel: Float
    ) -> Self {
        guard capturesSystemAudio, systemBufferObserved else { return .notCaptured }
        return systemPeakLevel > 0 ? .present : .silent
    }

    /// A silent system track is only worth warning about when the recording ran
    /// long enough to be a real meeting and the microphone did carry signal.
    ///
    /// Both guards exist to keep quiet about the innocent cases: a few seconds of
    /// testing, or a session where nothing was audible on either side, is not
    /// evidence that the tap broke.
    public static func shouldWarn(
        verdict: Self,
        microphonePeakLevel: Float,
        durationSeconds: TimeInterval,
        minimumDurationSeconds: TimeInterval = defaultMinimumWarningDurationSeconds
    ) -> Bool {
        verdict == .silent
            && microphonePeakLevel > 0
            && durationSeconds >= minimumDurationSeconds
    }

    public static let defaultMinimumWarningDurationSeconds: TimeInterval = 30
}
