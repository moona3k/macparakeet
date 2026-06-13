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
}

private struct DictationPreRollRingBuffer: Sendable {
    private let capacitySamples: Int
    private var storage: [Float]
    private var startIndex = 0
    private var sampleCount = 0

    init(capacitySamples: Int) {
        self.capacitySamples = max(1, capacitySamples)
        self.storage = Array(repeating: 0, count: max(1, capacitySamples))
    }

    mutating func append(_ samples: UnsafePointer<Float>, count incomingCount: Int) {
        guard incomingCount > 0 else { return }

        if incomingCount >= capacitySamples {
            let offset = incomingCount - capacitySamples
            for index in 0..<capacitySamples {
                storage[index] = samples[offset + index]
            }
            startIndex = 0
            sampleCount = capacitySamples
            return
        }

        for index in 0..<incomingCount {
            let writeIndex = (startIndex + sampleCount) % capacitySamples
            storage[writeIndex] = samples[index]
            if sampleCount < capacitySamples {
                sampleCount += 1
            } else {
                startIndex = (startIndex + 1) % capacitySamples
            }
        }
    }

    mutating func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            append(baseAddress, count: samples.count)
        }
    }

    mutating func clear() {
        startIndex = 0
        sampleCount = 0
    }

    func suffix(maxSamples: Int) -> [Float] {
        let count = min(sampleCount, max(0, maxSamples))
        guard count > 0 else { return [] }

        let firstSampleIndex = sampleCount - count
        return (0..<count).map { offset in
            storage[(startIndex + firstSampleIndex + offset) % capacitySamples]
        }
    }
}

private struct UncheckedSendableFloatSamples: @unchecked Sendable {
    let baseAddress: UnsafePointer<Float>
    let count: Int
}

