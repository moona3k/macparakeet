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
    public let deviceUID: String?
    public let requestedDeviceUID: String?
}

/// Manages microphone recording via AVAudioEngine.
/// Captures audio, converts to 16kHz mono, and writes to a temporary WAV file.
///
/// When the system default input device has an invalid format (e.g., Bluetooth headphones
/// in HFP mode reporting 0 Hz sample rate), automatically falls back to the built-in microphone.
public actor AudioRecorder {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "AudioRecorder")
    private let selectedInputDeviceUIDProvider: @Sendable () -> String?
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

    public init(
        selectedInputDeviceUIDProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.selectedInputDeviceUIDProvider = selectedInputDeviceUIDProvider
    }

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

        // Hard-gate on microphone permission. Today AVFAudio will still attempt
        // to start without authorization and fail deep in the audio stack with
        // an opaque NSException. The UI layer requests mic access during
        // onboarding, so anything other than `.authorized` here means either a
        // first-run race or the user revoked access in System Settings.
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        logger.debug("mic_permission_status=\(authStatus.rawValue, privacy: .public)")
        guard authStatus == .authorized else {
            logger.error(
                "mic_permission_not_granted status=\(authStatus.rawValue, privacy: .public)"
            )
            throw AudioProcessorError.microphonePermissionDenied
        }

        logAvailableDevices()

        let selectedDeviceUID = AudioDeviceManager.normalizedUID(selectedInputDeviceUIDProvider())
        if let selectedDeviceUID {
            if let selectedDeviceID = AudioDeviceManager.inputDeviceID(forUID: selectedDeviceUID) {
                do {
                    try configureAndStart(
                        overrideDeviceID: selectedDeviceID,
                        fallbackUsed: false,
                        requestedDeviceUID: selectedDeviceUID
                    )
                    return
                } catch {
                    logger.warning(
                        "selected_input_device_failed uid=\(selectedDeviceUID, privacy: .private) error=\(error.localizedDescription, privacy: .public) — retrying with system default"
                    )
                }
            } else {
                logger.warning(
                    "selected_input_device_missing uid=\(selectedDeviceUID, privacy: .private) — retrying with system default"
                )
            }
        }

        // Try with the system default device next.
        do {
            try configureAndStart(
                overrideDeviceID: nil,
                fallbackUsed: selectedDeviceUID != nil,
                requestedDeviceUID: selectedDeviceUID
            )
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
            try configureAndStart(
                overrideDeviceID: builtInID,
                fallbackUsed: true,
                requestedDeviceUID: selectedDeviceUID
            )
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
    private func configureAndStart(
        overrideDeviceID: AudioDeviceID?,
        fallbackUsed: Bool,
        requestedDeviceUID: String?
    ) throws {
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
            let uid = AudioDeviceManager.deviceUID(resolvedID) ?? "unknown"
            let transport = AudioDeviceManager.transportType(resolvedID)
            let transportLabel = AudioDeviceManager.InputDevice.label(for: transport)
            logger.info(
                "input_device id=\(resolvedID, privacy: .public) uid=\(uid, privacy: .private) name=\(name, privacy: .public) transport=\(transportLabel, privacy: .public) requested_uid=\(requestedDeviceUID ?? "system-default", privacy: .private)"
            )
        }

        // AVFAudio raises an Objective-C NSException on aggregate / virtual
        // audio devices in bad states (issue #91). Swift can't catch it without
        // the ObjC trampoline — without the wrap this line will abort the
        // process on cluster-A/C crash paths.
        let inputFormat = try catchingObjCException {
            inputNode.outputFormat(forBus: 0)
        }
        logger.info(
            "input_format sr=\(inputFormat.sampleRate, privacy: .public) ch=\(inputFormat.channelCount, privacy: .public) common_format=\(inputFormat.commonFormat.rawValue, privacy: .public)"
        )

        // Capture device info for telemetry (before validation — we want info even on failure)
        if let resolvedID = AudioDeviceManager.currentInputDevice(of: engine) {
            let name = AudioDeviceManager.deviceName(resolvedID) ?? "unknown"
            let uid = AudioDeviceManager.deviceUID(resolvedID)
            let transport = AudioDeviceManager.transportType(resolvedID)
            let subTransport = AudioDeviceManager.subDeviceTransport(resolvedID)
            _deviceInfo = RecordingDeviceInfo(
                deviceName: name,
                transport: AudioDeviceManager.InputDevice.label(for: transport),
                subTransport: subTransport.map { AudioDeviceManager.InputDevice.label(for: $0) },
                sampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount,
                fallbackUsed: fallbackUsed,
                deviceUID: uid,
                requestedDeviceUID: requestedDeviceUID
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

        // Pre-validate that the format we just read is convertible to our
        // target. If this fails we want to bail fast before touching the tap.
        guard let initialConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
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

        // Converter cache for the tap block. We pass `format: nil` to
        // installTap so AVFAudio delivers buffers in whatever format the bus
        // is currently producing (avoiding the aggregate-device format-drift
        // NSException that caused issue #91). Seed the cache with the
        // converter we just created so the common case (bus format unchanged
        // between `outputFormat(forBus:)` and the first tap callback) avoids
        // a redundant `AVAudioConverter` allocation on the real-time audio
        // thread. If the bus format drifts mid-stream the cache rebuilds it.
        // Tap callbacks are serialized per bus so a plain reference-type
        // cache is safe; `@unchecked Sendable` satisfies Swift 6 concurrency
        // checks.
        let converterCache = TapConverterCache()
        converterCache.converter = initialConverter
        converterCache.sourceFormat = inputFormat

        // AVFAudio can raise NSException from installTap itself on aggregate
        // devices (e.g. "required condition is false:
        // IsFormatSampleRateAndChannelCountValid(hwFormat)"). Wrap the install
        // call so the caller sees a Swift error rather than a hard abort.
        do {
            nonisolated(unsafe) let unsafeInputNode = inputNode
            let outputFormatBox = UncheckedSendableAudioFormat(outputFormat)
            let fileBox = UncheckedSendableAudioFile(file)
            try catchingObjCException {
                unsafeInputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) {
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

                    // Lazily build the converter from the *actual* buffer format.
                    // With `format: nil` on installTap, AVFAudio delivers whatever
                    // the bus is currently producing — which may differ from the
                    // format we snapshotted before installTap. Re-check on each
                    // buffer and rebuild the converter if the format drifts
                    // mid-stream (rare, but cheap to handle).
                    let bufferFormat = buffer.format
                    // Aggregate/virtual devices can occasionally deliver a
                    // buffer whose format has sampleRate=0 or channelCount=0
                    // during a hardware transition (Bluetooth HFP↔A2DP, USB
                    // hot-plug, wake-from-sleep). Dividing by sampleRate below
                    // would crash. Bail out quietly — the next buffer is
                    // usually well-formed.
                    guard bufferFormat.sampleRate > 0, bufferFormat.channelCount > 0 else { return }
                    // Rebuild when the *full* AVAudioFormat identity changes
                    // (including interleaving/layout), not just SR/ch/common.
                    // Aggregate-device transitions can keep SR/ch/common stable
                    // while flipping other format details.
                    if tapConverterNeedsRebuild(
                        cachedSourceFormat: converterCache.sourceFormat,
                        incomingBufferFormat: bufferFormat
                    ) {
                        converterCache.converter = AVAudioConverter(from: bufferFormat, to: outputFormatBox.format)
                        converterCache.sourceFormat = bufferFormat
                    }
                    guard let converter = converterCache.converter else {
                        let alreadyLogged = self.tapErrorLogged.withLock { logged in
                            let was = logged; logged = true; return was
                        }
                        if !alreadyLogged {
                            let sr = bufferFormat.sampleRate
                            let ch = bufferFormat.channelCount
                            Task { await self.logTapError("converter_init_failed sr=\(sr) ch=\(ch)") }
                        }
                        return
                    }

                    // Convert to output format
                    let outputFrameCapacity = AVAudioFrameCount(
                        ceil(Double(buffer.frameLength) * outputFormatBox.format.sampleRate / bufferFormat.sampleRate)
                    )
                    guard outputFrameCapacity > 0,
                        let convertedBuffer = AVAudioPCMBuffer(
                            pcmFormat: outputFormatBox.format,
                            frameCapacity: outputFrameCapacity
                        )
                    else { return }

                    // One-shot input block: provide the buffer exactly once per convert() call.
                    // The converter may call the input block multiple times if it needs more data;
                    // returning the same buffer repeatedly would duplicate samples.
                    let inputBuffer = UncheckedSendableAudioPCMBuffer(buffer)
                    let inputConsumed = OSAllocatedUnfairLock(initialState: false)
                    var error: NSError?
                    let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                        let shouldProvideInput = inputConsumed.withLock { consumed -> Bool in
                            guard !consumed else { return false }
                            consumed = true
                            return true
                        }
                        if !shouldProvideInput {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        outStatus.pointee = .haveData
                        return inputBuffer.buffer
                    }

                    switch status {
                    case .haveData:
                        // Re-check generation before writing — stop() may have been called
                        // between the guard at the top and here.
                        guard self.sessionGeneration.withLock({ $0 }) == tapGeneration else { return }
                        do {
                            let convertedFrameLength = Int(convertedBuffer.frameLength)
                            try fileBox.file.write(from: convertedBuffer)
                            self.sampleCounter.withLock { $0 += convertedFrameLength }
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
            }
        } catch {
            // installTap raised an NSException (issue #91) — cluster A/C crash
            // path. Clean up and convert to a Swift error so the built-in-mic
            // fallback in start() gets a chance, and so DictationService's
            // catch emits a dictation_failed telemetry event with the real
            // NSException reason in `error_detail`.
            try? FileManager.default.removeItem(at: url)
            logger.error(
                "install_tap_raised error=\(error.localizedDescription, privacy: .public)"
            )
            throw AudioProcessorError.recordingFailed(
                "Audio tap install failed: \(error.localizedDescription)"
            )
        }

        // Reset counter before engine.start() — the tap can fire immediately after start.
        self.sampleCounter.withLock { $0 = 0 }

        // engine.start() is documented to throw Swift errors, but has been
        // observed to raise NSException in corner cases (stale CoreAudio state,
        // aggregate device teardown mid-start). Belt-and-braces wrap.
        do {
            nonisolated(unsafe) let unsafeEngine = engine
            try catchingObjCException {
                try unsafeEngine.start()
            }
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
                "  device id=\(device.id, privacy: .public) uid=\(device.uid, privacy: .private) name=\(device.name, privacy: .public) transport=\(device.transportLabel, privacy: .public)\(isDefault, privacy: .public)"
            )
        }
    }

    private func logTapError(_ message: String) {
        logger.warning("audio_tap \(message, privacy: .public)")
    }
}

@inline(__always)
func tapConverterNeedsRebuild(
    cachedSourceFormat: AVAudioFormat?,
    incomingBufferFormat: AVAudioFormat
) -> Bool {
    cachedSourceFormat?.isEqual(incomingBufferFormat) != true
}

/// Mutable cache for the tap block's `AVAudioConverter`. Tap callbacks are
/// serialized per bus by AVAudioEngine, so no locking is required. Marked
/// `@unchecked Sendable` to satisfy Swift 6 strict concurrency checks on the
/// escaping tap closure capture.
private final class TapConverterCache: @unchecked Sendable {
    var converter: AVAudioConverter?
    var sourceFormat: AVAudioFormat?
}
