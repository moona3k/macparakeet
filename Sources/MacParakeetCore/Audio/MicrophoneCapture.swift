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
/// every start. Input routing follows the user's microphone selection and is
/// independent of the current output device.
public func meetingInputDeviceAttempts(
    selectedUID: String?,
    selectedInputDeviceID: (String) -> AudioDeviceID?,
    defaultInputDevice: () -> AudioDeviceID?,
    builtInMicrophone: () -> AudioDeviceID?
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
    private enum LifecycleState: Equatable {
        case idle
        case starting(Int)
        case running(Int)
        case stopping(Int)
    }

    private enum StopAction {
        case none
        case wait(attemptID: Int)
        case unsubscribe(token: SharedMicrophoneStream.SubscriberToken, attemptID: Int)
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MicrophoneCapture")
    private let lifecycleQueue = DispatchQueue(label: "com.macparakeet.microphonecapture")
    private let watchdogQueue = DispatchQueue(label: "com.macparakeet.microphonecapture.watchdog", qos: .utility)
    private let handlerLock = NSLock()
    private let permissionProvider: @Sendable () -> Bool
    private let sharedStream: SharedMicrophoneStream
    private let watchdogLock = NSLock()

    private var state: LifecycleState = .idle
    private var nextStartAttemptID = 0
    private var stopSettlementWaiters: [(attemptID: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var bufferHandler: AudioBufferHandler?
    private var stallObserver: StallObserver?
    private var handlerGeneration: Int?
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
        let stoppingAttemptID = lifecycleQueue.sync { () -> Int? in
            guard case .stopping(let attemptID) = state else { return nil }
            return attemptID
        }
        if let stoppingAttemptID {
            await waitForStopSettlement(attemptID: stoppingAttemptID)
        }
        let attemptID: Int? = lifecycleQueue.sync {
            guard state == .idle else { return nil }
            nextStartAttemptID += 1
            state = .starting(nextStartAttemptID)
            return nextStartAttemptID
        }
        guard let attemptID else {
            throw MeetingAudioError.alreadyRunning
        }
        var didClaimRunning = false
        defer {
            if !didClaimRunning {
                completeStoppedStartIfOwned(attemptID: attemptID)
            }
        }

        guard permissionProvider() else {
            _ = finalizeFailureIfOwned(
                attemptID: attemptID,
                handlerGeneration: nil
            )
            AudioCaptureDiagnostics.append(
                "meeting_mic_capture_start_failed mode=\(String(describing: processingMode)) reason=\"permission_denied\""
            )
            throw MeetingAudioError.microphonePermissionDenied
        }

        AudioCaptureDiagnostics.append(
            "meeting_mic_capture_starting requested_mode=\(String(describing: processingMode)) \(AudioCaptureDiagnostics.defaultInputDeviceSummary())"
        )

        guard
            var activeWatchdogGeneration = installHandlersIfOwned(
                attemptID: attemptID,
                handler: handler,
                onStall: onStall
            )
        else {
            throw MeetingAudioError.audioEngineStartFailed("stop_during_start")
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
                onEngineDeath: makeEngineDeathDispatch(generation: activeWatchdogGeneration),
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
                    guard
                        let fallbackGeneration = replaceHandlerGenerationIfOwned(
                            attemptID: attemptID
                        )
                    else {
                        throw MeetingAudioError.audioEngineStartFailed("stop_during_subscribe")
                    }
                    activeWatchdogGeneration = fallbackGeneration
                    token = try await sharedStream.subscribe(
                        wantsVPIO: false,
                        onEngineDeath: makeEngineDeathDispatch(generation: activeWatchdogGeneration),
                        handler: makeBufferDispatch(generation: activeWatchdogGeneration)
                    )
                    effectiveMode = .raw
                } catch let fallbackError {
                    finalizeFailure(
                        attemptID: attemptID,
                        handlerGeneration: activeWatchdogGeneration,
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
                    attemptID: attemptID,
                    handlerGeneration: activeWatchdogGeneration,
                    processingMode: processingMode,
                    errorFields: AudioCaptureDiagnostics.errorFields(error)
                )
                throw MeetingAudioError.microphoneProcessingUnavailable(
                    mode: .vpioRequired,
                    reason: error.localizedDescription
                )
            case .raw:
                finalizeFailure(
                    attemptID: attemptID,
                    handlerGeneration: activeWatchdogGeneration,
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
                attemptID: attemptID,
                handlerGeneration: activeWatchdogGeneration,
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
            guard state == .starting(attemptID) else { return false }
            sharedSubscriberToken = token
            state = .running(attemptID)
            return true
        }
        if !didTakeOwnership {
            await sharedStream.unsubscribe(token)
            AudioCaptureDiagnostics.append(
                "meeting_mic_capture_start_aborted reason=\"stop_during_subscribe\""
            )
            throw MeetingAudioError.audioEngineStartFailed("stop_during_subscribe")
        }
        didClaimRunning = true

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
        attemptID: Int,
        handlerGeneration: Int,
        processingMode: MeetingMicProcessingMode,
        errorFields: String
    ) {
        _ = finalizeFailureIfOwned(
            attemptID: attemptID,
            handlerGeneration: handlerGeneration
        )
        AudioCaptureDiagnostics.append(
            "meeting_mic_capture_start_failed mode=\(String(describing: processingMode)) \(errorFields)"
        )
    }

    private func installHandlersIfOwned(
        attemptID: Int,
        handler: @escaping AudioBufferHandler,
        onStall: StallObserver?
    ) -> Int? {
        lifecycleQueue.sync {
            guard state == .starting(attemptID) else { return nil }
            let generation = nextWatchdogGeneration()
            handlerLock.withLock {
                bufferHandler = handler
                stallObserver = onStall
                handlerGeneration = generation
            }
            return generation
        }
    }

    private func replaceHandlerGenerationIfOwned(attemptID: Int) -> Int? {
        lifecycleQueue.sync {
            guard state == .starting(attemptID) else { return nil }
            let generation = nextWatchdogGeneration()
            handlerLock.withLock {
                handlerGeneration = generation
            }
            return generation
        }
    }

    @discardableResult
    private func finalizeFailureIfOwned(
        attemptID: Int,
        handlerGeneration expectedHandlerGeneration: Int?
    ) -> Bool {
        lifecycleQueue.sync {
            guard state == .starting(attemptID) else { return false }
            state = .stopping(attemptID)
            handlerLock.withLock {
                guard
                    expectedHandlerGeneration == nil
                        || handlerGeneration == expectedHandlerGeneration
                else { return }
                bufferHandler = nil
                stallObserver = nil
                handlerGeneration = nil
            }
            resetDiagnosticsState()
            state = .idle
            return true
        }
    }

    public func stop() async {
        let action: StopAction = lifecycleQueue.sync {
            switch state {
            case .idle:
                return .none
            case .stopping(let attemptID):
                return .wait(attemptID: attemptID)
            case .starting(let attemptID):
                beginStopLocked(attemptID: attemptID)
                return .wait(attemptID: attemptID)
            case .running(let attemptID):
                beginStopLocked(attemptID: attemptID)
                guard let token = sharedSubscriberToken else {
                    return .wait(attemptID: attemptID)
                }
                sharedSubscriberToken = nil
                return .unsubscribe(token: token, attemptID: attemptID)
            }
        }

        switch action {
        case .none:
            return
        case .wait(let attemptID):
            await waitForStopSettlement(attemptID: attemptID)
        case .unsubscribe(let token, let attemptID):
            await sharedStream.unsubscribe(token)
            finishStopIfOwned(attemptID: attemptID)
        }

        logger.info("microphone_capture_stopped")
        AudioCaptureDiagnostics.append(
            "meeting_mic_capture_stopped \(AudioCaptureDiagnostics.defaultInputDeviceSummary())"
        )
    }

    private func beginStopLocked(attemptID: Int) {
        state = .stopping(attemptID)
        handlerLock.withLock {
            bufferHandler = nil
            stallObserver = nil
            handlerGeneration = nil
        }
        resetDiagnosticsState()
    }

    private func completeStoppedStartIfOwned(attemptID: Int) {
        finishStopIfOwned(attemptID: attemptID)
    }

    private func finishStopIfOwned(attemptID: Int) {
        let waiters = lifecycleQueue.sync { () -> [CheckedContinuation<Void, Never>] in
            guard state == .stopping(attemptID) else { return [] }
            state = .idle
            let matching =
                stopSettlementWaiters
                .filter { $0.attemptID == attemptID }
                .map(\.continuation)
            stopSettlementWaiters.removeAll { $0.attemptID == attemptID }
            return matching
        }
        waiters.forEach { $0.resume() }
    }

    private func waitForStopSettlement(attemptID: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lifecycleQueue.sync { () -> Bool in
                guard state == .stopping(attemptID) else { return true }
                stopSettlementWaiters.append((attemptID, continuation))
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func dispatchBuffer(
        _ buffer: AVAudioPCMBuffer,
        time: AVAudioTime,
        extractVPIOChannelZero: Bool,
        generation: Int
    ) {
        guard hasActiveHandlers(generation: generation) else { return }
        markFirstBufferReceived(generation: generation)
        let deliveredBuffer: AVAudioPCMBuffer
        deliveredBuffer =
            microphoneCaptureMonoBuffer(
                from: buffer,
                extractVPIOChannelZero: extractVPIOChannelZero
            ) ?? buffer
        let callback = handlerLock.withLock { () -> AudioBufferHandler? in
            guard handlerGeneration == generation else { return nil }
            return bufferHandler
        }
        callback?(deliveredBuffer, time)
    }

    private func makeEngineDeathDispatch(
        generation: Int
    ) -> SharedMicrophoneStream.EngineDeathHandler {
        { [weak self] in
            guard let self else { return }
            let observer = self.handlerLock.withLock { () -> StallObserver? in
                guard self.handlerGeneration == generation else { return nil }
                return self.stallObserver
            }
            observer?(
                .captureRuntimeFailure(
                    "shared microphone engine stopped unexpectedly"
                )
            )
        }
    }

    private func hasActiveHandlers(generation: Int) -> Bool {
        handlerLock.withLock {
            handlerGeneration == generation && bufferHandler != nil
        }
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
                let observer = self.handlerLock.withLock { () -> StallObserver? in
                    guard self.handlerGeneration == generation else { return nil }
                    return self.stallObserver
                }
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
