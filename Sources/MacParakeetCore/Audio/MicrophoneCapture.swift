import Foundation
import OSLog
@preconcurrency import AVFoundation

public struct MeetingInputDeviceAttempt: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case selected(uid: String)
        case systemDefault
        case builtIn
    }

    public enum Routing: Equatable, Sendable {
        case explicit(AudioDeviceID)
        case implicitSystemDefault(resolvedDeviceID: AudioDeviceID?)
    }

    public let source: Source
    public let routing: Routing

    public init(source: Source, deviceID: AudioDeviceID) {
        self.source = source
        self.routing = .explicit(deviceID)
    }

    private init(source: Source, routing: Routing) {
        self.source = source
        self.routing = routing
    }

    public static func implicitSystemDefault(resolvedDeviceID: AudioDeviceID? = nil) -> MeetingInputDeviceAttempt {
        MeetingInputDeviceAttempt(
            source: .systemDefault,
            routing: .implicitSystemDefault(resolvedDeviceID: resolvedDeviceID)
        )
    }

    public var deviceID: AudioDeviceID? {
        switch routing {
        case .explicit(let deviceID):
            return deviceID
        case .implicitSystemDefault(let resolvedDeviceID):
            return resolvedDeviceID
        }
    }

    public var explicitDeviceID: AudioDeviceID? {
        switch routing {
        case .explicit(let deviceID):
            return deviceID
        case .implicitSystemDefault:
            return nil
        }
    }

    public var usesImplicitSystemDefault: Bool {
        if case .implicitSystemDefault = routing { return true }
        return false
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

/// Builds the ordered device-attempt chain the shared mic engine walks on
/// every start, deduplicated by device ID unless a pinned built-in fallback is
/// needed to avoid an unpinned Bluetooth system default.
///
/// `preferBuiltInWhenOutputIsBluetooth` opts into the Bluetooth-output
/// avoidance rule. When audio output is currently routed to a Bluetooth
/// headset and the unpinned system-default input is Bluetooth, unresolved, or
/// the built-in mic itself, the built-in microphone is pinned before that
/// default fallback so opening the mic does not force the headset from A2DP
/// into HFP/SCO — which degrades playback and races the profile switch into
/// silent capture (issues #481 / #541 / #409). A resolvable explicit
/// selection stays first; the rule only changes the fallback behind it. The
/// rule is gated on whether a `.selected` attempt actually resolved, not just
/// on `selectedUID`: a saved-but-unavailable selection falls through to this
/// rule rather than landing on a Bluetooth system default. A non-Bluetooth
/// system-default input, such as a USB desk mic, is left alone.
/// `outputIsBluetooth` is consulted last, only once the cheap guards confirm
/// the rule could improve the chain, so the HAL query is skipped when the
/// feature is off, the default input is non-Bluetooth, or there is no built-in
/// mic to pin. `nil` means the output route could not be resolved during
/// route churn and is treated as risky only after those input guards pass.
public func meetingInputDeviceAttempts(
    selectedUID: String?,
    selectedInputDeviceID: (String) -> AudioDeviceID?,
    defaultInputDevice: () -> AudioDeviceID?,
    builtInMicrophone: () -> AudioDeviceID?,
    preferBuiltInWhenOutputIsBluetooth: Bool = false,
    defaultInputIsBluetooth: (AudioDeviceID) -> Bool = { _ in true },
    outputIsBluetooth: () -> Bool? = { false }
) -> [MeetingInputDeviceAttempt] {
    meetingInputDeviceAttempts(
        selectedUID: selectedUID,
        selectedInputDeviceID: selectedInputDeviceID,
        defaultInputDevice: defaultInputDevice,
        builtInMicrophone: builtInMicrophone,
        preferBuiltInWhenOutputIsBluetooth: preferBuiltInWhenOutputIsBluetooth,
        defaultInputIsBluetooth: defaultInputIsBluetooth,
        outputIsBluetooth: outputIsBluetooth,
        diagnosticsSink: { AudioCaptureDiagnostics.appendAsync($0) }
    )
}

func meetingInputDeviceAttempts(
    selectedUID: String?,
    selectedInputDeviceID: (String) -> AudioDeviceID?,
    defaultInputDevice: () -> AudioDeviceID?,
    builtInMicrophone: () -> AudioDeviceID?,
    preferBuiltInWhenOutputIsBluetooth: Bool = false,
    defaultInputIsBluetooth: (AudioDeviceID) -> Bool = { _ in true },
    outputIsBluetooth: () -> Bool? = { false },
    diagnosticsSink: @Sendable (String) -> Void
) -> [MeetingInputDeviceAttempt] {
    var attempts: [MeetingInputDeviceAttempt] = []
    var seenDeviceIDs = Set<AudioDeviceID>()

    func appendExplicit(_ source: MeetingInputDeviceAttempt.Source, deviceID: AudioDeviceID?) {
        guard let deviceID, seenDeviceIDs.insert(deviceID).inserted else { return }
        attempts.append(MeetingInputDeviceAttempt(source: source, deviceID: deviceID))
    }

    if let selectedUID {
        appendExplicit(.selected(uid: selectedUID), deviceID: selectedInputDeviceID(selectedUID))
    }

    let defaultDeviceID = defaultInputDevice()
    let builtInDeviceID = builtInMicrophone()
    if let defaultDeviceID {
        seenDeviceIDs.insert(defaultDeviceID)
    }
    attempts.append(.implicitSystemDefault(resolvedDeviceID: defaultDeviceID))

    appendExplicit(.builtIn, deviceID: builtInDeviceID)

    // Bluetooth-output avoidance. Gate on whether a `.selected` attempt
    // actually resolved (not just on `selectedUID`): a saved selection whose
    // device is currently unavailable produces no `.selected` attempt and
    // would otherwise fall back to a Bluetooth system default and still hit
    // the race. Leave non-Bluetooth system-default inputs (for example a USB
    // desk mic) alone; opening them does not force the headset output into
    // HFP/SCO. The cheap structural guards run before any transport query so
    // the HAL is consulted only when the chain can actually be made safer.
    let hasResolvedSelection = attempts.contains { attempt in
        if case .selected = attempt.source { return true }
        return false
    }
    var defaultOutputTransport = "not_queried"
    var policyOutcome = "skipped"
    var policyReason = preferBuiltInWhenOutputIsBluetooth ? "no_built_in_microphone" : "preference_off"

    func outputTransportLabel(_ outputIsBluetooth: Bool?) -> String {
        switch outputIsBluetooth {
        case .some(true):
            return "bluetooth"
        case .some(false):
            return "other"
        case .none:
            return "unresolved-nil"
        }
    }

    if preferBuiltInWhenOutputIsBluetooth,
        let builtInDeviceID
    {
        policyReason = "default_input_not_bluetooth"
        let shouldAvoidDefaultInput: Bool = {
            guard let defaultDeviceID else { return true }
            if defaultDeviceID == builtInDeviceID { return true }
            return defaultInputIsBluetooth(defaultDeviceID)
        }()

        var shouldAvoidDefaultOutput = false
        if shouldAvoidDefaultInput {
            let defaultOutputIsBluetooth = outputIsBluetooth()
            shouldAvoidDefaultOutput = defaultOutputIsBluetooth != false
            defaultOutputTransport = outputTransportLabel(defaultOutputIsBluetooth)
            policyReason = defaultOutputIsBluetooth == false ? "default_output_not_bluetooth" : "built_in_promoted"
            if hasResolvedSelection, defaultOutputIsBluetooth != false {
                policyReason = "explicit_selection_resolved"
            }
            policyOutcome = shouldAvoidDefaultOutput
                ? "fired"
                : "skipped"
        }

        if shouldAvoidDefaultInput, shouldAvoidDefaultOutput {
            let selectedDeviceID = attempts.first { attempt in
                if case .selected = attempt.source { return true }
                return false
            }?.deviceID
            let defaultIndex = attempts.firstIndex(where: \.usesImplicitSystemDefault)

            func removeImplicitDefaultFallback() {
                if let defaultIndex = attempts.firstIndex(where: \.usesImplicitSystemDefault) {
                    attempts.remove(at: defaultIndex)
                }
            }

            func moveOrInsertBuiltIn(at index: Int) {
                if let existingIndex = attempts.firstIndex(where: { $0.source == .builtIn }) {
                    let builtIn = attempts.remove(at: existingIndex)
                    attempts.insert(builtIn, at: existingIndex < index ? index - 1 : index)
                } else if selectedDeviceID != builtInDeviceID {
                    attempts.insert(
                        MeetingInputDeviceAttempt(source: .builtIn, deviceID: builtInDeviceID),
                        at: index
                    )
                }
            }

            if hasResolvedSelection {
                if selectedDeviceID == builtInDeviceID {
                    removeImplicitDefaultFallback()
                } else if let defaultIndex {
                    moveOrInsertBuiltIn(at: defaultIndex)
                    if defaultDeviceID == builtInDeviceID {
                        removeImplicitDefaultFallback()
                    }
                }
            } else if let builtInIndex = attempts.firstIndex(where: { $0.source == .builtIn }) {
                if builtInIndex != 0 {
                    let builtIn = attempts.remove(at: builtInIndex)
                    attempts.insert(builtIn, at: 0)
                }
            } else if defaultDeviceID == builtInDeviceID {
                removeImplicitDefaultFallback()
                attempts.insert(MeetingInputDeviceAttempt(source: .builtIn, deviceID: builtInDeviceID), at: 0)
            }
        }
    }
    let diagnosticsMessage =
        "mic_attempts_bluetooth_output_policy preference=\(preferBuiltInWhenOutputIsBluetooth ? "on" : "off") explicit_selection_resolved=\(hasResolvedSelection) default_output_transport=\(defaultOutputTransport) outcome=\(policyOutcome) reason=\(policyReason)"
    diagnosticsSink(diagnosticsMessage)

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
    private static let firstBufferTimeoutSeconds = 2.0
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
    /// Buffer callbacks can arrive before `start()` returns and arms the watchdog.
    /// Generation state keeps those early callbacks tied to the correct start attempt.
    private var watchdogGeneration = 0
    private var firstBufferSeenGeneration: Int?
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
            "meeting_mic_capture_starting requested_mode=\(String(describing: processingMode)) \(AudioCaptureDiagnostics.defaultInputDeviceSummary())"
        )

        handlerLock.withLock {
            bufferHandler = handler
            stallObserver = onStall
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
        var activeWatchdogGeneration = nextWatchdogGeneration()
        do {
            token = try await sharedStream.subscribe(
                wantsVPIO: wantsVPIO,
                onEngineDeath: deathDispatch,
                handler: makeBufferDispatch(generation: activeWatchdogGeneration)
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
                let errorType = AudioCaptureDiagnostics.errorType(error)
                logger.warning(
                    "meeting_mic_processing_fallback requested=vpioPreferred effective=raw error_type=\(errorType, privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
                )
                AudioCaptureDiagnostics.append(
                    "meeting_mic_processing_fallback requested=vpioPreferred effective=raw \(AudioCaptureDiagnostics.errorFields(error))"
                )
                do {
                    activeWatchdogGeneration = nextWatchdogGeneration()
                    token = try await sharedStream.subscribe(
                        wantsVPIO: false,
                        onEngineDeath: deathDispatch,
                        handler: makeBufferDispatch(generation: activeWatchdogGeneration)
                    )
                    effectiveMode = .raw
                } catch let fallbackError {
                    finalizeFailure(
                        processingMode: processingMode,
                        errorFields: AudioCaptureDiagnostics.errorFields(fallbackError)
                    )
                    throw MeetingAudioError.audioEngineStartFailed(fallbackError.localizedDescription)
                }
            case .vpioRequired:
                AudioCaptureDiagnostics.append(
                    "meeting_mic_processing_unavailable mode=vpioRequired \(AudioCaptureDiagnostics.errorFields(error))"
                )
                finalizeFailure(
                    processingMode: processingMode,
                    errorFields: AudioCaptureDiagnostics.errorFields(error)
                )
                throw MeetingAudioError.microphoneProcessingUnavailable(
                    mode: .vpioRequired,
                    reason: error.localizedDescription
                )
            case .raw:
                finalizeFailure(
                    processingMode: processingMode,
                    errorFields: AudioCaptureDiagnostics.errorFields(error)
                )
                throw MeetingAudioError.audioEngineStartFailed(error.localizedDescription)
            }
        }

        if processingMode == .vpioRequired, effectiveMode != .vpio {
            let reason = "VPIO engagement deferred by active non-VPIO subscriber"
            await sharedStream.unsubscribe(token)
            AudioCaptureDiagnostics.append(
                "meeting_mic_processing_unavailable mode=vpioRequired reason_code=vpio_deferred"
            )
            finalizeFailure(
                processingMode: processingMode,
                errorFields: "reason_code=vpio_deferred"
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
        scheduleSilentBufferWatchdog(generation: activeWatchdogGeneration)

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
            "meeting_mic_capture_started requested_mode=\(String(describing: processingMode)) effective_mode=\(effectiveMode.rawValue) sr=\(activeSampleRate) ch=\(activeChannelCount) \(AudioCaptureDiagnostics.defaultInputDeviceSummary())"
        )

        return MeetingMicrophoneCaptureStartReport(
            requestedMode: processingMode,
            effectiveMode: effectiveMode
        )
    }

    private func finalizeFailure(
        processingMode: MeetingMicProcessingMode,
        errorFields: String
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
            "meeting_mic_capture_start_failed mode=\(String(describing: processingMode)) \(errorFields)"
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
            "meeting_mic_capture_stopped \(AudioCaptureDiagnostics.defaultInputDeviceSummary())"
        )
    }

    private func dispatchBuffer(
        _ buffer: AVAudioPCMBuffer,
        time: AVAudioTime,
        extractVPIOChannelZero: Bool,
        generation: Int
    ) {
        markFirstBufferReceived(generation: generation)
        let deliveredBuffer: AVAudioPCMBuffer
        deliveredBuffer = microphoneCaptureMonoBuffer(
            from: buffer,
            extractVPIOChannelZero: extractVPIOChannelZero
        ) ?? buffer
        let callback = handlerLock.withLock { bufferHandler }
        callback?(deliveredBuffer, time)
    }

    private func makeBufferDispatch(generation: Int) -> SharedMicrophoneStream.BufferHandler {
        { [weak self] buffer, time in
            guard let self else { return }
            self.dispatchBuffer(
                buffer,
                time: time,
                extractVPIOChannelZero: self.sharedStream.isVPIOEngaged,
                generation: generation
            )
        }
    }

    private func nextWatchdogGeneration() -> Int {
        watchdogLock.withLock {
            watchdogGeneration += 1
            firstBufferSeenGeneration = nil
            watchdogWorkItem?.cancel()
            watchdogWorkItem = nil
            return watchdogGeneration
        }
    }

    private func scheduleSilentBufferWatchdog(generation: Int) {
        let workItem = watchdogLock.withLock { () -> DispatchWorkItem? in
            guard firstBufferSeenGeneration != generation else {
                watchdogWorkItem?.cancel()
                watchdogWorkItem = nil
                return nil
            }
            watchdogWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let shouldLog = self.watchdogLock.withLock {
                    self.watchdogGeneration == generation
                        && self.firstBufferSeenGeneration != generation
                }
                guard shouldLog else { return }
                let error = MeetingAudioError.captureRuntimeFailure(
                    "microphone capture started but delivered no buffers within 2 seconds"
                )
                let observer = self.handlerLock.withLock { self.stallObserver }
                observer?(error)

                let elapsedSeconds = String(
                    format: "%.3f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    Self.firstBufferTimeoutSeconds
                )
                let isRunning = self.sharedStream.diagnostics.engineRunning
                let defaultInput = AudioCaptureDiagnostics.defaultInputDeviceSummary()
                self.logger.warning(
                    "microphone_capture_no_buffers_within_timeout elapsed_s=\(elapsedSeconds, privacy: .public) isRunning=\(isRunning, privacy: .public) \(defaultInput, privacy: .public)"
                )
                AudioCaptureDiagnostics.appendAsync(
                    "meeting_mic_capture_no_buffers_within_timeout elapsed_s=\(elapsedSeconds) isRunning=\(isRunning) \(defaultInput)"
                )
            }
            watchdogWorkItem = item
            return item
        }
        if let workItem {
            watchdogQueue.asyncAfter(deadline: .now() + Self.firstBufferTimeoutSeconds, execute: workItem)
        }
    }

    private func markFirstBufferReceived(generation: Int) {
        let shouldLog = watchdogLock.withLock {
            guard watchdogGeneration == generation else { return false }
            guard firstBufferSeenGeneration != generation else { return false }
            firstBufferSeenGeneration = generation
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
            watchdogGeneration += 1
            firstBufferSeenGeneration = nil
            watchdogWorkItem?.cancel()
            watchdogWorkItem = nil
        }
    }
}
