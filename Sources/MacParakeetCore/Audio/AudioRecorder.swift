import AVFoundation
import CoreAudio
import Foundation
import os
import OSLog

/// Snapshot of the audio input device used for a recording. Currently always
/// `nil` in the shared-mic-stream architecture — device info now lives on the
/// platform behind the stream and is not yet plumbed through to the recorder.
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

private struct RecordingRuntimeMetrics: Sendable {
    var inputBufferCount: Int = 0
    var outputBufferCount: Int = 0
    var inputFrameCount: Int = 0
    var maxRMS: Float = 0
    var maxAudioLevel: Float = 0
    var nonSilentBufferCount: Int = 0
    var missingFloatChannelDataBufferCount: Int = 0
    var invalidFormatBufferCount: Int = 0
}

/// Records dictation audio by subscribing to the process-wide
/// `SharedMicrophoneStream` and writing converted 16 kHz mono Float32 buffers
/// to a temporary WAV file. The buffer handler always extracts channel 0 —
/// when VPIO is engaged anywhere in the process, every subscriber sees a
/// duplex layout (typically ch=9) where channel 0 is the post-AEC processed
/// mono and the rest are reference channels.
public actor AudioRecorder {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "AudioRecorder")
    private let permissionProvider: @Sendable () -> Bool
    private let sharedStream: SharedMicrophoneStream
    private var audioFile: AVAudioFile?
    private var sharedSubscriberToken: SharedMicrophoneStream.SubscriberToken?
    /// Thread-safe sample counter updated synchronously from the audio tap callback.
    /// Using OSAllocatedUnfairLock because the tap runs on the real-time audio thread,
    /// and actor-hopped Tasks would race with stop() on the actor queue.
    nonisolated private let sampleCounter = OSAllocatedUnfairLock(initialState: 0)
    /// Thread-safe flag to throttle tap error logging (avoid flooding logs from audio thread).
    nonisolated private let tapErrorLogged = OSAllocatedUnfairLock(initialState: false)
    /// Thread-safe audio level written from the real-time audio thread, read by the actor.
    /// Avoids Task allocation on the audio thread which causes priority inversion.
    nonisolated private let atomicAudioLevel = OSAllocatedUnfairLock<Float>(initialState: 0.0)
    nonisolated private let runtimeMetrics = OSAllocatedUnfairLock(
        initialState: RecordingRuntimeMetrics()
    )
    nonisolated private let firstBufferLogged = OSAllocatedUnfairLock(initialState: false)
    nonisolated private let sharedProcessingQueue = DispatchQueue(
        label: "com.macparakeet.audio-recorder.shared-processing",
        qos: .userInitiated
    )
    /// Thread-safe generation counter incremented on each stop(). Tap callbacks capture
    /// the generation at install time and bail out if it has changed. This prevents both
    /// the stop() race (writes after audioFile is nilled) and the cross-session race
    /// (stale callback from session A writing after session B has started).
    nonisolated private let sessionGeneration = OSAllocatedUnfairLock(initialState: 0)
    private var outputURL: URL?
    private var recording = false
    private var starting = false

    /// Minimum samples before sending to STT.
    /// FluidAudio requires at least 1 second of 16kHz audio (16,000 samples).
    private static let minimumSamples = 16_000

    public init(
        sharedStream: SharedMicrophoneStream,
        permissionProvider: @escaping @Sendable () -> Bool = {
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    ) {
        self.sharedStream = sharedStream
        self.permissionProvider = permissionProvider
    }

    public var audioLevel: Float {
        // Read the latest value written by the audio tap thread
        atomicAudioLevel.withLock { $0 }
    }

    public var isRecording: Bool {
        recording
    }

    /// Device info from the most recent recording. Always `nil` today —
    /// surfacing platform device info through the shared stream is tracked as
    /// follow-up work; dictation telemetry treats `nil` as "device unknown".
    public var deviceInfo: RecordingDeviceInfo? {
        nil
    }

    /// Subscribe to the shared microphone stream and start writing converted
    /// buffers to a temp WAV file. Returns once the subscription is owned and
    /// the watchdog is armed.
    public func start() async throws {
        guard !recording, !starting else { return }
        starting = true
        defer { starting = false }

        AudioCaptureDiagnostics.append(
            "dictation_capture_start permission_status=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)"
        )
        guard permissionProvider() else {
            AudioCaptureDiagnostics.append(
                "dictation_capture_start_denied"
            )
            throw AudioProcessorError.microphonePermissionDenied
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioProcessorError.recordingFailed("Failed to create output format")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet", isDirectory: true)
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        }
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: outputFormat.settings)

        // Reset per-session counters before subscribing — the buffer handler
        // can fire as soon as subscribe returns.
        self.tapErrorLogged.withLock { $0 = false }
        self.firstBufferLogged.withLock { $0 = false }
        self.runtimeMetrics.withLock { $0 = RecordingRuntimeMetrics() }
        self.sampleCounter.withLock { $0 = 0 }

        let preSubscribeGeneration = self.sessionGeneration.withLock { $0 }
        let tapGeneration = preSubscribeGeneration
        let converterCache = TapConverterCache()
        let outputFormatBox = UncheckedSendableAudioFormat(outputFormat)
        let fileBox = UncheckedSendableAudioFile(file)

        let processCopiedBuffer: @Sendable (UncheckedSendableAudioPCMBuffer, AVAudioChannelCount) -> Void = { [weak self] copiedBufferBox, originalChannelCount in
            guard let self else { return }
            guard self.sessionGeneration.withLock({ $0 }) == tapGeneration else { return }
            let buffer = copiedBufferBox.buffer

            // ch[0] mono extraction — the design rule that makes dictation
            // correct under every VPIO state. See `extractChannelZero`.
            guard let monoBuffer = extractChannelZero(from: buffer) else {
                self.runtimeMetrics.withLock { $0.invalidFormatBufferCount += 1 }
                return
            }

            let bufferFormat = monoBuffer.format
            let frameCount = Int(monoBuffer.frameLength)
            self.runtimeMetrics.withLock { metrics in
                metrics.inputBufferCount += 1
                metrics.inputFrameCount += frameCount
            }

            if let data = monoBuffer.floatChannelData?[0], frameCount > 0 {
                var rms: Float = 0
                for i in 0..<frameCount {
                    rms += data[i] * data[i]
                }
                rms = sqrtf(rms / Float(frameCount))
                let normalized = min(rms * 5.0, 1.0)
                self.atomicAudioLevel.withLock { level in
                    level = level * 0.3 + normalized * 0.7
                }
                let rmsValue = rms
                let normalizedValue = normalized
                self.runtimeMetrics.withLock { metrics in
                    metrics.maxRMS = max(metrics.maxRMS, rmsValue)
                    metrics.maxAudioLevel = max(metrics.maxAudioLevel, normalizedValue)
                    if normalizedValue >= 0.02 {
                        metrics.nonSilentBufferCount += 1
                    }
                }
            } else {
                self.runtimeMetrics.withLock {
                    $0.missingFloatChannelDataBufferCount += 1
                }
            }

            let shouldLogFirstBuffer = self.firstBufferLogged.withLock { logged in
                guard !logged else { return false }
                logged = true
                return true
            }
            if shouldLogFirstBuffer {
                let sr = bufferFormat.sampleRate
                let ch = bufferFormat.channelCount
                let commonFormat = bufferFormat.commonFormat.rawValue
                let interleaved = bufferFormat.isInterleaved
                let frameLength = monoBuffer.frameLength
                let hasFloatData = monoBuffer.floatChannelData != nil
                Task {
                    AudioCaptureDiagnostics.append(
                        "dictation_capture_first_buffer sr=\(sr) ch=\(ch) original_ch=\(originalChannelCount) common_format=\(commonFormat) interleaved=\(interleaved) frames=\(frameLength) has_float_data=\(hasFloatData)"
                    )
                }
            }

            guard bufferFormat.sampleRate > 0, bufferFormat.channelCount > 0 else {
                self.runtimeMetrics.withLock { $0.invalidFormatBufferCount += 1 }
                return
            }

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

            let outputFrameCapacity = AVAudioFrameCount(
                ceil(Double(monoBuffer.frameLength) * outputFormatBox.format.sampleRate / bufferFormat.sampleRate)
            )
            guard outputFrameCapacity > 0,
                  let convertedBuffer = AVAudioPCMBuffer(
                      pcmFormat: outputFormatBox.format,
                      frameCapacity: outputFrameCapacity
                  )
            else { return }

            let inputBuffer = UncheckedSendableAudioPCMBuffer(monoBuffer)
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
                guard self.sessionGeneration.withLock({ $0 }) == tapGeneration else { return }
                do {
                    let convertedFrameLength = Int(convertedBuffer.frameLength)
                    try fileBox.file.write(from: convertedBuffer)
                    self.sampleCounter.withLock { $0 += convertedFrameLength }
                    self.runtimeMetrics.withLock { $0.outputBufferCount += 1 }
                } catch {
                    let alreadyLogged = self.tapErrorLogged.withLock { logged in
                        let was = logged; logged = true; return was
                    }
                    if !alreadyLogged {
                        let desc = error.localizedDescription
                        Task { await self.logTapError("audio_write_error: \(desc)") }
                    }
                }
            case .error:
                let alreadyLogged = self.tapErrorLogged.withLock { logged in
                    let was = logged; logged = true; return was
                }
                if !alreadyLogged {
                    let desc = error?.localizedDescription ?? "unknown"
                    Task { await self.logTapError("converter_error: \(desc)") }
                }
            case .endOfStream, .inputRanDry:
                break
            @unknown default:
                break
            }
        }
        let bufferHandler: SharedMicrophoneStream.BufferHandler = { [weak self] buffer, _ in
            guard let self else { return }
            guard self.sessionGeneration.withLock({ $0 }) == tapGeneration else { return }
            let originalChannelCount = buffer.format.channelCount
            guard let copiedBuffer = copyPCMBufferForAsyncUse(buffer) else {
                self.runtimeMetrics.withLock { $0.invalidFormatBufferCount += 1 }
                return
            }
            let copiedBufferBox = UncheckedSendableAudioPCMBuffer(copiedBuffer)
            self.sharedProcessingQueue.async {
                processCopiedBuffer(copiedBufferBox, originalChannelCount)
            }
        }

        let deathHandler: SharedMicrophoneStream.EngineDeathHandler = { [weak self] in
            // Engine death = recording is dead. Bump the generation so any
            // in-flight buffer handlers bail. The next caller of `stop()`
            // will surface `insufficientSamples` if no audio was captured.
            self?.sessionGeneration.withLock { $0 += 1 }
        }

        AudioCaptureDiagnostics.append(
            "dictation_capture_starting"
        )

        let token: SharedMicrophoneStream.SubscriberToken
        do {
            token = try await sharedStream.subscribe(
                wantsVPIO: false,
                onEngineDeath: deathHandler,
                handler: bufferHandler
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            AudioCaptureDiagnostics.append(
                "dictation_capture_start_failed reason=\"\(error.localizedDescription)\""
            )
            throw AudioProcessorError.recordingFailed(error.localizedDescription)
        }

        // Actor-reentrancy guard. While we awaited subscribe, another
        // method (typically `stop()`) may have run on this actor — `stop()`
        // bumps the generation, so a generation mismatch means we're an
        // orphan. Unsubscribe and clean up rather than claim a recording
        // session that nobody asked for.
        let postSubscribeGeneration = self.sessionGeneration.withLock { $0 }
        let lostRace = preSubscribeGeneration != postSubscribeGeneration || !self.starting || self.recording
        if lostRace {
            let stream = sharedStream
            Task { await stream.unsubscribe(token) }
            try? FileManager.default.removeItem(at: url)
            AudioCaptureDiagnostics.append(
                "dictation_capture_start_aborted reason=\"interrupted_during_subscribe\""
            )
            throw AudioProcessorError.recordingFailed("interrupted during subscribe")
        }

        self.audioFile = file
        self.outputURL = url
        self.recording = true
        self.sharedSubscriberToken = token

        AudioCaptureDiagnostics.append(
            "dictation_capture_engine_started file=\(url.lastPathComponent)"
        )
        logger.info(
            "dictation_capture_started file=\(url.lastPathComponent, privacy: .public)"
        )
    }

    /// Stop recording and return the path to the recorded WAV file.
    /// Throws `insufficientSamples` if the recording is shorter than 1 second.
    public func stop() throws -> URL {
        if starting, !recording {
            // `start()` awaits the stream subscription. A stop/cancel during
            // that await must invalidate the pending tap generation so the
            // in-flight start cannot claim a recording after cancellation.
            sessionGeneration.withLock { $0 += 1 }
            starting = false
            throw AudioProcessorError.recordingFailed("Not recording")
        }
        guard recording else {
            throw AudioProcessorError.recordingFailed("Not recording")
        }

        if let token = sharedSubscriberToken {
            // Fire-and-forget so stop() stays synchronous. The stream's
            // engine queue serializes the unsubscribe behind any pending
            // operations.
            let stream = sharedStream
            Task { await stream.unsubscribe(token) }
            sharedSubscriberToken = nil
            // Conversion and file writes run on this serial queue instead of
            // the shared audio tap. Drain already-enqueued work so stop()
            // reports a sample count that includes buffers accepted before
            // the user stopped recording.
            sharedProcessingQueue.sync {}
            sessionGeneration.withLock { $0 += 1 }
        }
        audioFile = nil
        recording = false
        atomicAudioLevel.withLock { $0 = 0.0 }

        let url = outputURL
        outputURL = nil

        guard let url else {
            throw AudioProcessorError.recordingFailed("No output file")
        }

        let sampleCount = sampleCounter.withLock { $0 }
        let metrics = runtimeMetrics.withLock { $0 }
        let fileBytes = Self.fileSizeBytes(at: url)
        let duration = Double(sampleCount) / 16_000.0
        logger.debug("stop sampleCount=\(sampleCount, privacy: .public)")
        AudioCaptureDiagnostics.append(
            "dictation_capture_stop sample_count=\(sampleCount) duration_s=\(String(format: "%.3f", duration)) file_bytes=\(fileBytes.map(String.init) ?? "unknown") input_buffers=\(metrics.inputBufferCount) output_buffers=\(metrics.outputBufferCount) input_frames=\(metrics.inputFrameCount) max_rms=\(String(format: "%.6f", metrics.maxRMS)) max_level=\(String(format: "%.3f", metrics.maxAudioLevel)) non_silent_buffers=\(metrics.nonSilentBufferCount) missing_float_buffers=\(metrics.missingFloatChannelDataBufferCount) invalid_format_buffers=\(metrics.invalidFormatBufferCount)"
        )
        guard sampleCount >= Self.minimumSamples else {
            // Clean up the too-short file
            try? FileManager.default.removeItem(at: url)
            AudioCaptureDiagnostics.append(
                "dictation_capture_insufficient sample_count=\(sampleCount) required=\(Self.minimumSamples)"
            )
            throw AudioProcessorError.insufficientSamples
        }

        return url
    }

    private func logTapError(_ message: String) {
        logger.warning("audio_tap \(message, privacy: .public)")
        AudioCaptureDiagnostics.append("dictation_capture_tap_error \(message)")
    }

    private static func fileSizeBytes(at url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64 else {
            return nil
        }
        return size
    }
}

