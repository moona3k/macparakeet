import Foundation

/// Unified audio processor that handles both microphone capture and file conversion.
public actor AudioProcessor: AudioProcessorProtocol {
    private let recorder: AudioRecorder
    private let converter: AudioFileConverter

    public init(sharedMicStream: SharedMicrophoneStream) {
        self.recorder = AudioRecorder(sharedStream: sharedMicStream)
        self.converter = AudioFileConverter()
    }

    /// File-only init for callers that never need mic capture (CLI, tests).
    /// Allocates an unstarted shared stream so the recorder API stays valid;
    /// no Core Audio engine starts until `startCapture()` runs.
    public init() {
        let stream = SharedMicrophoneStream(
            platform: AVAudioEngineMicrophonePlatform()
        )
        self.recorder = AudioRecorder(sharedStream: stream)
        self.converter = AudioFileConverter()
    }

    public var audioLevel: Float {
        get async { await recorder.audioLevel }
    }

    public var isRecording: Bool {
        get async { await recorder.isRecording }
    }

    public var recordingDeviceInfo: RecordingDeviceInfo? {
        get async { await recorder.deviceInfo }
    }

    public func convert(fileURL: URL) async throws -> URL {
        try await converter.convert(fileURL: fileURL)
    }

    public func startCapture() async throws {
        try await recorder.start()
    }

    public func stopCapture() async throws -> URL {
        try await recorder.stop()
    }

    public func setInstantDictationEnabled(_ enabled: Bool) async {
        await recorder.setInstantDictationEnabled(enabled)
    }

    public func refreshInstantDictationWarmCapture() async {
        await recorder.refreshInstantDictationWarmCapture()
    }
}