/// Holds the per-recording diagnostic generation. The first-buffer timeout
/// fires once if no buffer has been delivered within
/// `firstBufferTimeoutSeconds` after `dictation_capture_engine_started`; the
/// heartbeat repeats every `heartbeatIntervalSeconds` while the recording is
/// active. Both are log-only and generation-guarded, so stale delayed closures
/// bail out after `stop()` or the next recording starts. See
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
/// to a temporary WAV file. VPIO buffers keep the channel-0-only rule because
/// channel 0 is the post-AEC processed mono. Raw multichannel device buffers
/// are downmixed so USB interfaces whose microphone lives on channel 2+ do not
/// record digital silence.
public actor AudioRecorder {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "AudioRecorder")
    private let permissionProvider: @Sendable () -> Bool
    /// True when the input device the shared engine would resolve to right
    /// now captures over Bluetooth. The Instant Dictation warm lease must
    /// never hold (or be revived onto) a Bluetooth input: an open Bluetooth
    /// microphone forces the headset into HFP/SCO, degrading playback for as
    /// long as the engine runs (issue #481). Active dictation sessions are
    /// unaffected — recording from a Bluetooth mic the user chose is fine;
    /// only the idle warm hold is suppressed.
    private let isBluetoothInputProvider: @Sendable () -> Bool
    /// Trailing debounce applied to `refreshInstantDictationWarmCapture`.
    /// Default-input-change notifications arrive in bursts (Core Audio fires
    /// duplicates, and Bluetooth profile transitions flap the default input),
    /// and each refresh restarts the warm engine — which itself can trigger
    /// the next notification. The debounce collapses a burst into one
    /// restart. Zero disables the debounce (tests, CLI).
    private let warmCaptureRefreshDebounce: Duration
    /// Supersession counter for debounced refreshes: each call bumps it, and
    /// a sleeper whose captured value is stale bails out without touching
    /// engine or pre-roll state.
    private var warmRefreshGeneration = 0
    private let sharedStream: SharedMicrophoneStream
    private var audioFile: AVAudioFile?
    private var sharedSubscriberToken: SharedMicrophoneStream.SubscriberToken?
    private var warmSubscriberToken: SharedMicrophoneStream.SubscriberToken?
    private var warmCaptureStartInFlight = false
    private var warmCaptureStartPending = false
    private var warmCaptureLifecycleGeneration = 0
    private var instantDictationEnabled = false
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
    nonisolated private let preRollBuffer = OSAllocatedUnfairLock(
        initialState: DictationPreRollRingBuffer(
            capacitySamples: Int(Double(ASRConstants.sampleRate) * 1.0)
        )
    )
    nonisolated private let preRollAcceptingSamples = OSAllocatedUnfairLock(initialState: false)
    nonisolated private let preRollCaptureGeneration = OSAllocatedUnfairLock(initialState: 0)
    nonisolated private let preRollConverterCache = TapConverterCache()
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
    private var liveSampleSink: DictationAudioSampleSink?
    private var recording = false
    private var starting = false
    /// Frames of instant-dictation pre-roll prepended to the current
    /// recording's WAV. Reset at every `start()` entry; read by `stop()` to
    /// trim the file head when `discardPreRollRequested` is set.
    private var preRollFramesWritten = 0
    /// Set via `discardPreRollForActiveRecording()` when system media was
    /// confirmed playing at dictation start — the pre-roll is then known to
    /// be pre-press media audio that no media pause can silence (issue #474).
    /// Best-effort: requests that arrive outside an active/starting session
    /// are dropped, and `start()` resets the flag so a stale request can
    /// never trim a later session's pre-roll.
    private var discardPreRollRequested = false
    /// Bumped on every `start()` entry that passes the entry guard. Each call
    /// captures its value as `myStartCallGeneration`; the `defer` only clears
    /// `starting` if no newer call has claimed the slot. Without this, an
    /// aborted sibling's defer would clobber a legitimate replacement start
    /// AND mislead `stop()` into taking its no-op path (which doesn't bump
    /// `sessionGeneration`), letting the replacement claim a recording the
    /// caller of `stop()` just asked to end.
    private var startCallGeneration: Int = 0

    private static let outputSampleRate = ASRConstants.sampleRate
    private static let preRollPrependSamples = Int(Double(outputSampleRate) * 0.45)

    /// Minimum samples before sending to STT. Mirrors FluidAudio's ASR guard,
    /// currently 0.3 seconds at 16 kHz.
    private static let minimumSamples = ASRConstants.minimumRequiredSamples(
        forSampleRate: outputSampleRate
    )

    /// Time after `engine_started` to wait for the first buffer before
    /// emitting `dictation_capture_no_buffers_within_timeout`. Mirrors the
    /// 2 s value used by `MicrophoneCapture.scheduleSilentBufferWatchdog`.
    private static let firstBufferTimeoutSeconds: TimeInterval = 2.0
    /// Cadence for the recording heartbeat log. Long enough that short
    /// dictations (< 5 s) don't add log noise; short enough that a stalled
    /// 18 s recording produces ~3 heartbeats showing `input_buffers=0`.
    private static let heartbeatIntervalSeconds: TimeInterval = 5.0

    public init(
        sharedStream: SharedMicrophoneStream,
        permissionProvider: @escaping @Sendable () -> Bool = {
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        },
        isBluetoothInputProvider: @escaping @Sendable () -> Bool = { false },
        warmCaptureRefreshDebounce: TimeInterval = 0
    ) {
        self.sharedStream = sharedStream
        self.permissionProvider = permissionProvider
        self.isBluetoothInputProvider = isBluetoothInputProvider
        self.warmCaptureRefreshDebounce = .seconds(max(0, warmCaptureRefreshDebounce))
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

    public func setInstantDictationEnabled(_ enabled: Bool) async {
        guard enabled != instantDictationEnabled else {
            if enabled {
                await startWarmCaptureIfNeeded()
            }
            return
        }

        instantDictationEnabled = enabled
        warmCaptureLifecycleGeneration += 1
        if enabled {
            preRollCaptureGeneration.withLock { $0 += 1 }
            preRollConverterCache.reset()
            preRollBuffer.withLock { $0.clear() }
            let shouldAcceptPreRoll = !recording && !starting
            preRollAcceptingSamples.withLock { $0 = shouldAcceptPreRoll }
            await startWarmCaptureIfNeeded()
        } else {
            warmCaptureStartPending = false
            preRollAcceptingSamples.withLock { $0 = false }
            preRollCaptureGeneration.withLock { $0 += 1 }
            sharedProcessingQueue.sync {}
            preRollConverterCache.reset()
            preRollBuffer.withLock { $0.clear() }
            await stopWarmCapture()
        }
    }

    public func refreshInstantDictationWarmCapture() async {
        guard instantDictationEnabled else { return }
        warmRefreshGeneration += 1
        let myGeneration = warmRefreshGeneration
        if warmCaptureRefreshDebounce > .zero {
            // Trailing debounce. The sleep suspends the actor, so a burst of
            // refresh calls each enters, bumps the generation, and sleeps;
            // only the last one survives the guard below. No state is touched
            // before this point, so superseded and cancelled sleepers leave
            // pre-roll and engine state exactly as they found it.
            try? await Task.sleep(for: warmCaptureRefreshDebounce)
            guard !Task.isCancelled,
                  myGeneration == warmRefreshGeneration,
                  instantDictationEnabled else { return }
        }
        warmCaptureLifecycleGeneration += 1
        preRollAcceptingSamples.withLock { $0 = false }
        preRollCaptureGeneration.withLock { $0 += 1 }
        sharedProcessingQueue.sync {}
        preRollConverterCache.reset()
        preRollBuffer.withLock { $0.clear() }
        if isBluetoothInputProvider() {
            // Drop the warm lease outright instead of deferring: leaving the
            // subscriber registered would let the shared stream's deferred
            // passive restart revive the warm engine on the Bluetooth input
            // after the active session ends. Active capture (dictation or
            // meeting mic) owns its own subscription and is unaffected.
            AudioCaptureDiagnostics.append(
                "dictation_warm_capture_suppressed reason=\"bluetooth_input\" \(AudioCaptureDiagnostics.defaultInputDeviceSummary())"
            )
            await stopWarmCapture()
            return
        }
        if recording || starting {
            await sharedStream.restartPassiveSubscribers()
            return
        }

        await stopWarmCapture()
        preRollCaptureGeneration.withLock { $0 += 1 }
        preRollConverterCache.reset()
        preRollBuffer.withLock { $0.clear() }
        await sharedStream.restartPassiveSubscribers()
        preRollAcceptingSamples.withLock { $0 = true }
        await startWarmCaptureIfNeeded()
    }

    /// Subscribe to the shared microphone stream and start writing converted
    /// buffers to a temp WAV file. Returns once the subscription is owned and
    /// the watchdog is armed.
    public func start() async throws {
        try await start(sampleSink: nil)
    }

    public func start(sampleSink: DictationAudioSampleSink?) async throws {
        var didClaimSampleSink = false
        defer {
            if !didClaimSampleSink {
                sampleSink?.onFinish()
            }
        }

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
        // This synchronous section has no suspension points, so a discard
        // request for *this* session cannot interleave before the reset; one
        // arriving for a previous aborted session is correctly cleared here.
        self.preRollFramesWritten = 0
        self.discardPreRollRequested = false
        self.preRollAcceptingSamples.withLock { $0 = false }
        self.sharedProcessingQueue.sync {}
        self.preRollCaptureGeneration.withLock { $0 += 1 }
        self.preRollConverterCache.reset()
        let preRollSamples: [Float] = instantDictationEnabled
            ? self.preRollBuffer.withLock { buffer in
                let samples = buffer.suffix(maxSamples: Self.preRollPrependSamples)
                buffer.clear()
                return samples
            }
            : []
        do {
            if !preRollSamples.isEmpty {
                try writePreRollSamples(preRollSamples, to: file, format: outputFormat)
                // Mirror the pre-roll into the live STT stream so live text
                // covers the same leading audio as the WAV. If the pre-roll
                // is later discarded (media playing, issue #474), the
                // dictation service degrades the live session instead.
                sampleSink?.onSamples(preRollSamples)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            if instantDictationEnabled {
                let hasWarmSubscriber = warmSubscriberToken != nil
                preRollCaptureGeneration.withLock { $0 += 1 }
                preRollConverterCache.reset()
                preRollBuffer.withLock { $0.clear() }
                preRollAcceptingSamples.withLock { $0 = hasWarmSubscriber }
            }
            throw error
        }

        let preSubscribeGeneration = self.sessionGeneration.withLock { $0 }
        let tapGeneration = preSubscribeGeneration
        let converterCache = TapConverterCache()
        let outputFormatBox = UncheckedSendableAudioFormat(outputFormat)
        let fileBox = UncheckedSendableAudioFile(file)

        let processCopiedBuffer: @Sendable (
            UncheckedSendableAudioPCMBuffer,
            AVAudioChannelCount,
            Bool
        ) -> Void = { [weak self] copiedBufferBox, originalChannelCount, extractVPIOChannelZero in
            guard let self else { return }
            guard self.sessionGeneration.withLock({ $0 }) == tapGeneration else { return }
            let buffer = copiedBufferBox.buffer

            guard let monoBuffer = microphoneCaptureMonoBuffer(
                from: buffer,
                extractVPIOChannelZero: extractVPIOChannelZero
            ) else {
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

            switch convertDictationBuffer(
                monoBuffer,
                outputFormat: outputFormatBox.format,
                converterCache: converterCache
            ) {
            case .converted(let convertedBuffer):
                guard self.sessionGeneration.withLock({ $0 }) == tapGeneration else { return }
                do {
                    let convertedFrameLength = Int(convertedBuffer.frameLength)
                    try fileBox.file.write(from: convertedBuffer)
                    self.sampleCounter.withLock { $0 += convertedFrameLength }
                    self.runtimeMetrics.withLock { $0.outputBufferCount += 1 }
                    if let sampleSink,
                       convertedFrameLength > 0,
                       let samples = convertedBuffer.floatChannelData?[0] {
                        sampleSink.onSamples(
                            Array(UnsafeBufferPointer(start: samples, count: convertedFrameLength))
                        )
                    }
                } catch {
                    let alreadyLogged = self.tapErrorLogged.withLock { logged in
                        let was = logged; logged = true; return was
                    }
                    if !alreadyLogged {
                        let errorFields = AudioCaptureDiagnostics.errorFields(error)
                        Task { await self.logTapError("audio_write_error \(errorFields)") }
                    }
                }
            case .failed(let message):
                let alreadyLogged = self.tapErrorLogged.withLock { logged in
                    let was = logged; logged = true; return was
                }
                if !alreadyLogged {
                    Task { await self.logTapError(message) }
                }
            case .noData:
                break
            }
        }
        let bufferHandler: SharedMicrophoneStream.BufferHandler = { [weak self] buffer, _ in
            guard let self else { return }
            guard self.sessionGeneration.withLock({ $0 }) == tapGeneration else { return }
            let originalChannelCount = buffer.format.channelCount
            let extractVPIOChannelZero = self.sharedStream.isVPIOEngaged
            guard let copiedBuffer = copyPCMBufferForAsyncUse(buffer) else {
                self.runtimeMetrics.withLock { $0.invalidFormatBufferCount += 1 }
                return
            }
            let copiedBufferBox = UncheckedSendableAudioPCMBuffer(copiedBuffer)
            self.sharedProcessingQueue.async {
                processCopiedBuffer(copiedBufferBox, originalChannelCount, extractVPIOChannelZero)
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
            if instantDictationEnabled {
                let hasWarmSubscriber = warmSubscriberToken != nil
                preRollCaptureGeneration.withLock { $0 += 1 }
                preRollConverterCache.reset()
                preRollBuffer.withLock { $0.clear() }
                preRollAcceptingSamples.withLock { $0 = hasWarmSubscriber }
            }
            AudioCaptureDiagnostics.append(
                "dictation_capture_start_failed \(AudioCaptureDiagnostics.errorFields(error))"
            )
            throw AudioProcessorError.recordingFailed(error.localizedDescription)
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
            if instantDictationEnabled {
                let hasWarmSubscriber = warmSubscriberToken != nil
                preRollCaptureGeneration.withLock { $0 += 1 }
                preRollConverterCache.reset()
                preRollBuffer.withLock { $0.clear() }
                preRollAcceptingSamples.withLock { $0 = hasWarmSubscriber }
            }
            AudioCaptureDiagnostics.append(
                "dictation_capture_start_aborted reason=\"interrupted_during_subscribe\""
            )
            throw AudioProcessorError.recordingFailed("interrupted during subscribe")
        }

        self.audioFile = file
        self.outputURL = url
        self.recording = true
        self.sharedSubscriberToken = token
        self.liveSampleSink = sampleSink
        didClaimSampleSink = true

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

        // Diagnostic instrumentation. Strictly log-only — these timers fire
        // observability events and never abort the recording. Treating the
        // tap-silence condition as "the user's recording is over" would mask
        // a regression behind a friendlier error message; we want to surface
        // the regression instead. See journal/2026-05-03-dictation-silent-stall.md.
        armCaptureDiagnostics(generation: tapGeneration)
    }

    /// Discard the instant-dictation pre-roll from the in-flight recording.
    /// Called when system media was confirmed playing at dictation start: the
    /// pre-roll is then pre-press media audio that no media pause can silence,
    /// and `stop()` trims it from the WAV before transcription (issue #474).
    /// Requests outside an active/starting session are dropped — best-effort
    /// by design; a missed request only keeps the original bleed window.
    public func discardPreRollForActiveRecording() {
        guard recording || starting else { return }
        discardPreRollRequested = true
    }

    /// Stop recording and return the path to the recorded WAV file.
    /// Throws `insufficientSamples` if the recording is shorter than the STT
    /// minimum — measured after any pre-roll discard, so a capture that is
    /// effectively media-only dismisses silently instead of transcribing it.
    public func stop() async throws -> URL {
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

        var unsubscribeTask: Task<Void, Never>?
        if let token = sharedSubscriberToken {
            // Fire-and-forget on the happy path so stop() never waits on the
            // stream's engine queue, which serializes the unsubscribe behind
            // any pending operations. The pre-roll discard path below awaits
            // this task — that is what releases the tap's retain on the
            // writer AVAudioFile, finalizing the WAV before it is re-read.
            let stream = sharedStream
            unsubscribeTask = Task { await stream.unsubscribe(token) }
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
        let sampleSink = liveSampleSink
        liveSampleSink = nil
        atomicAudioLevel.withLock { $0 = 0.0 }
        preRollCaptureGeneration.withLock { $0 += 1 }
        preRollConverterCache.reset()
        preRollBuffer.withLock { $0.clear() }
        // Snapshot + reset the discard state while still in the synchronous
        // section: the trim below suspends, and a reentrant start() must see
        // clean per-session state.
        let discardFrames = (discardPreRollRequested && preRollFramesWritten > 0)
            ? preRollFramesWritten
            : 0
        preRollFramesWritten = 0
        discardPreRollRequested = false
        if instantDictationEnabled {
            let hasWarmSubscriber = warmSubscriberToken != nil
            preRollAcceptingSamples.withLock { $0 = hasWarmSubscriber }
            if warmSubscriberToken == nil {
                Task { await self.startWarmCaptureIfNeeded() }
            }
        }

        let url = outputURL
        outputURL = nil

        guard let url else {
            throw AudioProcessorError.recordingFailed("No output file")
        }

        let sampleCount = sampleCounter.withLock { $0 }
        let metrics = runtimeMetrics.withLock { $0 }
        let fileBytes = Self.fileSizeBytes(at: url)
        let duration = Double(sampleCount) / Double(Self.outputSampleRate)
        logger.debug("stop sampleCount=\(sampleCount, privacy: .public)")
        AudioCaptureDiagnostics.append(
            "dictation_capture_stop sample_count=\(sampleCount) duration_s=\(String(format: "%.3f", duration)) file_bytes=\(fileBytes.map(String.init) ?? "unknown") input_buffers=\(metrics.inputBufferCount) output_buffers=\(metrics.outputBufferCount) input_frames=\(metrics.inputFrameCount) max_rms=\(String(format: "%.6f", metrics.maxRMS)) max_level=\(String(format: "%.3f", metrics.maxAudioLevel)) non_silent_buffers=\(metrics.nonSilentBufferCount) missing_float_buffers=\(metrics.missingFloatChannelDataBufferCount) invalid_format_buffers=\(metrics.invalidFormatBufferCount)"
        )
        // Length gate uses the post-discard count: a capture whose remainder
        // is below the STT floor would otherwise transcribe nothing but the
        // discarded media audio.
        let effectiveSampleCount = sampleCount - discardFrames
        guard effectiveSampleCount >= Self.minimumSamples else {
            // Clean up the too-short file
            try? FileManager.default.removeItem(at: url)
            let discardField = discardFrames > 0 ? " discarded_preroll_frames=\(discardFrames)" : ""
            AudioCaptureDiagnostics.append(
                "dictation_capture_insufficient sample_count=\(effectiveSampleCount) required=\(Self.minimumSamples)\(discardField)"
            )
            throw AudioProcessorError.insufficientSamples
        }
        sampleSink?.onFinish()

        if discardFrames > 0 {
            // Releasing the subscriber drops the tap's retain on the writer
            // AVAudioFile (the handler closure holds it); draining the
            // processing queue afterwards releases the copies held by any
            // already-enqueued blocks. Only then is the WAV finalized on disk
            // and safe to re-read. Suspending here is safe: every piece of
            // per-session actor state was reset above, and this path touches
            // only locals — a reentrant start() begins a fresh session
            // against a different file.
            await unsubscribeTask?.value
            sharedProcessingQueue.sync {}
            do {
                try Self.removeLeadingFrames(discardFrames, fromWAVAt: url)
                let duration = Double(discardFrames) / Double(Self.outputSampleRate)
                AudioCaptureDiagnostics.append(
                    "dictation_capture_preroll_discarded reason=media_paused sample_count=\(discardFrames) duration_s=\(String(format: "%.3f", duration))"
                )
            } catch {
                // Degrade to the pre-fix behavior (pre-roll bleed) rather
                // than lose the user's dictation.
                AudioCaptureDiagnostics.append(
                    "dictation_capture_preroll_discard_failed \(AudioCaptureDiagnostics.errorFields(error))"
                )
            }
        }

        return url
    }

    /// Rewrite the WAV at `url` without its first `frames` frames. Used by
    /// `stop()` to drop a media-contaminated instant-dictation pre-roll. The
    /// rewrite goes through a sibling temp file plus an atomic replace so a
    /// failure at any point leaves the original file intact.
    private static func removeLeadingFrames(_ frames: Int, fromWAVAt url: URL) throws {
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).wav")
        do {
            try writeCopy(of: url, skippingLeadingFrames: frames, to: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    /// Separate function so the writer `AVAudioFile`'s last strong reference
    /// is provably gone when it returns — dealloc finalizes the WAV header,
    /// which must happen before `removeLeadingFrames` swaps the file in.
    private static func writeCopy(
        of sourceURL: URL,
        skippingLeadingFrames frames: Int,
        to destinationURL: URL
    ) throws {
        let source = try AVAudioFile(forReading: sourceURL)
        // fileFormat, not processingFormat: the copy must preserve the
        // on-disk format. Identical for today's Float32 mono WAVs, but
        // processingFormat would silently reformat the copy if the recording
        // format ever changed (e.g. Int16).
        let writer = try AVAudioFile(
            forWriting: destinationURL,
            settings: source.fileFormat.settings
        )
        source.framePosition = AVAudioFramePosition(frames)
        var remaining = max(0, source.length - AVAudioFramePosition(frames))
        let chunkFrames: AVAudioFrameCount = 16_384
        while remaining > 0 {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: source.processingFormat,
                frameCapacity: count
            ) else {
                throw AudioProcessorError.recordingFailed("Failed to allocate pre-roll trim buffer")
            }
            try source.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            try writer.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    private func logTapError(_ message: String) {
        logger.warning("audio_tap \(message, privacy: .public)")
        AudioCaptureDiagnostics.append("dictation_capture_tap_error \(message)")
    }

    private func writePreRollSamples(
        _ samples: [Float],
        to file: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let destination = buffer.floatChannelData?[0] else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            if let baseAddress = pointer.baseAddress {
                destination.update(from: baseAddress, count: samples.count)
            }
        }
        try file.write(from: buffer)
        preRollFramesWritten = samples.count
        sampleCounter.withLock { $0 += samples.count }
        runtimeMetrics.withLock { $0.outputBufferCount += 1 }
        let duration = Double(samples.count) / Double(Self.outputSampleRate)
        AudioCaptureDiagnostics.append(
            "dictation_capture_preroll_prepend sample_count=\(samples.count) duration_s=\(String(format: "%.3f", duration))"
        )
    }

    private func startWarmCaptureIfNeeded() async {
        guard instantDictationEnabled,
              warmSubscriberToken == nil else { return }
        if warmCaptureStartInFlight {
            warmCaptureStartPending = true
            return
        }
        guard permissionProvider() else {
            preRollAcceptingSamples.withLock { $0 = false }
            AudioCaptureDiagnostics.append("dictation_warm_capture_start_skipped reason=\"permission_denied\"")
            return
        }
        guard !isBluetoothInputProvider() else {
            // Holding a Bluetooth input open while idle forces the headset
            // into HFP/SCO and degrades playback the entire time (issue
            // #481). Skip the warm hold; dictation falls back to a normal
            // cold start with no pre-roll.
            preRollAcceptingSamples.withLock { $0 = false }
            AudioCaptureDiagnostics.append(
                "dictation_warm_capture_suppressed reason=\"bluetooth_input\" \(AudioCaptureDiagnostics.defaultInputDeviceSummary())"
            )
            return
        }

        let lifecycleGeneration = warmCaptureLifecycleGeneration
        warmCaptureStartInFlight = true
        defer {
            warmCaptureStartInFlight = false
            if warmCaptureStartPending {
                warmCaptureStartPending = false
                Task { await self.startWarmCaptureIfNeeded() }
            }
        }

        let bufferHandler: SharedMicrophoneStream.BufferHandler = { [weak self] buffer, _ in
            guard let self else { return }
            guard self.preRollAcceptingSamples.withLock({ $0 }) else { return }
            let generation = self.preRollCaptureGeneration.withLock { $0 }
            let extractVPIOChannelZero = self.sharedStream.isVPIOEngaged
            guard let copiedBuffer = copyPCMBufferForAsyncUse(buffer) else { return }
            let copiedBufferBox = UncheckedSendableAudioPCMBuffer(copiedBuffer)
            self.sharedProcessingQueue.async {
                self.appendPreRollBuffer(
                    copiedBufferBox.buffer,
                    generation: generation,
                    extractVPIOChannelZero: extractVPIOChannelZero
                )
            }
        }
        let deathHandler: SharedMicrophoneStream.EngineDeathHandler = { [weak self] in
            guard let self else { return }
            self.preRollAcceptingSamples.withLock { $0 = false }
            self.preRollCaptureGeneration.withLock { $0 += 1 }
            self.sharedProcessingQueue.sync {}
            self.preRollConverterCache.reset()
            self.preRollBuffer.withLock { $0.clear() }
            Task { await self.handleWarmCaptureEngineDeath() }
        }

        do {
            let token = try await sharedStream.subscribe(
                wantsVPIO: false,
                blocksVPIOPromotion: false,
                onEngineDeath: deathHandler,
                handler: bufferHandler
            )
            guard instantDictationEnabled,
                  lifecycleGeneration == warmCaptureLifecycleGeneration,
                  warmSubscriberToken == nil else {
                preRollAcceptingSamples.withLock { $0 = false }
                preRollCaptureGeneration.withLock { $0 += 1 }
                sharedProcessingQueue.sync {}
                preRollConverterCache.reset()
                preRollBuffer.withLock { $0.clear() }
                await sharedStream.unsubscribe(token)
                return
            }
            warmSubscriberToken = token
            let shouldAcceptPreRoll = !recording && !starting
            preRollAcceptingSamples.withLock { $0 = shouldAcceptPreRoll }
            AudioCaptureDiagnostics.append("dictation_warm_capture_started preroll_s=0.450")
        } catch {
            preRollAcceptingSamples.withLock { $0 = false }
            AudioCaptureDiagnostics.append(
                "dictation_warm_capture_start_failed \(AudioCaptureDiagnostics.errorFields(error))"
            )
        }
    }

    private func stopWarmCapture() async {
        guard let token = warmSubscriberToken else { return }
        warmSubscriberToken = nil
        preRollAcceptingSamples.withLock { $0 = false }
        preRollCaptureGeneration.withLock { $0 += 1 }
        sharedProcessingQueue.sync {}
        preRollConverterCache.reset()
        preRollBuffer.withLock { $0.clear() }
        await sharedStream.unsubscribe(token)
        AudioCaptureDiagnostics.append("dictation_warm_capture_stopped")
    }

    private func handleWarmCaptureEngineDeath() {
        warmSubscriberToken = nil
        warmCaptureLifecycleGeneration += 1
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await self.startWarmCaptureIfNeeded()
        }
    }

    nonisolated private func appendPreRollBuffer(
        _ buffer: AVAudioPCMBuffer,
        generation: Int,
        extractVPIOChannelZero: Bool
    ) {
        guard preRollCaptureGeneration.withLock({ $0 }) == generation else { return }
        guard let monoBuffer = microphoneCaptureMonoBuffer(
            from: buffer,
            extractVPIOChannelZero: extractVPIOChannelZero
        ) else { return }
        guard monoBuffer.format.sampleRate > 0, monoBuffer.format.channelCount > 0 else { return }
        guard case .converted(let convertedBuffer) = convertDictationBuffer(
            monoBuffer,
            outputFormat: Self.preRollOutputFormatBox.format,
            converterCache: preRollConverterCache
        ) else {
            return
        }
        let frameCount = Int(convertedBuffer.frameLength)
        guard frameCount > 0, let samples = convertedBuffer.floatChannelData?[0] else { return }
        let sampleView = UncheckedSendableFloatSamples(
            baseAddress: UnsafePointer(samples),
            count: frameCount
        )
        guard preRollCaptureGeneration.withLock({ $0 }) == generation else { return }
        preRollBuffer.withLock { $0.append(sampleView.baseAddress, count: sampleView.count) }
    }

    private static func fileSizeBytes(at url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64 else {
            return nil
        }
        return size
    }

    nonisolated private static let preRollOutputFormatBox = UncheckedSendableAudioFormat(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(outputSampleRate),
            channels: 1,
            interleaved: false
        )!
    )

    // MARK: - Capture diagnostics (log-only)

    /// Arm the first-buffer timeout and recording heartbeat. Both are
    /// log-only; firing them does not affect the recording.
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

private enum DictationBufferConversionResult {
    case converted(AVAudioPCMBuffer)
    case noData
    case failed(String)
}

private func convertDictationBuffer(
    _ monoBuffer: AVAudioPCMBuffer,
    outputFormat: AVAudioFormat,
    converterCache: TapConverterCache
) -> DictationBufferConversionResult {
    let bufferFormat = monoBuffer.format
    if tapConverterNeedsRebuild(
        cachedSourceFormat: converterCache.sourceFormat,
        incomingBufferFormat: bufferFormat
    ) {
        converterCache.converter = AVAudioConverter(from: bufferFormat, to: outputFormat)
        converterCache.sourceFormat = bufferFormat
    }
    guard let converter = converterCache.converter else {
        let sr = bufferFormat.sampleRate
        let ch = bufferFormat.channelCount
        return .failed("converter_init_failed sr=\(sr) ch=\(ch)")
    }

    let outputFrameCapacity = AVAudioFrameCount(
        ceil(Double(monoBuffer.frameLength) * outputFormat.sampleRate / bufferFormat.sampleRate)
    )
    guard outputFrameCapacity > 0,
          let convertedBuffer = AVAudioPCMBuffer(
              pcmFormat: outputFormat,
              frameCapacity: outputFrameCapacity
          ) else {
        return .noData
    }

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
        return .converted(convertedBuffer)
    case .error:
        let errorFields = error.map(AudioCaptureDiagnostics.errorFields) ?? "error_type=unknown"
        return .failed("converter_error \(errorFields)")
    case .endOfStream, .inputRanDry:
        return .noData
    @unknown default:
        return .noData
    }
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

/// Converts a microphone tap buffer into the mono buffer downstream consumers
/// expect. VPIO uses channel 0 only because Core Audio puts the processed mono
/// signal there. Raw capture downmixes all channels so multichannel USB
/// interfaces work even when the physical mic is not wired to channel 1.
func microphoneCaptureMonoBuffer(
    from buffer: AVAudioPCMBuffer,
    extractVPIOChannelZero: Bool
) -> AVAudioPCMBuffer? {
    if extractVPIOChannelZero {
        return extractChannelZero(from: buffer)
    }
    return downmixChannelsToMono(from: buffer)
}

func downmixChannelsToMono(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let inputFormat = buffer.format
    let channelCount = Int(inputFormat.channelCount)
    guard channelCount > 0 else { return nil }
    if channelCount == 1 {
        return buffer
    }

    guard let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: inputFormat.sampleRate,
        channels: 1,
        interleaved: false
    ),
        let mixed = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: buffer.frameCapacity
        ),
        let destination = mixed.floatChannelData?[0] else {
        return nil
    }

    mixed.frameLength = buffer.frameLength
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return mixed }

    switch inputFormat.commonFormat {
    case .pcmFormatFloat32:
        guard fillDownmixedFloat32(
            from: buffer,
            channelCount: channelCount,
            frameCount: frameCount,
            destination: destination
        ) else { return nil }
    case .pcmFormatInt16:
        guard fillDownmixedInt16(
            from: buffer,
            channelCount: channelCount,
            frameCount: frameCount,
            destination: destination
        ) else { return nil }
    case .pcmFormatInt32:
        guard fillDownmixedInt32(
            from: buffer,
            channelCount: channelCount,
            frameCount: frameCount,
            destination: destination
        ) else { return nil }
    default:
        return nil
    }

    return mixed
}

private func fillDownmixedFloat32(
    from buffer: AVAudioPCMBuffer,
    channelCount: Int,
    frameCount: Int,
    destination: UnsafeMutablePointer<Float>
) -> Bool {
    if buffer.format.isInterleaved {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let sourceData = audioBuffer.mData else { return false }
        let source = sourceData.assumingMemoryBound(to: Float.self)
        for frameIndex in 0..<frameCount {
            var sum: Float = 0
            for channelIndex in 0..<channelCount {
                sum += source[(frameIndex * channelCount) + channelIndex]
            }
            destination[frameIndex] = sum / Float(channelCount)
        }
        return true
    }

    guard let source = buffer.floatChannelData else { return false }
    for frameIndex in 0..<frameCount {
        var sum: Float = 0
        for channelIndex in 0..<channelCount {
            sum += source[channelIndex][frameIndex]
        }
        destination[frameIndex] = sum / Float(channelCount)
    }
    return true
}

private func fillDownmixedInt16(
    from buffer: AVAudioPCMBuffer,
    channelCount: Int,
    frameCount: Int,
    destination: UnsafeMutablePointer<Float>
) -> Bool {
    if buffer.format.isInterleaved {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let sourceData = audioBuffer.mData else { return false }
        let source = sourceData.assumingMemoryBound(to: Int16.self)
        for frameIndex in 0..<frameCount {
            var sum: Float = 0
            for channelIndex in 0..<channelCount {
                sum += Float(source[(frameIndex * channelCount) + channelIndex]) / Float(Int16.max)
            }
            destination[frameIndex] = sum / Float(channelCount)
        }
        return true
    }

    guard let source = buffer.int16ChannelData else { return false }
    for frameIndex in 0..<frameCount {
        var sum: Float = 0
        for channelIndex in 0..<channelCount {
            sum += Float(source[channelIndex][frameIndex]) / Float(Int16.max)
        }
        destination[frameIndex] = sum / Float(channelCount)
    }
    return true
}

private func fillDownmixedInt32(
    from buffer: AVAudioPCMBuffer,
    channelCount: Int,
    frameCount: Int,
    destination: UnsafeMutablePointer<Float>
) -> Bool {
    if buffer.format.isInterleaved {
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        guard let sourceData = audioBuffer.mData else { return false }
        let source = sourceData.assumingMemoryBound(to: Int32.self)
        for frameIndex in 0..<frameCount {
            var sum: Float = 0
            for channelIndex in 0..<channelCount {
                sum += Float(source[(frameIndex * channelCount) + channelIndex]) / Float(Int32.max)
            }
            destination[frameIndex] = sum / Float(channelCount)
        }
        return true
    }

    guard let source = buffer.int32ChannelData else { return false }
    for frameIndex in 0..<frameCount {
        var sum: Float = 0
        for channelIndex in 0..<channelCount {
            sum += Float(source[channelIndex][frameIndex]) / Float(Int32.max)
        }
        destination[frameIndex] = sum / Float(channelCount)
    }
    return true
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

    func reset() {
        converter = nil
        sourceFormat = nil
    }
}
