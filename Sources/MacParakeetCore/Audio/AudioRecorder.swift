import AVFoundation
import CoreAudio
import FluidAudio
import Foundation
import os
import OSLog

/// Snapshot of the audio input device used for a recording. Currently always
/// `nil` for shared-stream recordings — `AVAudioEngineMicrophonePlatform`
/// exposes the active attempt as `lastSucceededAttempt`, but the stream does
/// not surface it through to subscribers yet. Wiring it into dictation
/// telemetry is deferred work, not blocked work.
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
    var noBufferTimeoutFired: Bool = false
}

/// Holds the per-recording diagnostic generation. The first-buffer timeout
/// fires once if no buffer has been delivered within
/// `firstBufferTimeoutSeconds` after `dictation_capture_engine_started`; the
/// heartbeat repeats every `heartbeatIntervalSeconds` while the recording is
/// active. The timeout records no-buffer state for capture health, and both
/// closures are generation-guarded so stale delayed closures bail out after
/// `stop()` or the next recording starts. See
/// `journal/2026-05-03-dictation-silent-stall.md`.
private struct CaptureDiagnosticsTimers {
    /// Generation that delivered its first buffer. This may be set before
    /// timers are armed because AVAudioEngine can deliver a tap buffer before
    /// `SharedMicrophoneStream.subscribe` returns to `start()`.
    var firstBufferSeenGeneration: Int?
    /// Session generation captured when the timers were armed. The fired
    /// closures bail out if the current generation has moved past this,
    /// which catches the race where `stop()` cancels in flight.
    var armedGeneration: Int = -1
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
    /// Diagnostic timers (first-buffer timeout + recording heartbeat). See
    /// `CaptureDiagnosticsTimers` for the field contract. Lives off-actor
    /// because the timer event handlers run on `diagnosticsQueue`.
    nonisolated private let captureDiagnosticsTimers = OSAllocatedUnfairLock(
        initialState: CaptureDiagnosticsTimers()
    )
    nonisolated private let diagnosticsQueue = DispatchQueue(
        label: "com.macparakeet.audio-recorder.diagnostics",
        qos: .utility
    )
    private var outputURL: URL?
    private var recording = false
    private var starting = false
    private var recordingStartedAt: TimeInterval?
    private var _lastCaptureHealth: AudioCaptureHealth?
    /// Bumped on every `start()` entry that passes the entry guard. Each call
    /// captures its value as `myStartCallGeneration`; the `defer` only clears
    /// `starting` if no newer call has claimed the slot. Without this, an
    /// aborted sibling's defer would clobber a legitimate replacement start
    /// AND mislead `stop()` into taking its no-op path (which doesn't bump
    /// `sessionGeneration`), letting the replacement claim a recording the
    /// caller of `stop()` just asked to end.
    private var startCallGeneration: Int = 0

    private static let outputSampleRate = ASRConstants.sampleRate

    /// Minimum samples before sending to STT. Mirrors FluidAudio's ASR guard,
    /// currently 0.3 seconds at 16 kHz.
    private static let minimumSamples = ASRConstants.minimumRequiredSamples(
        forSampleRate: outputSampleRate
    )

    /// Time after `engine_started` to wait for the first buffer before
    /// emitting `dictation_capture_no_buffers_within_timeout`. Mirrors the
    /// 2 s value used by `MicrophoneCapture.scheduleSilentBufferWatchdog`.
    private static let firstBufferTimeoutSeconds: TimeInterval = 2.0
    private static let maxStartAttempts = 2
    /// Cadence for the recording heartbeat log. Long enough that short
    /// dictations (< 5 s) don't add log noise; short enough that a stalled
    /// 18 s recording produces ~3 heartbeats showing `input_buffers=0`.
    private static let heartbeatIntervalSeconds: TimeInterval = 5.0

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
    /// `AVAudioEngineMicrophonePlatform.lastSucceededAttempt` already tracks
    /// the resolved device; surfacing it through the shared stream into
    /// dictation telemetry is a small wiring task, deferred. Dictation
    /// telemetry treats `nil` as "device unknown".
    public var deviceInfo: RecordingDeviceInfo? {
        nil
    }

    public var lastCaptureHealth: AudioCaptureHealth? {
        _lastCaptureHealth
    }