@inline(__always)
func tapConverterNeedsRebuild(
    cachedSourceFormat: AVAudioFormat?,
    incomingBufferFormat: AVAudioFormat
) -> Bool {
    cachedSourceFormat?.isEqual(incomingBufferFormat) != true
}

/// Extracts channel 0 from a multi-channel buffer as a mono buffer.
///
/// When `SharedMicrophoneStream` engages VPIO anywhere in the process, the
/// mic input format becomes a multi-channel duplex layout (typically ch=9)
/// where channel 0 is the post-AEC processed mono and the rest are
/// reference / diagnostic channels. The dictation subscriber must read
/// channel 0 only — `AVAudioConverter`'s default channel-reduction would
/// average across channels and dilute the AEC.
///
/// - Mono input (`ch=1`) is returned unchanged.
/// - Multi-channel **non-interleaved** input is copied into a fresh ch=1
///   buffer with the same sample rate and common format. Float32 / Int16 /
///   Int32 are supported (matching what AVFAudio routinely produces on
///   macOS).
/// - Multi-channel **interleaved** input is rare in our stack (VPIO and
///   most macOS device formats are non-interleaved). We pass it through
///   unchanged and let the converter mix channels — wrong for VPIO but a
///   safe degradation for arbitrary multi-mic devices.
///
/// Returns `nil` only on allocation failure or unsupported sample format.
func extractChannelZero(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let inputFormat = buffer.format
    if inputFormat.channelCount == 1 {
        return buffer
    }
    if inputFormat.isInterleaved {
        return buffer
    }
    guard let monoFormat = AVAudioFormat(
        commonFormat: inputFormat.commonFormat,
        sampleRate: inputFormat.sampleRate,
        channels: 1,
        interleaved: false
    ) else {
        return nil
    }
    guard let extracted = AVAudioPCMBuffer(
        pcmFormat: monoFormat,
        frameCapacity: buffer.frameCapacity
    ) else {
        return nil
    }
    extracted.frameLength = buffer.frameLength
    let frameCount = Int(buffer.frameLength)

    if let src = buffer.floatChannelData, let dst = extracted.floatChannelData {
        dst[0].update(from: src[0], count: frameCount)
        return extracted
    }
    if let src = buffer.int16ChannelData, let dst = extracted.int16ChannelData {
        dst[0].update(from: src[0], count: frameCount)
        return extracted
    }
    if let src = buffer.int32ChannelData, let dst = extracted.int32ChannelData {
        dst[0].update(from: src[0], count: frameCount)
        return extracted
    }
    return nil
}

