import AVFoundation
import CoreAudio
import Foundation
import os

/// Abstract surface that `SharedMicrophoneStream` uses to drive real
/// `AVAudioEngine` operations. Splitting it out lets unit tests exercise the
/// stream's state machine and fan-out under a deterministic mock, while the
/// production adapter handles the Core Audio side.
///
/// Implementations must serialize concurrent calls. `SharedMicrophoneStream`
/// also serializes via its own engine queue, so platform implementations may
/// rely on that — but they must remain reentrancy-safe (e.g. handle a stop
/// during a partially-failed start).
public protocol MicrophoneEnginePlatform: AnyObject, Sendable {
    /// True between a successful `configureAndStart` and the next
    /// `stopEngine`. Implementations may also set this to `false` if the
    /// engine fails post-start.
    var isEngineRunning: Bool { get }

    /// Live input format reported by the running engine, or `nil` if the
    /// engine is not running or its format is invalid.
    var inputFormat: AVAudioFormat? { get }

    /// Idempotent start. Stops any existing engine and rebuilds it with the
    /// requested VPIO mode. Installs `tapHandler` as the buffer callback;
    /// the handler runs on the audio render thread.
    ///
    /// - Important: The buffer passed to `tapHandler` is valid only for the
    ///   synchronous duration of the call. Implementations must not retain
    ///   the buffer past return.
    func configureAndStart(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws

    /// Stop the engine, remove the tap, and tear down VPIO. Recreates the
    /// underlying `AVAudioEngine` so coreaudiod releases the VPAU aggregate
    /// (`CADefaultDeviceAggregate-<pid>-N`). Mirrors the ephemeral-engine
    /// pattern proven in `MicrophoneCapture` (PR #186).
    func stopEngine()

    /// Pre-pay device acquisition + format negotiation + tap install on a
    /// *stopped* engine so a later matching `configureAndStart` only pays
    /// `audioEngine.start()`. Best-effort and optional: the default
    /// implementation is a no-op, so a later full `configureAndStart` is always
    /// correct on its own.
    func prepare(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    )
}

public extension MicrophoneEnginePlatform {
    func prepare(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {}
}

/// The tap is installed during idle preparation, but the callback requested by
/// the eventual capture may be a newer closure. Keep that callback replaceable
/// without reinstalling the tap; copy it under the lock and invoke it after the
/// lock is released on the audio render thread.
private final class MutableMicrophoneTapHandler: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    private let handler: OSAllocatedUnfairLock<Handler?>

    init(_ handler: @escaping Handler) {
        self.handler = OSAllocatedUnfairLock(initialState: handler)
    }

    func replace(with handler: @escaping Handler) {
        self.handler.withLock { $0 = handler }
    }

    func invoke(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let current = handler.withLock { $0 }
        current?(buffer, time)
    }

    func clear() {
        handler.withLock { $0 = nil }
    }
}

/// Production adapter that drives a real `AVAudioEngine`. Mirrors the
/// engine-lifecycle invariants from `MicrophoneCapture` (PR #186):
///
/// - VPIO ducking is suppressed so other apps' audio isn't ~50% attenuated.
/// - VPIO AGC is disabled so it cannot write the shared hardware input gain
///   that other apps capturing the same mic (a live Zoom call) inherit.
/// - The engine is destroyed and recreated on stop so coreaudiod releases
///   the VPAU aggregate device. A long-lived engine keeps the VPAU alive
///   indefinitely, which inherits the duplex layout into other engines.
/// - When configured with a `deviceAttemptsBuilder`, each `configureAndStart`
///   walks the resolved attempt list (selected → implicit systemDefault →
///   builtIn) and recreates the engine on every failed attempt before trying
///   the next — the same fallback shape `MicrophoneCapture` uses today.
public final class AVAudioEngineMicrophonePlatform: MicrophoneEnginePlatform, @unchecked Sendable {
    public typealias DeviceAttemptsBuilder = @Sendable () -> [MeetingInputDeviceAttempt]
    public typealias InputDeviceSetter = @Sendable (AudioDeviceID, AVAudioEngine) -> Bool
    typealias EngineStarter =
        @Sendable (
            AVAudioEngine,
            Bool,
            AVAudioFrameCount,
            @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
        ) throws -> Void