    /// Subscribe to the shared microphone stream and start writing converted
    /// buffers to a temp WAV file. Returns only after the stream delivers a
    /// first usable buffer; otherwise retries/fails before the caller treats
    /// recording as healthy.
    public func start() async throws {
        guard !recording, !starting else { return }
        starting = true
        startCallGeneration += 1
        let myStartCallGeneration = startCallGeneration
        defer {
            // Only clear `starting` if this call still owns the slot. If
            // `stop()` reset `starting=false` mid-await and a newer `start()`
            // entered, the newer call bumped `startCallGeneration` and now
            // owns `starting=true`. Clobbering it here would (a) trip the
            // newer call's lostRace `!self.starting` check and (b) hide the
            // newer call from a subsequent `stop()`, which would take its
            // no-op path and skip bumping `sessionGeneration`.
            if startCallGeneration == myStartCallGeneration {
                starting = false
            }
        }

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
            sampleRate: Double(Self.outputSampleRate),
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
        self._lastCaptureHealth = nil

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
                    if normalizedValue >= AudioCaptureHealth.silentInputMaximumLevel {
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
                self.markFirstBufferReceivedForDiagnostics(generation: tapGeneration)
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
                        let errorFields = AudioCaptureDiagnostics.errorFields(error)
                        Task { await self.logTapError("audio_write_error \(errorFields)") }
                    }
                }
            case .error:
                let alreadyLogged = self.tapErrorLogged.withLock { logged in
                    let was = logged; logged = true; return was
                }
                if !alreadyLogged {
                    let errorFields = error.map(AudioCaptureDiagnostics.errorFields) ?? "error_type=unknown"
                    Task { await self.logTapError("converter_error \(errorFields)") }
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
            // in-flight buffer handlers bail. The next caller surfaces the
            // capture-health problem instead of continuing with stale audio.
            self?.sessionGeneration.withLock { $0 += 1 }
        }

        AudioCaptureDiagnostics.append(
            "dictation_capture_starting"
        )

