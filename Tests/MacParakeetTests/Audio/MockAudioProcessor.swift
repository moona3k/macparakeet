import Foundation
@testable import MacParakeetCore

public actor MockAudioProcessor: AudioProcessorProtocol {
    public var convertResult: URL?
    public var convertError: Error?
    public var captureResult: URL?
    public var captureError: Error?
    private var _audioLevel: Float = 0.0
    private var _isRecording = false
    public var startCaptureCalled = false
    public var stopCaptureCalled = false
    public var convertCallCount = 0
    public var lastConvertURL: URL?

    public init() {}

    public func configure(convertResult: URL) {
        self.convertResult = convertResult
        self.convertError = nil
    }

    public func configure(captureResult: URL) {
        self.captureResult = captureResult
        self.captureError = nil
    }

    public func configureConvertError(_ error: Error) {
        self.convertError = error
    }

    public func configureCaptureError(_ error: Error) {
        self.captureError = error
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

    public func convert(fileURL: URL) async throws -> URL {
        convertCallCount += 1
        lastConvertURL = fileURL
        if let error = convertError { throw error }
        return convertResult ?? URL(fileURLWithPath: "/tmp/converted.wav")
    }

    public func startCapture() async throws {
        startCaptureCalled = true
        if let error = captureError { throw error }
        _isRecording = true
    }

    public func stopCapture() async throws -> URL {
        stopCaptureCalled = true
        _isRecording = false
        if let error = captureError { throw error }
        return captureResult ?? URL(fileURLWithPath: "/tmp/recording.wav")
    }
}