    private let logger = Logger(
        subsystem: "com.macparakeet.core",
        category: "AVAudioEngineMicrophonePlatform"
    )
    private let queue = DispatchQueue(label: "com.macparakeet.shared-mic-platform")
    private let routeListenerQueue = DispatchQueue(
        label: "com.macparakeet.shared-mic-platform.route-listener"
    )
    private let deviceAttemptsBuilder: DeviceAttemptsBuilder?
    private let inputDeviceSetter: InputDeviceSetter
    private let engineStarter: EngineStarter?
    private var audioEngine = AVAudioEngine()
    private var running: Bool = false
    private var lastSucceededAttemptLocked: MeetingInputDeviceAttempt?
    /// Token for the `AVAudioEngine.configurationChangeNotification` observer
    /// installed on the current `audioEngine` instance. Cleared on
    /// `tearDown` / `resetEngine` / `replaceEngineAfterFailure` so the
    /// next instance gets its own observer. Drives both diagnostic logging
    /// and self-healing restart via `recoverFromConfigurationChangeLocked` —
    /// Core Audio sends this when the input chain reconfigures (default-input
    /// change, format change, sample-rate change), which is the most likely
    /// trigger for the silent tap-stall under investigation.
    private var configurationChangeObserver: NSObjectProtocol?
    private var defaultInputChangeObserver: AudioObjectPropertyListenerBlock?
    private var defaultOutputChangeObserver: AudioObjectPropertyListenerBlock?
    /// Parameters from the most recent successful start. Used by the
    /// configuration-change observer to re-run the exact same start sequence
    /// during self-healing recovery. Cleared at the start of each configure
    /// attempt and in `stopEngine()` — including when the platform is already
    /// stopped — so a stale tap-handler closure is never retained after a
    /// failed start or explicit stop. Never cleared by teardown / reset /
    /// engine-replace helpers (they are part of the recovery path).
    private struct StartRequest {
        let vpioEnabled: Bool
        let bufferSize: AVAudioFrameCount
        let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    }
    private var lastStartRequestLocked: StartRequest?

    // Prepared-but-stopped engine: device + format + tap are paid, but the engine
    // is not started, so there is no capture and no mic indicator. A later
    // `configureAndStart` with a matching request just calls `audioEngine.start()`
    // (~the engine-start cost only), shaving the ~device+format cold-start.
    private var prepared = false
    private var preparedAttempt: MeetingInputDeviceAttempt?
    private var preparedRouteSnapshot: [MeetingInputDeviceAttempt]?
    private var preparedVPIO = false
    private var preparedBufferSize: AVAudioFrameCount = 0
    private var tapHandlerBox: MutableMicrophoneTapHandler?
    /// Incremented synchronously in the notification callback before recovery
    /// is queued. The prepared snapshot lets key-down reject stale preparation
    /// even when it races the queued invalidation block.
    private let configurationChangeGeneration = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var preparedConfigurationGeneration: UInt64 = 0

    deinit {
        if running || prepared {
            tearDownLocked()
        } else {
            removeConfigurationChangeObserverLocked()
            removeRouteChangeObserversLocked()
        }
    }

    private static func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> String {
        String(format: "%.3f", Double(end - start) / 1_000_000.0)
    }

    /// Return the leading route attempt when it is safe to acquire while idle.
    /// Preparation never falls through to a lower-priority device: a transient
    /// preferred-route failure must be retried on key-down, not silently replaced
    /// by a prepared fallback. The route is pinned explicitly so a system default
    /// cannot change to Bluetooth between validation and preparation.
    static func prewarmAttemptPrefix(
        from attempts: [MeetingInputDeviceAttempt],
        bluetoothInputState: (AudioDeviceID) -> Bool?
    ) -> [MeetingInputDeviceAttempt] {
        guard let attempt = attempts.first, let deviceID = attempt.deviceID else { return [] }
        guard bluetoothInputState(deviceID) == false else { return [] }
        return [MeetingInputDeviceAttempt(source: attempt.source, deviceID: deviceID)]
    }

    public init(
        deviceAttemptsBuilder: DeviceAttemptsBuilder? = nil,
        inputDeviceSetter: @escaping InputDeviceSetter = { deviceID, engine in
            AudioDeviceManager.setInputDevice(deviceID, on: engine)
        }
    ) {
        self.deviceAttemptsBuilder = deviceAttemptsBuilder
        self.inputDeviceSetter = inputDeviceSetter
        self.engineStarter = nil
    }

    init(
        deviceAttemptsBuilder: DeviceAttemptsBuilder? = nil,
        inputDeviceSetter: @escaping InputDeviceSetter = { deviceID, engine in
            AudioDeviceManager.setInputDevice(deviceID, on: engine)
        },
        engineStarter: @escaping EngineStarter
    ) {
        self.deviceAttemptsBuilder = deviceAttemptsBuilder
        self.inputDeviceSetter = inputDeviceSetter
        self.engineStarter = engineStarter
    }

    public var isEngineRunning: Bool {
        // Must not be called from the platform's own queue — `queue.sync`
        // would deadlock. Caller is expected to be on a different queue
        // (typically `SharedMicrophoneStream.engineQueue` or a UI thread).
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { running }
    }

    /// Internal identity/state seam for deterministic configuration-change
    /// tests. Production callers use only the protocol surface above.
    var preparedEngineStateForTesting: (engine: AVAudioEngine, prepared: Bool) {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { (audioEngine, prepared) }
    }