        let token: SharedMicrophoneStream.SubscriberToken
        var subscribeAttempt = 1
        while true {
            do {
                token = try await sharedStream.subscribe(
                    wantsVPIO: false,
                    onEngineDeath: deathHandler,
                    handler: bufferHandler
                )
                break
            } catch {
                if error is CancellationError {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }

                let startWasCancelled = preSubscribeGeneration != self.sessionGeneration.withLock { $0 }
                    || !self.starting
                    || self.startCallGeneration != myStartCallGeneration
                if startWasCancelled {
                    try? FileManager.default.removeItem(at: url)
                    AudioCaptureDiagnostics.append(
                        "dictation_capture_start_aborted reason=\"interrupted_during_subscribe\""
                    )
                    throw AudioProcessorError.recordingFailed("interrupted during subscribe")
                }

                if subscribeAttempt < Self.maxStartAttempts, Self.isRetryableStartError(error) {
                    AudioCaptureDiagnostics.append(
                        "dictation_capture_start_retry attempt=\(subscribeAttempt + 1) reason=engine_start_failed \(AudioCaptureDiagnostics.errorFields(error))"
                    )
                    subscribeAttempt += 1
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                    } catch {
                        try? FileManager.default.removeItem(at: url)
                        throw error
                    }
                    continue
                }

                try? FileManager.default.removeItem(at: url)
                AudioCaptureDiagnostics.append(
                    "dictation_capture_start_failed \(AudioCaptureDiagnostics.errorFields(error))"
                )
                throw AudioProcessorError.inputUnavailable(.engineStartFailed)
            }
        }

        // Actor-reentrancy guard. While we awaited subscribe, another
        // method (typically `stop()`) may have run on this actor — `stop()`
        // bumps the generation, so a generation mismatch means we're an
        // orphan. Unsubscribe and clean up rather than claim a recording
        // session that nobody asked for. The `!self.starting` clause catches
        // the rarer case where another `start()` entered after `stop()` reset
        // `starting`, took the slot, and is now in flight; we should not
        // claim a recording on its behalf. The per-call defer guard above
        // makes this safe — a sibling's defer cannot clobber the active
        // claim, so this check fires only when we genuinely lost the slot.
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
        self.recordingStartedAt = ProcessInfo.processInfo.systemUptime
        self.sharedSubscriberToken = token

        let liveFormat = sharedStream.inputFormat
        let liveSampleRate = liveFormat?.sampleRate ?? 0
        let liveChannelCount = liveFormat?.channelCount ?? 0
        let defaultInput = AudioCaptureDiagnostics.defaultInputDeviceSummary()
        AudioCaptureDiagnostics.append(
            "dictation_capture_engine_started file_created=true \(defaultInput) sr=\(liveSampleRate) ch=\(liveChannelCount)"
        )
        logger.info(
            "dictation_capture_started"
        )

        // Diagnostic instrumentation plus first-buffer readiness. The delayed
        // log still records the stall shape, while start() now refuses to
        // report a healthy recording until a usable first buffer arrives.
        armCaptureDiagnostics(generation: tapGeneration)

        let firstBufferArrived = await waitForFirstBuffer(
            generation: tapGeneration,
            timeoutSeconds: Self.firstBufferTimeoutSeconds
        )
        if !firstBufferArrived {
            await abortStartedCapture(
                token: token,
                url: url,
                generation: tapGeneration,
                reason: "no_first_buffer"
            )
            try Task.checkCancellation()
            throw AudioProcessorError.inputUnavailable(.noInputBuffers)
        }
    }

    /// Stop recording and return the path to the recorded WAV file.
    /// Throws `insufficientSamples` if the recording is shorter than the STT minimum.
    public func stop() throws -> URL {
        if starting, !recording {
            // `start()` awaits the stream subscription. A stop/cancel during
            // that await must invalidate the pending tap generation so the
            // in-flight start cannot claim a recording after cancellation.
            sessionGeneration.withLock { $0 += 1 }
            starting = false
            AudioCaptureDiagnostics.append(
                "dictation_capture_start_cancelled_during_subscribe"
            )
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
            disarmCaptureDiagnostics()
        }
        audioFile = nil
        recording = false
        let startedAt = recordingStartedAt
        recordingStartedAt = nil
        atomicAudioLevel.withLock { $0 = 0.0 }

        let url = outputURL
        outputURL = nil

        guard let url else {
            throw AudioProcessorError.recordingFailed("No output file")
        }

        let sampleCount = sampleCounter.withLock { $0 }
        let metrics = runtimeMetrics.withLock { $0 }
        let fileBytes = Self.fileSizeBytes(at: url)
        let duration = Double(sampleCount) / Double(Self.outputSampleRate)
        let wallDuration = startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? duration
        let health = AudioCaptureHealth(
            sampleCount: sampleCount,
            audioDurationSeconds: duration,
            wallDurationSeconds: wallDuration,
            fileBytes: fileBytes,
            inputBufferCount: metrics.inputBufferCount,
            outputBufferCount: metrics.outputBufferCount,
            inputFrameCount: metrics.inputFrameCount,
            maxRMS: metrics.maxRMS,
            maxAudioLevel: metrics.maxAudioLevel,
            nonSilentBufferCount: metrics.nonSilentBufferCount,
            missingFloatChannelDataBufferCount: metrics.missingFloatChannelDataBufferCount,
            invalidFormatBufferCount: metrics.invalidFormatBufferCount,
            noBufferTimeoutFired: metrics.noBufferTimeoutFired
        )
        _lastCaptureHealth = health
        logger.debug("stop sampleCount=\(sampleCount, privacy: .public)")
        AudioCaptureDiagnostics.append(
            "dictation_capture_stop sample_count=\(sampleCount) duration_s=\(String(format: "%.3f", duration)) wall_duration_s=\(String(format: "%.3f", wallDuration)) file_bytes=\(fileBytes.map(String.init) ?? "unknown") input_buffers=\(metrics.inputBufferCount) output_buffers=\(metrics.outputBufferCount) input_frames=\(metrics.inputFrameCount) max_rms=\(String(format: "%.6f", metrics.maxRMS)) max_level=\(String(format: "%.3f", metrics.maxAudioLevel)) non_silent_buffers=\(metrics.nonSilentBufferCount) missing_float_buffers=\(metrics.missingFloatChannelDataBufferCount) invalid_format_buffers=\(metrics.invalidFormatBufferCount) no_buffer_timeout=\(metrics.noBufferTimeoutFired)"
        )
        if let problem = health.terminalProblem {
            try? FileManager.default.removeItem(at: url)
            AudioCaptureDiagnostics.append(
                "dictation_capture_unavailable problem=\(problem.rawValue) sample_count=\(sampleCount) input_buffers=\(metrics.inputBufferCount) non_silent_buffers=\(metrics.nonSilentBufferCount) max_level=\(String(format: "%.3f", metrics.maxAudioLevel))"
            )
            throw AudioProcessorError.inputUnavailable(problem)
        }
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

    private static func isRetryableStartError(_ error: Error) -> Bool {
        if case SharedMicrophoneStream.SubscribeError.engineStartFailed = error {
            return true
        }
        return false
    }

    private func waitForFirstBuffer(
        generation: Int,
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if Task.isCancelled {
                return false
            }
            if captureDiagnosticsTimers.withLock({ $0.firstBufferSeenGeneration == generation }) {
                return true
            }
            if sessionGeneration.withLock({ $0 }) != generation || !recording {
                return false
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return captureDiagnosticsTimers.withLock { $0.firstBufferSeenGeneration == generation }
    }

    private func abortStartedCapture(
        token: SharedMicrophoneStream.SubscriberToken,
        url: URL,
        generation: Int,
        reason: String
    ) async {
        let generationStillActive = sessionGeneration.withLock { $0 } == generation
        let recorderStillOwnsToken = sharedSubscriberToken == token && recording
        guard generationStillActive || recorderStillOwnsToken else { return }

        sharedSubscriberToken = nil
        audioFile = nil
        outputURL = nil
        recording = false
        recordingStartedAt = nil
        atomicAudioLevel.withLock { $0 = 0.0 }
        sessionGeneration.withLock { $0 += 1 }
        disarmCaptureDiagnostics()
        sharedProcessingQueue.sync {}

        AudioCaptureDiagnostics.append(
            "dictation_capture_start_failed reason=\(reason)"
        )
        await sharedStream.unsubscribe(token)
        try? FileManager.default.removeItem(at: url)
    }

    private static func fileSizeBytes(at url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64 else {
            return nil
        }
        return size
    }

    // MARK: - Capture diagnostics

    /// Arm the first-buffer timeout and recording heartbeat. The timeout also
    /// records no-buffer state used by start/stop capture-health checks.
    ///
    /// `armedGeneration` (captured by both closures) is the value of
    /// `sessionGeneration` at the moment `start()` succeeded. If the closure
    /// later finds the live generation has moved past it, a `stop()` already
    /// raced ahead — in that case the closure bails out without logging.
    /// Without that guard, a heartbeat fired between `cancel()` and the
    /// queued event handler running could log against a session that has
    /// already ended.
    private func armCaptureDiagnostics(generation: Int) {
        let stream = sharedStream
        let armedGeneration = generation
        let shouldScheduleFirstBufferTimeout = captureDiagnosticsTimers.withLock { state -> Bool in
            let alreadySawFirstBuffer = state.firstBufferSeenGeneration == armedGeneration
            if !alreadySawFirstBuffer {
                state.firstBufferSeenGeneration = nil
            }
            state.armedGeneration = armedGeneration
            return !alreadySawFirstBuffer
        }
        if shouldScheduleFirstBufferTimeout {
            scheduleFirstBufferTimeout(generation: armedGeneration, stream: stream)
        }
        scheduleCaptureHeartbeat(generation: armedGeneration, stream: stream)
    }

    nonisolated private func scheduleFirstBufferTimeout(
        generation armedGeneration: Int,
        stream: SharedMicrophoneStream
    ) {
        diagnosticsQueue.asyncAfter(deadline: .now() + Self.firstBufferTimeoutSeconds) { [weak self, stream] in
            guard let self else { return }
            let shouldFire = self.captureDiagnosticsTimers.withLock { state -> Bool in
                guard state.armedGeneration == armedGeneration else { return false }
                guard state.firstBufferSeenGeneration != armedGeneration else { return false }
                return true
            }
            guard shouldFire else { return }
            guard self.sessionGeneration.withLock({ $0 }) == armedGeneration else { return }
            self.runtimeMetrics.withLock { $0.noBufferTimeoutFired = true }
            let isRunning = stream.diagnostics.engineRunning
            let defaultInput = AudioCaptureDiagnostics.defaultInputDeviceSummary()
            AudioCaptureDiagnostics.append(
                "dictation_capture_no_buffers_within_timeout isRunning=\(isRunning) \(defaultInput)"
            )
        }
    }

    nonisolated private func scheduleCaptureHeartbeat(
        generation armedGeneration: Int,
        stream: SharedMicrophoneStream
    ) {
        diagnosticsQueue.asyncAfter(deadline: .now() + Self.heartbeatIntervalSeconds) { [weak self, stream] in
            guard let self else { return }
            let isArmed = self.captureDiagnosticsTimers.withLock { state in
                state.armedGeneration == armedGeneration
            }
            guard isArmed else { return }
            guard self.sessionGeneration.withLock({ $0 }) == armedGeneration else { return }
            let metrics = self.runtimeMetrics.withLock { $0 }
            let isRunning = stream.diagnostics.engineRunning
            let defaultInput = AudioCaptureDiagnostics.defaultInputDeviceSummary()
            AudioCaptureDiagnostics.append(
                "dictation_capture_heartbeat input_buffers=\(metrics.inputBufferCount) input_frames=\(metrics.inputFrameCount) isRunning=\(isRunning) \(defaultInput)"
            )
            self.scheduleCaptureHeartbeat(generation: armedGeneration, stream: stream)
        }
    }

    /// Disarm delayed diagnostics. Already-scheduled closures still run, but
    /// their generation guards return before logging.
    private func disarmCaptureDiagnostics() {
        captureDiagnosticsTimers.withLock { state in
            state.firstBufferSeenGeneration = nil
            state.armedGeneration = -1
        }
    }

    /// Called from the audio tap path on the very first buffer of a
    /// session. Cancels the first-buffer timeout so it doesn't fire
    /// behind a healthy recording. The heartbeat continues — its job is
    /// to detect mid-session stalls, not just startup ones.
    nonisolated fileprivate func markFirstBufferReceivedForDiagnostics(generation: Int) {
        captureDiagnosticsTimers.withLock { state in
            state.firstBufferSeenGeneration = generation
        }
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
