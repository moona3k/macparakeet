import Foundation
import OSLog
@preconcurrency import AVFoundation

public struct MeetingInputDeviceAttempt: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case selected(uid: String)
        case systemDefault
        case builtIn
    }

    public let source: Source
    public let deviceID: AudioDeviceID

    public init(source: Source, deviceID: AudioDeviceID) {
        self.source = source
        self.deviceID = deviceID
    }
}

extension MeetingInputDeviceAttempt.Source {
    public var logValue: String {
        switch self {
        case .selected:
            return "selected"
        case .systemDefault:
            return "system_default"
        case .builtIn:
            return "built_in"
        }
    }
}

public func meetingInputDeviceAttempts(
    selectedUID: String?,
    selectedInputDeviceID: (String) -> AudioDeviceID?,
    defaultInputDevice: () -> AudioDeviceID?,
    builtInMicrophone: () -> AudioDeviceID?
) -> [MeetingInputDeviceAttempt] {
    var attempts: [MeetingInputDeviceAttempt] = []
    var seenDeviceIDs = Set<AudioDeviceID>()

    func append(_ source: MeetingInputDeviceAttempt.Source, deviceID: AudioDeviceID?) {
        guard let deviceID, seenDeviceIDs.insert(deviceID).inserted else { return }
        attempts.append(MeetingInputDeviceAttempt(source: source, deviceID: deviceID))
    }

    if let selectedUID {
        append(.selected(uid: selectedUID), deviceID: selectedInputDeviceID(selectedUID))
    }

    append(.systemDefault, deviceID: defaultInputDevice())
    append(.builtIn, deviceID: builtInMicrophone())

    return attempts
}

/// Routes meeting-mic capture through the process-wide
/// `SharedMicrophoneStream` so dictation and meeting recording can run
/// concurrently without dueling `AVAudioEngine` instances. Permission gate,
/// silent-buffer watchdog, processing-mode preferred→raw fallback, and
/// `AudioCaptureDiagnostics` events live at this layer; engine ownership and
/// device fallback live behind the stream's platform.
public final class MicrophoneCapture: @unchecked Sendable {
    public typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    public typealias StallObserver = @Sendable (MeetingAudioError) -> Void
    private enum LifecycleState {
        case idle
        case starting
        case running
        case stopping
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MicrophoneCapture")
    private let lifecycleQueue = DispatchQueue(label: "com.macparakeet.microphonecapture")
    private let watchdogQueue = DispatchQueue(label: "com.macparakeet.microphonecapture.watchdog", qos: .utility)
    private let handlerLock = NSLock()
    private let permissionProvider: @Sendable () -> Bool
    private let sharedStream: SharedMicrophoneStream
    private let watchdogLock = NSLock()

    private var state: LifecycleState = .idle
    private var bufferHandler: AudioBufferHandler?
    private var stallObserver: StallObserver?
    private var firstBufferReceived = false
    private var watchdogWorkItem: DispatchWorkItem?
    /// Active subscription token. Snapshotted by `stop()` and `deinit` so
    /// unsubscribe can fire without holding `self`.
    private var sharedSubscriberToken: SharedMicrophoneStream.SubscriberToken?

