import AVFoundation
import Foundation
import os
import OSLog

/// Manages microphone recording via AVAudioEngine.
/// Captures audio, converts to 16kHz mono, and writes to a temporary WAV file.
public actor AudioRecorder {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "AudioRecorder")
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    /// Thread-safe sample counter updated synchronously from the audio tap callback.
    /// Using OSAllocatedUnfairLock because the tap runs on the real-time audio thread,
    /// and actor-hopped Tasks would race with stop() on the actor queue.
    private let sampleCounter = OSAllocatedUnfairLock(initialState: 0)
    private var currentAudioLevel: Float = 0.0
    private var outputURL: URL?
    private var recording = false

    /// Minimum samples before sending to STT.
    /// FluidAudio requires at least 1 second of 16kHz audio (16,000 samples).
    private static let minimumSamples = 16_000

    public init() {}

    public var audioLevel: Float {
        currentAudioLevel
    }

    public var isRecording: Bool {
        recording
    }

    /// Start recording from the microphone.
    public func start() throws {
        guard !recording else { return }

        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        logger.debug("mic_permission_status=\(authStatus.rawValue, privacy: .public)")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        logger.debug(
            "input_format sample_rate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public) common_format=\(inputFormat.commonFormat.rawValue, privacy: .public)"
        )

        // Target: 16kHz mono Float32
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            logger.error("failed_to_create_output_format")
            throw AudioProcessorError.recordingFailed("Failed to create output format")
        }

        // Create temp file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet", isDirectory: true)
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        }
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: outputFormat.settings)

        // Install converter + tap
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            logger.error("failed_to_create_audio_converter")
            throw AudioProcessorError.recordingFailed("Failed to create audio converter")
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            // Calculate audio level (RMS)
            let channelData = buffer.floatChannelData?[0]
            let frameCount = Int(buffer.frameLength)
            if let data = channelData, frameCount > 0 {
                var rms: Float = 0
                for i in 0..<frameCount {
                    rms += data[i] * data[i]
                }
                rms = sqrtf(rms / Float(frameCount))
                Task { await self?.updateAudioLevel(rms) }
            }

            // Convert to output format
            let outputFrameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputFrameCapacity
            ) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if status == .haveData {
                do {
                    try file.write(from: convertedBuffer)
                    self?.sampleCounter.withLock { $0 += Int(convertedBuffer.frameLength) }
                } catch {
                    // Log but don't crash
                }
            }
        }

        try engine.start()

        self.audioEngine = engine
        self.audioFile = file
        self.outputURL = url
        self.sampleCounter.withLock { $0 = 0 }
        self.recording = true
    }

    /// Stop recording and return the path to the recorded WAV file.
    /// Throws `insufficientSamples` if the recording is shorter than 1 second.
    public func stop() throws -> URL {
        guard recording else {
            throw AudioProcessorError.recordingFailed("Not recording")
        }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        recording = false
        currentAudioLevel = 0.0

        guard let url = outputURL else {
            throw AudioProcessorError.recordingFailed("No output file")
        }

        let sampleCount = sampleCounter.withLock { $0 }
        logger.debug("stop sampleCount=\(sampleCount, privacy: .public)")
        guard sampleCount >= Self.minimumSamples else {
            // Clean up the too-short file
            try? FileManager.default.removeItem(at: url)
            throw AudioProcessorError.insufficientSamples
        }

        return url
    }

    // MARK: - Private

    private func updateAudioLevel(_ level: Float) {
        // Normalize to 0-1 range with some smoothing
        let normalized = min(level * 5.0, 1.0)
        currentAudioLevel = currentAudioLevel * 0.3 + normalized * 0.7
    }

}