    public var inputFormat: AVAudioFormat? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            guard running else { return nil }
            do {
                let format = try catchingObjCException {
                    audioEngine.inputNode.outputFormat(forBus: 0)
                }
                return format.sampleRate > 0 && format.channelCount > 0 ? format : nil
            } catch {
                let errorType = AudioCaptureDiagnostics.errorType(error)
                logger.error(
                    "shared_mic_engine_input_format_failed error_type=\(errorType, privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
                )
                AudioCaptureDiagnostics.append(
                    "shared_mic_engine_input_format_failed \(AudioCaptureDiagnostics.errorFields(error))"
                )
                return nil
            }
        }
    }

    /// The device attempt that produced the most recent successful start, or
    /// `nil` if no `deviceAttemptsBuilder` was configured (the engine used
    /// whatever device the system chose) or the platform is not running.
    public var lastSucceededAttempt: MeetingInputDeviceAttempt? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { running ? lastSucceededAttemptLocked : nil }
    }

    public func configureAndStart(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        try queue.sync {
            try configureAndStartLocked(
                vpioEnabled: vpioEnabled,
                bufferSize: bufferSize,
                tapHandler: tapHandler
            )
        }
    }

    /// Pre-pay device acquisition + format negotiation + tap install on a
    /// *stopped* engine (no capture, no mic indicator), so a later matching
    /// `configureAndStart` only pays `audioEngine.start()`. Best-effort: a no-op
    /// when the engine is already running/prepared or a test engineStarter is
    /// injected; a failure leaves the platform un-prepared (next start is full).
    public func prepare(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        queue.sync {
            guard engineStarter == nil, !running, !prepared else { return }
            // Route observation stays active even when preparation is currently
            // suppressed, so a later move from Bluetooth/unresolved to a safe
            // device can proactively retry before the next dictation.
            installRouteChangeObserversLocked()
            // Snapshot the route once and pin every eligible attempt explicitly.
            // Stop at the first unresolved/Bluetooth route: walking past it to a
            // later built-in fallback would change which device a real start uses.
            guard let routeSnapshot = deviceAttemptsBuilder?(), !routeSnapshot.isEmpty else {
                AudioCaptureDiagnostics.append(
                    "shared_mic_engine_prepare_skipped reason=unresolved_route"
                )
                return
            }
            let prewarmAttempts = Self.prewarmAttemptPrefix(
                from: routeSnapshot,
                bluetoothInputState: AudioDeviceManager.bluetoothInputState
            )
            guard !prewarmAttempts.isEmpty else {
                AudioCaptureDiagnostics.append(
                    "shared_mic_engine_prepare_skipped reason=bluetooth_or_unresolved_route"
                )
                return
            }
            // Observe before touching the engine. Core Audio may reconfigure
            // while device selection, format negotiation, tap installation, or
            // AVAudioEngine.prepare() is in flight; that entire window must be
            // covered before the result can be published as reusable.
            installConfigurationChangeObserverLocked()
            let preparationConfigurationGeneration = configurationChangeGeneration.withLock { $0 }
            do {
                try configureAndStartLocked(
                    vpioEnabled: vpioEnabled,
                    bufferSize: bufferSize,
                    tapHandler: tapHandler,
                    startNow: false,
                    attemptsOverride: prewarmAttempts,
                    preparationConfigurationGeneration: preparationConfigurationGeneration
                )
                if prepared {
                    preparedRouteSnapshot = routeSnapshot
                }
            } catch {
                prepared = false
                preparedRouteSnapshot = nil
                AudioCaptureDiagnostics.append(
                    "shared_mic_engine_prepare_failed \(AudioCaptureDiagnostics.errorFields(error))"
                )
            }
        }
    }

    public func stopEngine() {
        queue.sync {
            // Clear the stored start request unconditionally so the tap-handler
            // closure is never retained past an explicit stop, even when the
            // platform is already stopped.
            lastStartRequestLocked = nil
            let hasConfiguredEngine = running || prepared
            let hasRouteObservers = defaultInputChangeObserver != nil || defaultOutputChangeObserver != nil
            guard hasConfiguredEngine || hasRouteObservers else {
                return
            }
            // A suppressed Bluetooth/unresolved preparation installs only the
            // system route listeners. Remove those without asking AVAudioEngine
            // for its input node, which could itself touch the unsafe route.
            guard hasConfiguredEngine else {
                removeRouteChangeObserversLocked()
                return
            }
            tearDownLocked()
            logger.info("shared_mic_engine_stopped")
            AudioCaptureDiagnostics.append("shared_mic_engine_stopped")
        }
    }

    // MARK: - Internals (queue-held)

    /// Queue-held body of `configureAndStart`. Extracted so that
    /// `recoverFromConfigurationChangeLocked` (already on the platform queue)
    /// can re-run the full start sequence — including the device-fallback
    /// chain — without deadlocking.
    private func configureAndStartLocked(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        startNow: Bool = true,
        attemptsOverride: [MeetingInputDeviceAttempt]? = nil,
        preparationConfigurationGeneration: UInt64? = nil
    ) throws {
        lastStartRequestLocked = nil
        let currentRouteSnapshot = startNow ? deviceAttemptsBuilder?() : nil
        // Fast path: a matching prepared engine (device + format + tap already
        // paid, same VPIO/buffer/device) — just start it.
        if startNow, !running, prepared, engineStarter == nil,
            preparedVPIO == vpioEnabled, preparedBufferSize == bufferSize,
            currentRouteSnapshot == preparedRouteSnapshot
        {
            // The tap itself was installed during preparation. Swap its
            // dispatch target before start so the protocol's current caller,
            // not the earlier prewarm closure, receives every buffer.
            if let tapHandlerBox {
                tapHandlerBox.replace(with: tapHandler)
            } else {
                AudioCaptureDiagnostics.append(
                    "shared_mic_engine_prepared_discarded reason=missing_tap_handler"
                )
                tearDownLocked()
            }
            if prepared, goPreparedLocked() {
                lastSucceededAttemptLocked = preparedAttempt
                lastStartRequestLocked = StartRequest(
                    vpioEnabled: vpioEnabled,
                    bufferSize: bufferSize,
                    tapHandler: tapHandler
                )
                return
            }
        }
        // Anything else is a full (re)configure. A prepared engine already has
        // a tap installed, so replace it rather than merely clearing the flag;
        // otherwise the full path would try to install a second tap.
        if prepared {
            AudioCaptureDiagnostics.append(
                "shared_mic_engine_prepared_discarded reason=request_mismatch"
            )
            tearDownLocked()
        }
        // VPIO toggle requires a stop → setVoiceProcessingEnabled → start
        // sequence; the engine cannot be reconfigured while running.
        if running {
            tearDownLocked()
        }

        let attempts = attemptsOverride ?? currentRouteSnapshot ?? []
        if attempts.isEmpty {
            // No device chain — use whatever the engine's input node picks.
            try startConfiguredEngineLocked(
                vpioEnabled: vpioEnabled,
                bufferSize: bufferSize,
                tapHandler: tapHandler,
                startNow: startNow
            )
            if startNow {
                lastSucceededAttemptLocked = nil
                lastStartRequestLocked = StartRequest(
                    vpioEnabled: vpioEnabled,
                    bufferSize: bufferSize,
                    tapHandler: tapHandler
                )
            } else {
                guard let preparationConfigurationGeneration else { return }
                guard
                    markPreparedLocked(
                        attempt: nil,
                        vpioEnabled: vpioEnabled,
                        bufferSize: bufferSize,
                        startingConfigurationGeneration: preparationConfigurationGeneration
                    )
                else { return }
            }
            return
        }

        var lastError: Error?
        for attempt in attempts {
            let transport = AudioCaptureDiagnostics.deviceTransportLabel(attempt.deviceID)
            let deviceLabel = AudioCaptureDiagnostics.deviceLabel(attempt.deviceID)
            var setDeviceMilliseconds = "0.000"
            if let deviceID = attempt.explicitDeviceID {
                let setDeviceStartedAt = Self.nowNanos()
                let didSetDevice = inputDeviceSetter(deviceID, audioEngine)
                let setDeviceEndedAt = Self.nowNanos()
                setDeviceMilliseconds = Self.elapsedMilliseconds(
                    from: setDeviceStartedAt,
                    to: setDeviceEndedAt
                )
                guard didSetDevice else {
                    logger.warning(
                        "shared_mic_engine_input_device_set_failed source=\(attempt.source.logValue, privacy: .public) transport=\(transport, privacy: .public)"
                    )
                    AudioCaptureDiagnostics.append(
                        "shared_mic_engine_input_device_set_failed source=\(attempt.source.logValue) device=\(deviceLabel) transport=\(transport) set_device_ms=\(setDeviceMilliseconds)"
                    )
                    if lastError == nil {
                        lastError = AVAudioEngineMicrophonePlatformError.deviceSetFailed(attempt)
                    }
                    resetEngineLocked()
                    continue
                }
            }

            do {
                let startEngineStartedAt = Self.nowNanos()
                try startConfiguredEngineLocked(
                    vpioEnabled: vpioEnabled,
                    bufferSize: bufferSize,
                    tapHandler: tapHandler,
                    startNow: startNow
                )
                let startEngineEndedAt = Self.nowNanos()
                let startEngineMilliseconds = Self.elapsedMilliseconds(
                    from: startEngineStartedAt,
                    to: startEngineEndedAt
                )
                if startNow {
                    lastSucceededAttemptLocked = attempt
                    lastStartRequestLocked = StartRequest(
                        vpioEnabled: vpioEnabled,
                        bufferSize: bufferSize,
                        tapHandler: tapHandler
                    )
                } else {
                    guard let preparationConfigurationGeneration else { return }
                    guard
                        markPreparedLocked(
                            attempt: attempt,
                            vpioEnabled: vpioEnabled,
                            bufferSize: bufferSize,
                            startingConfigurationGeneration: preparationConfigurationGeneration
                        )
                    else { return }
                }
                logger.info(
                    "shared_mic_engine_input_device_\(startNow ? "started" : "prepared") source=\(attempt.source.logValue, privacy: .public) transport=\(transport, privacy: .public) vpio=\(vpioEnabled, privacy: .public)"
                )
                if startNow {
                    AudioCaptureDiagnostics.append(
                        "shared_mic_engine_input_device_started source=\(attempt.source.logValue) device=\(deviceLabel) transport=\(transport) vpio=\(vpioEnabled) set_device_ms=\(setDeviceMilliseconds) start_engine_ms=\(startEngineMilliseconds)"
                    )
                } else {
                    // Prepare-only: the engine is configured but stopped (no
                    // capture, no indicator). `prepare_engine_ms` is format +
                    // tap + AVAudioEngine.prepare(), NOT a real start — keep it
                    // a distinct event so latency reads aren't conflated.
                    AudioCaptureDiagnostics.append(
                        "shared_mic_engine_input_device_prepared source=\(attempt.source.logValue) device=\(deviceLabel) transport=\(transport) vpio=\(vpioEnabled) set_device_ms=\(setDeviceMilliseconds) prepare_engine_ms=\(startEngineMilliseconds)"
                    )
                }
                return
            } catch {
                lastError = error
                let errorType = AudioCaptureDiagnostics.errorType(error)
                logger.warning(
                    "shared_mic_engine_input_device_start_failed source=\(attempt.source.logValue, privacy: .public) transport=\(transport, privacy: .public) error_type=\(errorType, privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
                )
                AudioCaptureDiagnostics.append(
                    "shared_mic_engine_input_device_start_failed source=\(attempt.source.logValue) device=\(deviceLabel) transport=\(transport) set_device_ms=\(setDeviceMilliseconds) \(AudioCaptureDiagnostics.errorFields(error))"
                )
                // startConfiguredEngineLocked already replaces the engine on
                // failure, so nothing more to reset here.
            }
        }

        throw lastError ?? AVAudioEngineMicrophonePlatformError.noDeviceAvailable
    }

    private func startConfiguredEngineLocked(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        startNow: Bool = true
    ) throws {
        guard let engineStarter else {
            try startEngineLocked(
                vpioEnabled: vpioEnabled,
                bufferSize: bufferSize,
                tapHandler: tapHandler,
                startNow: startNow
            )
            return
        }
        // The injected engineStarter (tests) always starts; prepare() is gated to
        // engineStarter == nil, so startNow is always true here.

        do {
            try engineStarter(audioEngine, vpioEnabled, bufferSize, tapHandler)
        } catch {
            replaceEngineAfterFailureLocked()
            throw error
        }
        running = true
        installConfigurationChangeObserverLocked()
    }

    private func startEngineLocked(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        startNow: Bool = true
    ) throws {
        let totalStartedAt = Self.nowNanos()
        var setVPIOMilliseconds = "0.000"
        var duckingMilliseconds = "0.000"
        var outputFormatMilliseconds = "0.000"
        var installTapMilliseconds = "0.000"
        var audioEngineStartMilliseconds = "0.000"
        let inputNode = audioEngine.inputNode
        do {
            let phaseStartedAt = Self.nowNanos()
            try catchingObjCException {
                try inputNode.setVoiceProcessingEnabled(vpioEnabled)
            }
            setVPIOMilliseconds = Self.elapsedMilliseconds(
                from: phaseStartedAt,
                to: Self.nowNanos()
            )
        } catch {
            // VPIO toggle failed before tap install / engine start. Replace
            // the engine so the next attempt isn't on a half-configured one.
            replaceEngineAfterFailureLocked()
            throw error
        }
        if vpioEnabled, #available(macOS 14.0, *) {
            do {
                let phaseStartedAt = Self.nowNanos()
                try catchingObjCException {
                    inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
                        enableAdvancedDucking: false,
                        duckingLevel: .min
                    )
                }
                duckingMilliseconds = Self.elapsedMilliseconds(
                    from: phaseStartedAt,
                    to: Self.nowNanos()
                )
            } catch {
                let errorType = AudioCaptureDiagnostics.errorType(error)
                logger.debug(
                    "shared_mic_engine_ducking_config_failed error_type=\(errorType, privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
                )
            }
            do {
                // VPIO's AGC can write the shared hardware input gain of the
                // physical device, which every other app capturing the same
                // mic (e.g. a live Zoom call) inherits. Keep the experimental
                // VPIO path's side effects inside this process.
                try catchingObjCException {
                    inputNode.isVoiceProcessingAGCEnabled = false
                }
            } catch {
                let errorType = AudioCaptureDiagnostics.errorType(error)
                logger.debug(
                    "shared_mic_engine_agc_config_failed error_type=\(errorType, privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
                )
            }
        }

        let liveFormat: AVAudioFormat
        do {
            let phaseStartedAt = Self.nowNanos()
            liveFormat = try catchingObjCException {
                inputNode.outputFormat(forBus: 0)
            }
            outputFormatMilliseconds = Self.elapsedMilliseconds(
                from: phaseStartedAt,
                to: Self.nowNanos()
            )
        } catch {
            replaceEngineAfterFailureLocked()
            throw error
        }
        guard liveFormat.sampleRate > 0, liveFormat.channelCount > 0 else {
            replaceEngineAfterFailureLocked()
            throw AVAudioEngineMicrophonePlatformError.invalidInputFormat(
                sampleRate: liveFormat.sampleRate,
                channels: liveFormat.channelCount
            )
        }

        let installedTapHandler = MutableMicrophoneTapHandler(tapHandler)
        do {
            let phaseStartedAt = Self.nowNanos()
            try catchingObjCException {
                inputNode.installTap(
                    onBus: 0,
                    bufferSize: bufferSize,
                    format: nil
                ) { buffer, time in
                    installedTapHandler.invoke(buffer: buffer, time: time)
                }
            }
            tapHandlerBox = installedTapHandler
            installTapMilliseconds = Self.elapsedMilliseconds(
                from: phaseStartedAt,
                to: Self.nowNanos()
            )
        } catch {
            try? catchingObjCException {
                inputNode.removeTap(onBus: 0)
            }
            try? catchingObjCException {
                try inputNode.setVoiceProcessingEnabled(false)
            }
            replaceEngineAfterFailureLocked()
            throw error
        }

        // Prepare-only: device + format + tap are paid; stop here so the engine
        // is configured but not capturing (no mic indicator). The caller marks it
        // prepared; a later go just runs the `audioEngine.start()` below.
        guard startNow else {
            // Pre-allocate render resources so the eventual `start()` is cheaper.
            // Best-effort: a throw here just means start() does the work instead.
            try? catchingObjCException {
                audioEngine.prepare()
            }
            let preparedMilliseconds = Self.elapsedMilliseconds(from: totalStartedAt, to: Self.nowNanos())
            AudioCaptureDiagnostics.append(
                "shared_mic_engine_prepare_timing vpio=\(vpioEnabled) buffer_size=\(bufferSize) set_vpio_ms=\(setVPIOMilliseconds) output_format_ms=\(outputFormatMilliseconds) install_tap_ms=\(installTapMilliseconds) total_ms=\(preparedMilliseconds)"
            )
            return
        }

        do {
            let phaseStartedAt = Self.nowNanos()
            try catchingObjCException {
                try audioEngine.start()
            }
            audioEngineStartMilliseconds = Self.elapsedMilliseconds(
                from: phaseStartedAt,
                to: Self.nowNanos()
            )
        } catch {
            try? catchingObjCException {
                inputNode.removeTap(onBus: 0)
            }
            try? catchingObjCException {
                try inputNode.setVoiceProcessingEnabled(false)
            }
            replaceEngineAfterFailureLocked()
            throw error
        }
        running = true
        installConfigurationChangeObserverLocked()
        installRouteChangeObserversLocked()
        let totalMilliseconds = Self.elapsedMilliseconds(
            from: totalStartedAt,
            to: Self.nowNanos()
        )
        AudioCaptureDiagnostics.append(
            "shared_mic_engine_start_timing vpio=\(vpioEnabled) buffer_size=\(bufferSize) set_vpio_ms=\(setVPIOMilliseconds) ducking_ms=\(duckingMilliseconds) output_format_ms=\(outputFormatMilliseconds) install_tap_ms=\(installTapMilliseconds) audio_engine_start_ms=\(audioEngineStartMilliseconds) total_ms=\(totalMilliseconds)"
        )
    }

    /// Record that the current engine is configured-but-stopped for this request.
    private func markPreparedLocked(
        attempt: MeetingInputDeviceAttempt?,
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        startingConfigurationGeneration: UInt64
    ) -> Bool {
        let currentConfigurationGeneration = configurationChangeGeneration.withLock { $0 }
        guard currentConfigurationGeneration == startingConfigurationGeneration else {
            AudioCaptureDiagnostics.append(
                "shared_mic_engine_prepared_discarded reason=configuration_changed_during_prepare"
            )
            tearDownLocked()
            installRouteChangeObserversLocked()
            return false
        }
        prepared = true
        preparedAttempt = attempt
        preparedVPIO = vpioEnabled
        preparedBufferSize = bufferSize
        preparedConfigurationGeneration = currentConfigurationGeneration
        installRouteChangeObserversLocked()
        return true
    }

    /// Start a prepared engine (only the `audioEngine.start()` cost). Returns
    /// false if it fails, leaving the platform un-prepared so the caller does a
    /// full configure.
    private func goPreparedLocked() -> Bool {
        let observedGeneration = configurationChangeGeneration.withLock { $0 }
        guard observedGeneration == preparedConfigurationGeneration else {
            AudioCaptureDiagnostics.append(
                "shared_mic_engine_prepared_discarded reason=configuration_changed"
            )
            tearDownLocked()
            return false
        }
        let phaseStartedAt = Self.nowNanos()
        do {
            try catchingObjCException {
                try audioEngine.start()
            }
        } catch {
            replaceEngineAfterFailureLocked()  // clears prepared
            return false
        }
        running = true
        prepared = false
        preparedRouteSnapshot = nil
        installConfigurationChangeObserverLocked()
        installRouteChangeObserversLocked()
        AudioCaptureDiagnostics.append(
            "shared_mic_engine_started_from_prepared audio_engine_start_ms=\(Self.elapsedMilliseconds(from: phaseStartedAt, to: Self.nowNanos()))"
        )
        return true
    }

    private func tearDownLocked() {
        prepared = false
        preparedRouteSnapshot = nil
        preparedConfigurationGeneration = 0
        tapHandlerBox?.clear()
        tapHandlerBox = nil
        removeConfigurationChangeObserverLocked()
        removeRouteChangeObserversLocked()
        guard engineStarter == nil else {
            audioEngine = AVAudioEngine()
            running = false
            lastSucceededAttemptLocked = nil
            return
        }
        let inputNode = audioEngine.inputNode
        try? catchingObjCException {
            inputNode.removeTap(onBus: 0)
        }
        try? catchingObjCException {
            try inputNode.setVoiceProcessingEnabled(false)
        }
        try? catchingObjCException {
            audioEngine.stop()
        }
        // Replace the engine. Releasing the old instance tears down the
        // VPAU aggregate device coreaudiod created for it, so a sibling
        // AVAudioEngine in the same process doesn't inherit duplex layout.
        audioEngine = AVAudioEngine()
        running = false
        lastSucceededAttemptLocked = nil
    }

    /// Reset between failed device attempts (no tap installed yet, just
    /// hand back a fresh engine for the next try).
    private func resetEngineLocked() {
        prepared = false
        preparedRouteSnapshot = nil
        preparedConfigurationGeneration = 0
        tapHandlerBox?.clear()
        tapHandlerBox = nil
        removeConfigurationChangeObserverLocked()
        try? catchingObjCException {
            audioEngine.stop()
        }
        audioEngine = AVAudioEngine()
        running = false
        lastSucceededAttemptLocked = nil
    }

    private func replaceEngineAfterFailureLocked() {
        prepared = false
        preparedRouteSnapshot = nil
        preparedConfigurationGeneration = 0
        tapHandlerBox?.clear()
        tapHandlerBox = nil
        removeConfigurationChangeObserverLocked()
        try? catchingObjCException {
            audioEngine.stop()
        }
        audioEngine = AVAudioEngine()
        running = false
        lastSucceededAttemptLocked = nil
    }

    /// Observe `AVAudioEngine.configurationChangeNotification` on the
    /// current `audioEngine` and log every fire to `dictation-audio.log`.
    /// A prepared-but-stopped engine is discarded immediately so key-down
    /// cannot start a tap negotiated against the old input chain. A running
    /// engine calls `recoverFromConfigurationChangeLocked` to attempt a
    /// self-healing restart when all four gates pass:
    /// (1) `running == true`, (2) the notification belongs to the current
    /// engine instance, (3) `AVAudioEngine.isRunning == false`, and
    /// (4) the original start parameters are known.
    ///
    /// Core Audio posts `AVAudioEngineConfigurationChange` when the engine's
    /// input chain is renegotiated out from under us — default-input device
    /// change, sample-rate change, exclusive-access takeover by another
    /// process. The Apple-documented contract for this notification is that
    /// the client restarts the engine; this observer fulfils that contract
    /// while the watchdog/heartbeat in `AudioRecorder` remain log-only.
    private func installConfigurationChangeObserverLocked() {
        guard configurationChangeObserver == nil else { return }
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] notification in
            guard let self, let engine = notification.object as? AVAudioEngine else { return }
            self.configurationChangeGeneration.withLock { $0 &+= 1 }
            let engineBox = UncheckedSendableAudioEngine(engine)
            self.queue.async { [weak self, engineBox] in
                guard let self else { return }
                guard engineBox.wraps(self.audioEngine) else { return }
                let format = engineBox.inputFormat()
                let engineIsRunning = engineBox.isEngineRunning()
                let snapshot = (
                    sr: format?.sampleRate ?? 0,
                    ch: format?.channelCount ?? 0,
                    isRunning: self.running,
                    engineIsRunning: engineIsRunning
                )
                let defaultInput = AudioCaptureDiagnostics.defaultInputDeviceSummary()
                AudioCaptureDiagnostics.append(
                    "shared_mic_engine_configuration_changed sr=\(snapshot.sr) ch=\(snapshot.ch) isRunning=\(snapshot.isRunning) engine_is_running=\(snapshot.engineIsRunning) \(defaultInput)"
                )
                self.logger.info(
                    "shared_mic_engine_configuration_changed sr=\(snapshot.sr, privacy: .public) ch=\(snapshot.ch, privacy: .public) isRunning=\(snapshot.isRunning, privacy: .public) engine_is_running=\(snapshot.engineIsRunning, privacy: .public)"
                )
                if self.prepared {
                    AudioCaptureDiagnostics.append(
                        "shared_mic_engine_prepared_discarded reason=configuration_changed"
                    )
                    self.tearDownLocked()
                    self.installRouteChangeObserversLocked()
                    NotificationCenter.default.post(
                        name: .macParakeetMicrophoneSelectionDidChange,
                        object: nil
                    )
                    return
                }
                self.recoverFromConfigurationChangeLocked(engineBox: engineBox)
            }
        }
        configurationChangeObserver = token
    }

    private func removeConfigurationChangeObserverLocked() {
        if let token = configurationChangeObserver {
            NotificationCenter.default.removeObserver(token)
            configurationChangeObserver = nil
        }
    }

    /// Attempts to restart capture after an `AVAudioEngineConfigurationChange`
    /// notification. All four gates must be satisfied:
    /// 1. `running == true` — an explicit stop wins and suppresses recovery.
    /// 2. `engineBox.wraps(audioEngine)` — the notification belongs to the
    ///    current engine instance; stale events for a replaced engine are
    ///    discarded.
    /// 3. `engineBox.isEngineRunning() == false` — the engine actually
    ///    stopped; benign notifications around a healthy start are no-ops.
    /// 4. `lastStartRequestLocked != nil` — we have the parameters to replay.
    ///
    /// On success the engine is restarted with the original parameters.
    /// On failure `running` is left `false` (the start helpers guarantee
    /// this); a failed recovery does NOT retry — the next explicit
    /// `configureAndStart` resets everything.
    ///
    /// Loop safety: the observer is registered with `object: audioEngine` and
    /// removed on every teardown. Recovery replaces the engine, installing a
    /// fresh observer on the new instance. A failed recovery leaves
    /// `running == false`, which gates further attempts.
    private func recoverFromConfigurationChangeLocked(engineBox: UncheckedSendableAudioEngine) {
        guard running else { return }
        guard engineBox.wraps(audioEngine) else { return }
        guard !engineBox.isEngineRunning() else { return }
        guard let request = lastStartRequestLocked else { return }

        AudioCaptureDiagnostics.append("shared_mic_engine_config_change_recovery_attempt")
        logger.info("shared_mic_engine_config_change_recovery_attempt")

        do {
            try configureAndStartLocked(
                vpioEnabled: request.vpioEnabled,
                bufferSize: request.bufferSize,
                tapHandler: request.tapHandler
            )
            AudioCaptureDiagnostics.append("shared_mic_engine_config_change_recovery_succeeded")
            logger.info("shared_mic_engine_config_change_recovery_succeeded")
        } catch {
            AudioCaptureDiagnostics.append(
                "shared_mic_engine_config_change_recovery_failed \(AudioCaptureDiagnostics.errorFields(error))"
            )
            logger.error(
                "shared_mic_engine_config_change_recovery_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func installRouteChangeObserversLocked() {
        if defaultInputChangeObserver == nil {
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let inputBlock: AudioObjectPropertyListenerBlock = { _, _ in
                AudioCaptureDiagnostics.append(
                    "audio_default_input_changed \(AudioCaptureDiagnostics.defaultInputDeviceSummary())"
                )
                NotificationCenter.default.post(name: .macParakeetMicrophoneSelectionDidChange, object: nil)
            }
            let inputStatus = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &inputAddress,
                routeListenerQueue,
                inputBlock
            )
            if inputStatus == noErr {
                defaultInputChangeObserver = inputBlock
            } else {
                AudioCaptureDiagnostics.append(
                    "audio_default_input_listener_failed status=\(inputStatus)"
                )
            }
        }

        if defaultOutputChangeObserver == nil {
            var outputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let outputBlock: AudioObjectPropertyListenerBlock = { _, _ in
                let bluetooth = AudioDeviceManager.defaultOutputBluetoothState()
                AudioCaptureDiagnostics.append(
                    "audio_default_output_changed bluetooth=\(String(describing: bluetooth))"
                )
                NotificationCenter.default.post(name: .macParakeetMicrophoneSelectionDidChange, object: nil)
            }
            let outputStatus = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &outputAddress,
                routeListenerQueue,
                outputBlock
            )
            if outputStatus == noErr {
                defaultOutputChangeObserver = outputBlock
            } else {
                AudioCaptureDiagnostics.append(
                    "audio_default_output_listener_failed status=\(outputStatus)"
                )
            }
        }
    }

    private func removeRouteChangeObserversLocked() {
        if let inputBlock = defaultInputChangeObserver {
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &inputAddress,
                routeListenerQueue,
                inputBlock
            )
            defaultInputChangeObserver = nil
        }

        if let outputBlock = defaultOutputChangeObserver {
            var outputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &outputAddress,
                routeListenerQueue,
                outputBlock
            )
            defaultOutputChangeObserver = nil
        }
    }
}

public enum AVAudioEngineMicrophonePlatformError: Error, Equatable, LocalizedError {
    case deviceSetFailed(MeetingInputDeviceAttempt)
    case invalidInputFormat(sampleRate: Double, channels: AVAudioChannelCount)
    case noDeviceAvailable

    public var errorDescription: String? {
        switch self {
        case .deviceSetFailed(let attempt):
            return "Failed to set \(attempt.source.logValue) input device"
        case .invalidInputFormat(let sampleRate, let channels):
            return "Invalid input format: sampleRate=\(sampleRate) channels=\(channels)"
        case .noDeviceAvailable:
            return "No microphone input device available"
        }
    }
}