    public init(
        sharedStream: SharedMicrophoneStream,
        permissionProvider: @escaping @Sendable () -> Bool = {
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    ) {
        self.sharedStream = sharedStream
        self.permissionProvider = permissionProvider
    }

    deinit {
        // Snapshot the token off `self` because Task captures must outlive deinit.
        let token = lifecycleQueue.sync { sharedSubscriberToken }
        if let token {
            // Fire-and-forget: the stream's engine queue serializes the
            // unsubscribe behind any pending operations, so cleanup happens
            // even though we can't await from deinit.
            let stream = sharedStream
            Task { await stream.unsubscribe(token) }
        }
    }

    public static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public var inputFormat: AVAudioFormat? {
        sharedStream.inputFormat
    }

    public func start(
        processingMode: MeetingMicProcessingMode = .raw,
        handler: @escaping AudioBufferHandler,
        onStall: StallObserver? = nil
    ) async throws -> MeetingMicrophoneCaptureStartReport {
        let alreadyStarting: Bool = lifecycleQueue.sync {
            guard state == .idle else { return true }
            state = .starting
            return false
        }
        if alreadyStarting {
            throw MeetingAudioError.alreadyRunning
        }

        guard permissionProvider() else {
            lifecycleQueue.sync { state = .idle }
            AudioCaptureDiagnostics.append(
                "meeting_mic_capture_start_failed mode=\(String(describing: processingMode)) reason=\"permission_denied\""
            )
            throw MeetingAudioError.microphonePermissionDenied
        }

        AudioCaptureDiagnostics.append(
            "meeting_mic_capture_starting requested_mode=\(String(describing: processingMode)) default_input_pre=\(AudioCaptureDiagnostics.defaultInputDeviceLabel())"
        )

        handlerLock.withLock {
            bufferHandler = handler
            stallObserver = onStall
        }

        let bufferDispatch: SharedMicrophoneStream.BufferHandler = { [weak self] buffer, time in
            guard let self else { return }
            self.dispatchBuffer(
                buffer,
                time: time,
                extractVPIOChannelZero: self.sharedStream.isVPIOEngaged
            )
        }
        let deathDispatch: SharedMicrophoneStream.EngineDeathHandler = { [weak self] in
            guard let self else { return }
            let observer = self.handlerLock.withLock { self.stallObserver }
            observer?(.captureRuntimeFailure(
                "shared microphone engine stopped unexpectedly"
            ))
        }

        let wantsVPIO: Bool
        switch processingMode {
        case .raw:
            wantsVPIO = false
        case .vpioPreferred, .vpioRequired:
            wantsVPIO = true
        }

        let token: SharedMicrophoneStream.SubscriberToken
        var effectiveMode: MeetingMicProcessingEffectiveMode
        do {
            token = try await sharedStream.subscribe(
                wantsVPIO: wantsVPIO,
                onEngineDeath: deathDispatch,
                handler: bufferDispatch
            )
            // The effective mode reflects what the engine is actually
            // producing right now — `vpioEngaged=false` while a non-VPIO
            // subscriber holds the engine raw means the meeting is currently
            // capturing raw mic; engagement flips later when the blocker
            // leaves.
            effectiveMode = sharedStream.diagnostics.vpioEngaged ? .vpio : .raw
        } catch {
            switch processingMode {
            case .vpioPreferred:
                logger.warning(
                    "meeting_mic_processing_fallback requested=vpioPreferred effective=raw reason=\(error.localizedDescription, privacy: .public)"
                )
                AudioCaptureDiagnostics.append(
                    "meeting_mic_processing_fallback requested=vpioPreferred effective=raw reason=\"\(error.localizedDescription)\""
                )
                do {
                    token = try await sharedStream.subscribe(
                        wantsVPIO: false,
                        onEngineDeath: deathDispatch,
                        handler: bufferDispatch
                    )
                    effectiveMode = .raw
                } catch let fallbackError {
                    finalizeFailure(
                        processingMode: processingMode,
                        reason: fallbackError.localizedDescription
                    )
                    throw MeetingAudioError.audioEngineStartFailed(fallbackError.localizedDescription)
                }
            case .vpioRequired:
                AudioCaptureDiagnostics.append(
                    "meeting_mic_processing_unavailable mode=vpioRequired reason=\"\(error.localizedDescription)\""
                )
                finalizeFailure(
                    processingMode: processingMode,
                    reason: error.localizedDescription
                )
                throw MeetingAudioError.microphoneProcessingUnavailable(
                    mode: .vpioRequired,
                    reason: error.localizedDescription
                )
            case .raw:
                finalizeFailure(
                    processingMode: processingMode,
                    reason: error.localizedDescription
                )
                throw MeetingAudioError.audioEngineStartFailed(error.localizedDescription)
            }
        }

        if processingMode == .vpioRequired, effectiveMode != .vpio {
            let reason = "VPIO engagement deferred by active non-VPIO subscriber"
            await sharedStream.unsubscribe(token)
            AudioCaptureDiagnostics.append(
                "meeting_mic_processing_unavailable mode=vpioRequired reason=\"\(reason)\""
            )
            finalizeFailure(
                processingMode: processingMode,
                reason: reason
            )
            throw MeetingAudioError.microphoneProcessingUnavailable(
                mode: .vpioRequired,
                reason: reason
            )
        }

        // Subscribe succeeded — but `stop()` may have raced us during the
        // `await` and already taken the lifecycle to `.idle`. Re-check state
        // before claiming `.running`. If we lost the race, unsubscribe the
        // orphan token so the shared stream's engine isn't left with a live
        // subscriber that has no owner.
        let didTakeOwnership: Bool = lifecycleQueue.sync {
            guard state == .starting else { return false }
            sharedSubscriberToken = token
            state = .running
            return true
        }
        if !didTakeOwnership {
            let stream = sharedStream
            Task { await stream.unsubscribe(token) }
            AudioCaptureDiagnostics.append(
                "meeting_mic_capture_start_aborted reason=\"stop_during_subscribe\""
            )
            throw MeetingAudioError.audioEngineStartFailed("stop_during_subscribe")
        }

        // Watchdog must start AFTER the subscription is owned. Scheduling
        // earlier risks firing while a slow device-fallback chain is still
        // running through the platform.
        scheduleSilentBufferWatchdog()

        AudioCaptureDiagnostics.append(
            "meeting_mic_processing mode=\(effectiveMode.rawValue)"
        )

        let activeFormat = sharedStream.inputFormat
        let activeSampleRate = activeFormat?.sampleRate ?? 0
        let activeChannelCount = activeFormat?.channelCount ?? 0
        let activeInterleaved = activeFormat?.isInterleaved ?? false
        logger.info(
            "microphone_capture_started requested_mode=\(String(describing: processingMode), privacy: .public) effective_mode=\(effectiveMode.rawValue, privacy: .public) sample_rate=\(activeSampleRate, privacy: .public) channels=\(activeChannelCount, privacy: .public) interleaved=\(activeInterleaved, privacy: .public)"
        )
        AudioCaptureDiagnostics.append(
            "meeting_mic_capture_started requested_mode=\(String(describing: processingMode)) effective_mode=\(effectiveMode.rawValue) sr=\(activeSampleRate) ch=\(activeChannelCount) default_input=\(AudioCaptureDiagnostics.defaultInputDeviceLabel())"
        )

        return MeetingMicrophoneCaptureStartReport(
            requestedMode: processingMode,
            effectiveMode: effectiveMode
        )
    }

    private func finalizeFailure(
        processingMode: MeetingMicProcessingMode,
        reason: String
    ) {
        handlerLock.withLock {
            bufferHandler = nil
            stallObserver = nil
        }
        resetDiagnosticsState()
        lifecycleQueue.sync {
            state = .idle
        }
        AudioCaptureDiagnostics.append(
            "meeting_mic_capture_start_failed mode=\(String(describing: processingMode)) reason=\"\(reason)\""
        )
    }

    public func stop() {
        let snapshot: SharedMicrophoneStream.SubscriberToken? = lifecycleQueue.sync {
            guard state != .idle else { return nil }
            state = .stopping
            let token = sharedSubscriberToken
            sharedSubscriberToken = nil
            handlerLock.withLock {
                bufferHandler = nil
                stallObserver = nil
            }
            resetDiagnosticsState()
            state = .idle
            return token
        }
        guard let token = snapshot else { return }
        // Fire-and-forget so `stop()` stays synchronous (the protocol requires
        // it for the deinit path). The stream's engine queue serializes the
        // unsubscribe behind any pending operations.
        let stream = sharedStream
        Task { await stream.unsubscribe(token) }
        logger.info("microphone_capture_stopped")
        AudioCaptureDiagnostics.append(
            "meeting_mic_capture_stopped default_input_post=\(AudioCaptureDiagnostics.defaultInputDeviceLabel())"
        )
    }

    private func dispatchBuffer(
        _ buffer: AVAudioPCMBuffer,
        time: AVAudioTime,
        extractVPIOChannelZero: Bool
    ) {
        markFirstBufferReceived()
        let deliveredBuffer: AVAudioPCMBuffer
        if extractVPIOChannelZero {
            deliveredBuffer = extractChannelZero(from: buffer) ?? buffer
        } else {
            deliveredBuffer = buffer
        }
        let callback = handlerLock.withLock { bufferHandler }
        callback?(deliveredBuffer, time)
    }

    private func scheduleSilentBufferWatchdog() {
        let workItem = watchdogLock.withLock { () -> DispatchWorkItem in
            firstBufferReceived = false
            watchdogWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let shouldLog = self.watchdogLock.withLock { !self.firstBufferReceived }
                guard shouldLog else { return }
                let error = MeetingAudioError.captureRuntimeFailure(
                    "microphone capture started but delivered no buffers within 2 seconds"
                )
                self.logger.warning("microphone_capture_no_buffers_within_timeout")
                self.handlerLock.withLock { self.stallObserver }?(error)
            }
            watchdogWorkItem = item
            return item
        }
        watchdogQueue.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func markFirstBufferReceived() {
        let shouldLog = watchdogLock.withLock {
            guard !firstBufferReceived else { return false }
            firstBufferReceived = true
            watchdogWorkItem?.cancel()
            watchdogWorkItem = nil
            return true
        }
        if shouldLog {
            logger.info("microphone_capture_first_buffer_received")
            // Extract Sendable primitives so the diagnostics autoclosure
            // doesn't capture the non-Sendable `AVAudioFormat`.
            let format = inputFormat
            let firstBufferSampleRate = format?.sampleRate ?? 0
            let firstBufferChannelCount = format?.channelCount ?? 0
            let firstBufferInterleaved = format?.isInterleaved ?? false
            AudioCaptureDiagnostics.append(
                "meeting_mic_first_buffer sr=\(firstBufferSampleRate) ch=\(firstBufferChannelCount) interleaved=\(firstBufferInterleaved)"
            )
        }
    }

    private func resetDiagnosticsState() {
        watchdogLock.withLock {
            firstBufferReceived = false
            watchdogWorkItem?.cancel()
            watchdogWorkItem = nil
        }
    }
}
