import Foundation

/// Content-free capture facts retained across Stop, including failed settlement.
/// Frame counts are successfully written capture frames, excluding gap padding.
public struct MeetingCaptureDiagnostics: Sendable, Equatable {
    public let captureStartCompleted: Bool
    public let sourceMode: MeetingAudioSourceMode?
    public let elapsedSeconds: Double
    public let microphoneFrames: Int64
    public let systemFrames: Int64

    public init(
        captureStartCompleted: Bool,
        sourceMode: MeetingAudioSourceMode?,
        elapsedSeconds: Double,
        microphoneFrames: Int64,
        systemFrames: Int64
    ) {
        self.captureStartCompleted = captureStartCompleted
        self.sourceMode = sourceMode
        self.elapsedSeconds = elapsedSeconds
        self.microphoneFrames = microphoneFrames
        self.systemFrames = systemFrames
    }
}
