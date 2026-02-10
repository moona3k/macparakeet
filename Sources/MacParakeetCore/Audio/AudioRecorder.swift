import AVFoundation
import Foundation

/// Manages microphone recording via AVAudioEngine.
/// Captures audio, converts to 16kHz mono, and writes to a temporary WAV file.
public actor AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var sampleCount: Int = 0
    private var currentAudioLevel: Float = 0.0
    private var outputURL: URL?
    private var recording = false

    /// Minimum samples before sending to STT (Parakeet Metal allocator guard)
    private static let minimumSamples = 81

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

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target: 16kHz mono Float32
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
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
                    Task { await self?.addSamples(Int(convertedBuffer.frameLength)) }
                } catch {
                    // Log but don't crash
                }
            }
        }

        try engine.start()

        self.audioEngine = engine
        self.audioFile = file
        self.outputURL = url
        self.sampleCount = 0
        self.recording = true
    }

    /// Stop recording and return the path to the recorded WAV file.
    /// Throws if the recording is too short (< 81 samples).
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

    private func addSamples(_ count: Int) {
        sampleCount += count
    }
}
