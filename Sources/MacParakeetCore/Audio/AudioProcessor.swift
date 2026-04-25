import Foundation

/// Unified audio processor that handles both microphone capture and file conversion.
public actor AudioProcessor: AudioProcessorProtocol {
    private let recorder: AudioRecorder
    private let converter: AudioFileConverter

    public init(
        selectedInputDeviceUIDProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.recorder = AudioRecorder(
            selectedInputDeviceUIDProvider: selectedInputDeviceUIDProvider
        )
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
}
