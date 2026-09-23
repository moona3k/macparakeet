import Foundation
@testable import MacParakeetCore

public actor MockAudioProcessor: AudioProcessorProtocol {
    public var convertResult: URL?
    public var convertError: Error?
    public var captureResult: URL?
    public var captureError: Error?
    public var captureHealth: AudioCaptureHealth?
    private var _audioLevel: Float = 0.0
    private var _isRecording = false
    private var startCaptureDelayMs: UInt64 = 0
    private var pauseNextStopCapture = false
    private var strictStopRequiresRecording = false
    private var stopCapturePaused = false
    private var stopCapturePauseWaiter: CheckedContinuation<Void, Never>?
    private var stopCaptureRelease: CheckedContinuation<Void, Never>?
    public var startCaptureCalled = false
    public var startCaptureCallCount = 0
    public var stopCaptureCalled = false
    public var stopCaptureCallCount = 0
    public var successfulStopCaptureCount = 0
    public var convertCallCount = 0
    public var lastConvertURL: URL?
    public var lastAudioTrackOrdinal: Int?
    public var convertURLs: [URL] = []
    public var liveSampleSink: DictationAudioSampleSink?

    public init() {}

    public func configure(convertResult: URL) {
        self.convertResult = convertResult
        self.convertError = nil
    }

    public func configure(captureResult: URL) {
        self.captureResult = captureResult
        self.captureError = nil
    }

    public func configure(lastCaptureHealth: AudioCaptureHealth?) {
        self.captureHealth = lastCaptureHealth
    }

    public func configureConvertError(_ error: Error) {
        self.convertError = error
    }

    public func configureCaptureError(_ error: Error) {
        self.captureError = error
    }

    public func configureStartCaptureDelay(milliseconds: UInt64) {
        self.startCaptureDelayMs = milliseconds
    }

    public func pauseNextStopCaptureUntilReleased() {
        pauseNextStopCapture = true
    }

    public func requireRecordingForStopCapture() {
        strictStopRequiresRecording = true
    }

    public func waitUntilStopCaptureIsPaused() async {
        if stopCapturePaused { return }
        await withCheckedContinuation { stopCapturePauseWaiter = $0 }
    }

    public func releasePausedStopCapture() {
        stopCaptureRelease?.resume()
        stopCaptureRelease = nil
    }

    public func setAudioLevel(_ level: Float) {
        self._audioLevel = level
    }

    public var audioLevel: Float {
        _audioLevel
    }

    public var isRecording: Bool {
        _isRecording
    }

    public var recordingDeviceInfo: RecordingDeviceInfo? {
        nil
    }

    public var lastCaptureHealth: AudioCaptureHealth? {
        captureHealth
    }

    public func convert(fileURL: URL) async throws -> URL {
        try await convert(fileURL: fileURL, audioTrackOrdinal: nil)
    }

    public func convert(fileURL: URL, audioTrackOrdinal: Int?) async throws -> URL {
        convertCallCount += 1
        lastConvertURL = fileURL
        lastAudioTrackOrdinal = audioTrackOrdinal
        convertURLs.append(fileURL)
        if let error = convertError { throw error }
        return convertResult ?? URL(fileURLWithPath: "/tmp/converted.wav")
    }

    public func startCapture() async throws {
        try await startCapture(sampleSink: nil)
    }

    public func startCapture(sampleSink: DictationAudioSampleSink?) async throws {
        startCaptureCalled = true
        startCaptureCallCount += 1
        if startCaptureDelayMs > 0 {
            try await Task.sleep(for: .milliseconds(Int(startCaptureDelayMs)))
        }
        if let error = captureError {
            sampleSink?.onFinish()
            throw error
        }
        _isRecording = true
        liveSampleSink = sampleSink
    }

    public func stopCapture() async throws -> URL {
        stopCaptureCalled = true
        stopCaptureCallCount += 1
        if strictStopRequiresRecording && !_isRecording {
            throw AudioProcessorError.recordingFailed("Not recording")
        }
        successfulStopCaptureCount += 1
        _isRecording = false
        liveSampleSink?.onFinish()
        liveSampleSink = nil
        if pauseNextStopCapture {
            pauseNextStopCapture = false
            stopCapturePaused = true
            stopCapturePauseWaiter?.resume()
            stopCapturePauseWaiter = nil
            await withCheckedContinuation { stopCaptureRelease = $0 }
            stopCapturePaused = false
        }
        if let error = captureError { throw error }
        return captureResult ?? URL(fileURLWithPath: "/tmp/recording.wav")
    }

    public func emitLiveSamples(_ samples: [Float]) {
        liveSampleSink?.onSamples(samples)
    }

    public var discardPreRollCallCount = 0

    public func discardPreRollForActiveCapture() async {
        discardPreRollCallCount += 1
    }
}
