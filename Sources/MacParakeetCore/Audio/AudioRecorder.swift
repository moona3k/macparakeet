import AVFoundation
import CoreAudio
import Foundation
import os
import OSLog

/// Snapshot of the audio input device used for a recording.
public struct RecordingDeviceInfo: Sendable, Equatable {
    public let deviceName: String
    public let transport: String
    /// For aggregate devices, the transport of the underlying sub-device (e.g., "bluetooth", "built-in").
    public let subTransport: String?
    public let sampleRate: Double
    public let channels: UInt32
    public let fallbackUsed: Bool
}

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
    /// Thread-safe audio level written from the real-time audio thread, read by the actor.
    /// Avoids Task allocation on the audio thread which causes priority inversion.
    nonisolated private let atomicAudioLevel = OSAllocatedUnfairLock<Float>(initialState: 0.0)
    /// Thread-safe generation counter incremented on each stop(). Tap callbacks capture
    /// the generation at install time and bail out if it has changed. This prevents both
    /// the stop() race (writes after audioFile is nilled) and the cross-session race
    /// (stale callback from session A writing after session B has started).
    nonisolated private let sessionGeneration = OSAllocatedUnfairLock(initialState: 0)
    private var outputURL: URL?
    private var recording = false
    private var _deviceInfo: RecordingDeviceInfo?

    /// Minimum samples before sending to STT.
    /// FluidAudio requires at least 1 second of 16kHz audio (16,000 samples).
    private static let minimumSamples = 16_000

    public init() {}

    public var audioLevel: Float {
        // Read the latest value written by the audio tap thread
        atomicAudioLevel.withLock { $0 }
    }

    public var isRecording: Bool {
        recording
    }

    /// Device info from the most recent recording (including fallback status).
    public var deviceInfo: RecordingDeviceInfo? {
        _deviceInfo
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

        // Bump generation so any in-flight tap callbacks from this session bail out.
        // This prevents both the stop() race and the cross-session race.
        sessionGeneration.withLock { $0 += 1 }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        recording = false
        atomicAudioLevel.withLock { $0 = 0.0 }

        let url = outputURL
        outputURL = nil

        guard let url else {
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

        // Capture device info for telemetry (before validation — we want info even on failure)
        if let resolvedID = AudioDeviceManager.currentInputDevice(of: engine) {
            let name = AudioDeviceManager.deviceName(resolvedID) ?? "unknown"
            let transport = AudioDeviceManager.transportType(resolvedID)
            let subTransport = AudioDeviceManager.subDeviceTransport(resolvedID)
            _deviceInfo = RecordingDeviceInfo(
                deviceName: name,
                transport: AudioDeviceManager.InputDevice.label(for: transport),
                subTransport: subTransport.map { AudioDeviceManager.InputDevice.label(for: $0) },
                sampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount,
                fallbackUsed: overrideDeviceID != nil
            )
        }

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

        // Capture the current generation so stale callbacks from previous sessions bail out.
        let tapGeneration = self.sessionGeneration.withLock { $0 }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }

            // Bail if stop() was called (generation bumped) or a new session started
            let currentGen = self.sessionGeneration.withLock { $0 }
            guard currentGen == tapGeneration else { return }

            // Calculate audio level (RMS) — written atomically, no Task allocation needed
            let channelData = buffer.floatChannelData?[0]
            let frameCount = Int(buffer.frameLength)
            if let data = channelData, frameCount > 0 {
                var rms: Float = 0
                for i in 0..<frameCount {
                    rms += data[i] * data[i]
                }
                rms = sqrtf(rms / Float(frameCount))
                let normalized = min(rms * 5.0, 1.0)
                self.atomicAudioLevel.withLock { level in
                    level = level * 0.3 + normalized * 0.7
                }
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
                // Re-check generation before writing — stop() may have been called
                // between the guard at the top and here.
                guard self.sessionGeneration.withLock({ $0 }) == tapGeneration else { return }
                do {
                    try file.write(from: convertedBuffer)
                    self.sampleCounter.withLock { $0 += Int(convertedBuffer.frameLength) }
                } catch {
                    // Log but don't crash — we're on the audio thread.
                    // Throttled: only first error per session is logged.
                    let alreadyLogged = self.tapErrorLogged.withLock { logged in
                        let was = logged; logged = true; return was
                    }
                    if !alreadyLogged {
                        let desc = error.localizedDescription
                        Task { await self.logTapError("audio_write_error: \(desc)") }
                    }
                }
            case .error:
                // Log converter errors (throttled — only first occurrence per recording)
                let alreadyLogged = self.tapErrorLogged.withLock { logged in
                    let was = logged
                    logged = true
                    return was
                }
                if !alreadyLogged {
                    let desc = error?.localizedDescription ?? "unknown"
                    Task {
                        await self.logTapError(
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

    private func logTapError(_ message: String) {
        logger.warning("audio_tap \(message, privacy: .public)")
    }
}