/// Copies a tap buffer so heavier processing can happen off the audio render
/// thread while respecting `SharedMicrophoneStream`'s synchronous buffer
/// lifetime contract.
func copyPCMBufferForAsyncUse(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(
        pcmFormat: buffer.format,
        frameCapacity: max(buffer.frameLength, 1)
    ) else {
        return nil
    }
    copy.frameLength = buffer.frameLength

    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return copy }

    if buffer.format.isInterleaved {
        let source = buffer.audioBufferList.pointee.mBuffers
        let destination = copy.mutableAudioBufferList.pointee.mBuffers
        let byteCount = min(Int(source.mDataByteSize), Int(destination.mDataByteSize))
        guard byteCount > 0 else { return copy }
        guard let sourceData = source.mData,
              let destinationData = destination.mData else {
            return nil
        }
        destinationData.copyMemory(from: sourceData, byteCount: byteCount)
        return copy
    }

    let channelCount = Int(buffer.format.channelCount)
    if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
        for channel in 0..<channelCount {
            destination[channel].update(from: source[channel], count: frameCount)
        }
        return copy
    }
    if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
        for channel in 0..<channelCount {
            destination[channel].update(from: source[channel], count: frameCount)
        }
        return copy
    }
    if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
        for channel in 0..<channelCount {
            destination[channel].update(from: source[channel], count: frameCount)
        }
        return copy
    }

    return nil
}

/// Mutable cache for the tap block's `AVAudioConverter`. Tap callbacks are
/// serialized per bus by AVAudioEngine, so no locking is required. Marked
/// `@unchecked Sendable` to satisfy Swift 6 strict concurrency checks on the
/// escaping tap closure capture.
private final class TapConverterCache: @unchecked Sendable {
    var converter: AVAudioConverter?
    var sourceFormat: AVAudioFormat?
}
