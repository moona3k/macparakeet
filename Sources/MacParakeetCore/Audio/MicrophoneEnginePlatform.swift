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
}

/// Production adapter that drives a real `AVAudioEngine`. Mirrors the
/// engine-lifecycle invariants from `MicrophoneCapture` (PR #186):
///
/// - VPIO ducking is suppressed so other apps' audio isn't ~50% attenuated.
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
    typealias EngineStarter = @Sendable (
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
    private let defaultInputListenerQueue = DispatchQueue(
        label: "com.macparakeet.shared-mic-platform.default-input-listener"
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
    /// next instance gets its own observer. Recorded here purely to
    /// surface the signal in `dictation-audio.log` — Core Audio sends
    /// this when the input chain reconfigures (default-input change,
    /// format change, sample-rate change), which is the most likely
    /// trigger for the silent tap-stall under investigation.
    private var configurationChangeObserver: NSObjectProtocol?
    private var defaultInputChangeObserver: AudioObjectPropertyListenerBlock?

    private static func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> String {
        String(format: "%.3f", Double(end - start) / 1_000_000.0)
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
            // VPIO toggle requires a stop → setVoiceProcessingEnabled → start
            // sequence; the engine cannot be reconfigured while running.
            if running {
                tearDownLocked()
            }

            let attempts = deviceAttemptsBuilder?() ?? []
            if attempts.isEmpty {
                // No device chain — use whatever the engine's input node picks.
                try startConfiguredEngineLocked(
                    vpioEnabled: vpioEnabled,
                    bufferSize: bufferSize,
                    tapHandler: tapHandler
                )
                lastSucceededAttemptLocked = nil
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
                        tapHandler: tapHandler
                    )
                    let startEngineEndedAt = Self.nowNanos()
                    let startEngineMilliseconds = Self.elapsedMilliseconds(
                        from: startEngineStartedAt,
                        to: startEngineEndedAt
                    )
                    lastSucceededAttemptLocked = attempt
                    logger.info(
                        "shared_mic_engine_input_device_started source=\(attempt.source.logValue, privacy: .public) transport=\(transport, privacy: .public) vpio=\(vpioEnabled, privacy: .public)"
                    )
                    AudioCaptureDiagnostics.append(
                        "shared_mic_engine_input_device_started source=\(attempt.source.logValue) device=\(deviceLabel) transport=\(transport) vpio=\(vpioEnabled) set_device_ms=\(setDeviceMilliseconds) start_engine_ms=\(startEngineMilliseconds)"
                    )
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
    }

    public func stopEngine() {
        queue.sync {
            guard running else { return }
            tearDownLocked()
            logger.info("shared_mic_engine_stopped")
            AudioCaptureDiagnostics.append("shared_mic_engine_stopped")
        }
    }

    // MARK: - Internals (queue-held)

    private func startConfiguredEngineLocked(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        guard let engineStarter else {
            try startEngineLocked(
                vpioEnabled: vpioEnabled,
                bufferSize: bufferSize,
                tapHandler: tapHandler
            )
            return
        }

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
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
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

        do {
            let phaseStartedAt = Self.nowNanos()
            try catchingObjCException {
                inputNode.installTap(
                    onBus: 0,
                    bufferSize: bufferSize,
                    format: nil
                ) { buffer, time in
                    tapHandler(buffer, time)
                }
            }
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
        installDefaultInputChangeObserverLocked()
        let totalMilliseconds = Self.elapsedMilliseconds(
            from: totalStartedAt,
            to: Self.nowNanos()
        )
        AudioCaptureDiagnostics.append(
            "shared_mic_engine_start_timing vpio=\(vpioEnabled) buffer_size=\(bufferSize) set_vpio_ms=\(setVPIOMilliseconds) ducking_ms=\(duckingMilliseconds) output_format_ms=\(outputFormatMilliseconds) install_tap_ms=\(installTapMilliseconds) audio_engine_start_ms=\(audioEngineStartMilliseconds) total_ms=\(totalMilliseconds)"
        )
    }

    private func tearDownLocked() {
        removeConfigurationChangeObserverLocked()
        removeDefaultInputChangeObserverLocked()
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
        removeConfigurationChangeObserverLocked()
        removeDefaultInputChangeObserverLocked()
        try? catchingObjCException {
            audioEngine.stop()
        }
        audioEngine = AVAudioEngine()
        running = false
        lastSucceededAttemptLocked = nil
    }

    private func replaceEngineAfterFailureLocked() {
        removeConfigurationChangeObserverLocked()
        removeDefaultInputChangeObserverLocked()
        try? catchingObjCException {
            audioEngine.stop()
        }
        audioEngine = AVAudioEngine()
        running = false
        lastSucceededAttemptLocked = nil
    }

    /// Observe `AVAudioEngine.configurationChangeNotification` on the
    /// current `audioEngine` and log every fire to `dictation-audio.log`.
    /// Core Audio posts this when the engine's input chain is renegotiated
    /// out from under us — default-input device change, sample-rate
    /// change, exclusive-access takeover by another process. Without
    /// observing it, those events are invisible in our logs and the
    /// silent tap-stall they can leave behind has no signature beyond
    /// "buffers stopped arriving."
    private func installConfigurationChangeObserverLocked() {
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] notification in
            guard let self, let engine = notification.object as? AVAudioEngine else { return }
            let engineBox = UncheckedSendableAudioEngine(engine)
            self.queue.async { [weak self, engineBox] in
                guard let self else { return }
                let format = engineBox.inputFormat()
                let snapshot = (
                    sr: format?.sampleRate ?? 0,
                    ch: format?.channelCount ?? 0,
                    isRunning: self.running
                )
                let defaultInput = AudioCaptureDiagnostics.defaultInputDeviceSummary()
                AudioCaptureDiagnostics.append(
                    "shared_mic_engine_configuration_changed sr=\(snapshot.sr) ch=\(snapshot.ch) isRunning=\(snapshot.isRunning) \(defaultInput)"
                )
                self.logger.info(
                    "shared_mic_engine_configuration_changed sr=\(snapshot.sr, privacy: .public) ch=\(snapshot.ch, privacy: .public) isRunning=\(snapshot.isRunning, privacy: .public)"
                )
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

    private func installDefaultInputChangeObserverLocked() {
        guard defaultInputChangeObserver == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            AudioCaptureDiagnostics.append(
                "audio_default_input_changed \(AudioCaptureDiagnostics.defaultInputDeviceSummary())"
            )
            NotificationCenter.default.post(name: .macParakeetMicrophoneSelectionDidChange, object: nil)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultInputListenerQueue,
            block
        )
        guard status == noErr else {
            AudioCaptureDiagnostics.append(
                "audio_default_input_listener_failed status=\(status)"
            )
            return
        }
        defaultInputChangeObserver = block
    }

    private func removeDefaultInputChangeObserverLocked() {
        guard let block = defaultInputChangeObserver else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultInputListenerQueue,
            block
        )
        defaultInputChangeObserver = nil
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
