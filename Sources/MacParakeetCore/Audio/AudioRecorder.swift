import AVFoundation
import CoreAudio
import Foundation
import os
import OSLog

/// Manages microphone recording via AVAudioEngine.
/// Captures audio, converts to 16kHz mono, and writes to a temporary WAV file.
///
/// When the system default input device has an invalid format (e.g., Bluetooth headphones
/// in HFP mode reporting 0 Hz sample rate), automatically falls back to the built-in microphone.
public actor AudioRecorder {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "AudioRecorder")
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    /// Thread-safe sample counter updated synchronously from the audio tap callback.
    /// Using OSAllocatedUnfairLock because the tap runs on the real-time audio thread,
    /// and actor-hopped Tasks would race with stop() on the actor queue.
    nonisolated private let sampleCounter = OSAllocatedUnfairLock(initialState: 0)
    /// Thread-safe flag to throttle tap error logging (avoid flooding logs from audio thread).
    nonisolated private let tapErrorLogged = OSAllocatedUnfairLock(initialState: false)
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
    ///
    /// Attempts the system default input device first. If the device reports an invalid
    /// audio format (sampleRate ≤ 0 or channelCount ≤ 0) or the engine fails to start,
    /// retries with the built-in microphone.
    public func start() throws {
        guard !recording else { return }

        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        logger.debug("mic_permission_status=\(authStatus.rawValue, privacy: .public)")

        logAvailableDevices()

        // Try with the system default device first
        do {
            try configureAndStart(overrideDeviceID: nil)
        } catch {
            logger.warning(
                "default_device_failed error=\(error.localizedDescription, privacy: .public) — retrying with built-in mic"
            )

            guard let builtInID = AudioDeviceManager.builtInMicrophone() else {
                logger.error("no_built_in_mic_available — propagating original error")
                throw error
            }

            let name = AudioDeviceManager.deviceName(builtInID) ?? "unknown"
            logger.info(
                "retrying_with_built_in_mic id=\(builtInID, privacy: .public) name=\(name, privacy: .public)"
            )
            try configureAndStart(overrideDeviceID: builtInID)
        }
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

    /// Configures the audio engine and starts recording.
    ///
    /// If `overrideDeviceID` is provided, explicitly sets that device on the engine's
    /// input audio unit before reading the format. Otherwise uses the system default.
    private func configureAndStart(overrideDeviceID: AudioDeviceID?) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Optionally override the input device
        if let deviceID = overrideDeviceID {
            if !AudioDeviceManager.setInputDevice(deviceID, on: engine) {
                throw AudioProcessorError.recordingFailed(
                    "Failed to set input device \(deviceID)"
                )
            }
        }

        // Log the resolved device
        if let resolvedID = AudioDeviceManager.currentInputDevice(of: engine) {
            let name = AudioDeviceManager.deviceName(resolvedID) ?? "unknown"
            let transport = AudioDeviceManager.transportType(resolvedID)
            let transportLabel = AudioDeviceManager.InputDevice.label(for: transport)
            logger.info(
                "input_device id=\(resolvedID, privacy: .public) name=\(name, privacy: .public) transport=\(transportLabel, privacy: .public)"
            )
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        logger.info(
            "input_format sr=\(inputFormat.sampleRate, privacy: .public) ch=\(inputFormat.channelCount, privacy: .public) common_format=\(inputFormat.commonFormat.rawValue, privacy: .public)"
        )

        // Validate format — Bluetooth HFP can report 0 Hz or 0 channels
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioProcessorError.recordingFailed(
                "Invalid input format: sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)"
            )
        }

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
            try? FileManager.default.removeItem(at: url)
            logger.error(
                "failed_to_create_audio_converter from sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount) to 16kHz 1ch"
            )
            throw AudioProcessorError.recordingFailed(
                "Failed to create audio converter (input: \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch)"
            )
        }

        self.tapErrorLogged.withLock { $0 = false }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
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
                ceil(Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate)
            )
            guard outputFrameCapacity > 0,
                let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: outputFrameCapacity
                )
            else { return }

            // One-shot input block: provide the buffer exactly once per convert() call.
            // The converter may call the input block multiple times if it needs more data;
            // returning the same buffer repeatedly would duplicate samples.
            var inputConsumed = false
            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            switch status {
            case .haveData:
                do {
                    try file.write(from: convertedBuffer)
                    self?.sampleCounter.withLock { $0 += Int(convertedBuffer.frameLength) }
                } catch {
                    // Log but don't crash — we're on the audio thread
                }
            case .error:
                // Log converter errors (throttled — only first occurrence per recording)
                let alreadyLogged = self?.tapErrorLogged.withLock { logged in
                    let was = logged
                    logged = true
                    return was
                } ?? true
                if !alreadyLogged {
                    let desc = error?.localizedDescription ?? "unknown"
                    Task {
                        await self?.logTapError(
                            "converter_error: \(desc)"
                        )
                    }
                }
            case .endOfStream:
                break
            case .inputRanDry:
                break
            @unknown default:
                break
            }
        }

        // Reset counter before engine.start() — the tap can fire immediately after start.
        self.sampleCounter.withLock { $0 = 0 }

        do {
            try engine.start()
        } catch {
            // Clean up before propagating
            inputNode.removeTap(onBus: 0)
            try? FileManager.default.removeItem(at: url)
            throw AudioProcessorError.recordingFailed(
                "Audio engine failed to start: \(error.localizedDescription)"
            )
        }

        self.audioEngine = engine
        self.audioFile = file
        self.outputURL = url
        self.recording = true
    }

    /// Logs all available input devices (called once at start for diagnostics).
    private func logAvailableDevices() {
        let devices = AudioDeviceManager.inputDevices()
        let defaultID = AudioDeviceManager.defaultInputDevice()
        logger.info("available_input_devices count=\(devices.count, privacy: .public)")
        for device in devices {
            let isDefault = device.id == defaultID ? " [DEFAULT]" : ""
            logger.info(
                "  device id=\(device.id, privacy: .public) name=\(device.name, privacy: .public) transport=\(device.transportLabel, privacy: .public)\(isDefault, privacy: .public)"
            )
        }
    }

    private func updateAudioLevel(_ level: Float) {
        // Normalize to 0-1 range with some smoothing
        let normalized = min(level * 5.0, 1.0)
        currentAudioLevel = currentAudioLevel * 0.3 + normalized * 0.7
    }

    private func logTapError(_ message: String) {
        logger.warning("audio_tap \(message, privacy: .public)")
    }
}
