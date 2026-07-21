import Foundation
import OSLog
@preconcurrency import AVFoundation

public enum MeetingAudioCaptureEvent: Sendable {
    case microphoneBuffer(AVAudioPCMBuffer, AVAudioTime)
    case systemBuffer(AVAudioPCMBuffer, AVAudioTime)
    case microphoneHealth(MeetingMicHealthMonitor.HealthEvent)
    case sourceRecoveryStarted(source: AudioSource, error: MeetingAudioError)
    case sourceRecovered(source: AudioSource)
    case sourceInterrupted(source: AudioSource, error: MeetingAudioError)
    case error(MeetingAudioError)
}

public protocol MeetingAudioCapturing: Sendable {
    var events: AsyncStream<MeetingAudioCaptureEvent> { get async }
    func start(sourceMode: MeetingAudioSourceMode?) async throws -> MeetingAudioCaptureStartReport
    func stop() async
}

public extension MeetingAudioCapturing {
    func start() async throws -> MeetingAudioCaptureStartReport {
        try await start(sourceMode: nil)
    }
}

protocol MeetingMicrophoneCapturing: Sendable {
    typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    typealias StallObserver = @Sendable (MeetingAudioError) -> Void
    func start(
        processingMode: MeetingMicProcessingMode,
        handler: @escaping AudioBufferHandler,
        onStall: StallObserver?
    ) async throws -> MeetingMicrophoneCaptureStartReport
    func stop() async
}

extension MicrophoneCapture: MeetingMicrophoneCapturing {}

protocol MeetingSystemAudioCapturing: Sendable {
    typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    typealias StallObserver = @Sendable (MeetingAudioError) -> Void
    func start(handler: @escaping AudioBufferHandler, onStall: StallObserver?) async throws
    func stop() async
}

extension MeetingSystemAudioCapturing {
    func start(handler: @escaping AudioBufferHandler) async throws {
        try await start(handler: handler, onStall: nil)
    }
}

extension SystemAudioStream: MeetingSystemAudioCapturing {}

public actor MeetingAudioCaptureService {
    public typealias EventHandler = @Sendable (MeetingAudioCaptureEvent) -> Void
    typealias MeetingMicrophoneCaptureFactory = @Sendable () -> any MeetingMicrophoneCapturing

    // Route changes can leave ScreenCaptureKit without buffers while Core Audio
    // settles for many seconds. Keep retries bounded, but cover that transition
    // window instead of declaring the system source dead after a few seconds.
    // Six attempts span 23 seconds of scheduled backoff; bounded stream
    // start/readiness/teardown work is additional.
    private static let productionSystemAudioRecoveryDelays: [Duration] = [
        .zero,
        .seconds(1),
        .seconds(2),
        .seconds(4),
        .seconds(8),
        .seconds(8),
    ]

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioCaptureService")
    private let microphoneCapture: any MeetingMicrophoneCapturing
    private let systemAudioCaptureFactory: @Sendable () throws -> any MeetingSystemAudioCapturing
    private let micProcessingMode: MeetingMicProcessingMode
    private let sourceModeProvider: @Sendable () -> MeetingAudioSourceMode
    private let systemAudioRecoveryDelays: [Duration]
    private let micHealthObserver: MeetingMicHealthTelemetryObserver
    private let systemAudioCallbackGate = SystemAudioCallbackGate()

    private enum LifecycleState: Equatable {
        case idle
        case starting(Int)
        case running(Int)
        case stopping(Int)

        var attemptID: Int? {
            switch self {
            case .idle:
                return nil
            case .starting(let attemptID), .running(let attemptID), .stopping(let attemptID):
                return attemptID
            }
        }
    }

    private var systemAudioCapture: (any MeetingSystemAudioCapturing)?
    private var systemAudioCaptureGeneration: Int?
    private var nextSystemAudioCaptureGeneration = 0
    private var activeSystemAudioRecoveryID: Int?
    private var nextSystemAudioRecoveryID = 0
    private var systemAudioRecoveryTask: Task<Void, Never>?
    private var lifecycleState: LifecycleState = .idle
    private var nextAttemptID = 0
    private var startInFlightAttemptID: Int?
    private var stopCleanupCompletedAttemptID: Int?
    private var stopSettlementWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeEventTarget: (attemptID: Int, target: EventSink)?

    private var eventContinuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
    private var cachedEvents: AsyncStream<MeetingAudioCaptureEvent>?

    public init(
        micProcessingMode: MeetingMicProcessingMode = .raw,
        sourceModeProvider: @escaping @Sendable () -> MeetingAudioSourceMode = { .microphoneAndSystem },
        sharedMicStream: SharedMicrophoneStream
    ) {
        self.microphoneCapture = MicrophoneCapture(sharedStream: sharedMicStream)
        self.micProcessingMode = micProcessingMode
        self.sourceModeProvider = sourceModeProvider
        self.systemAudioRecoveryDelays = Self.productionSystemAudioRecoveryDelays
        self.micHealthObserver = MeetingMicHealthTelemetryObserver()
        self.systemAudioCaptureFactory = {
            guard #available(macOS 14.2, *) else {
                throw MeetingAudioError.unsupportedPlatform
            }
            return SystemAudioStream()
        }
    }

    init(
        microphoneCaptureFactory: @escaping MeetingMicrophoneCaptureFactory,
        systemAudioCaptureFactory: @escaping @Sendable () throws -> any MeetingSystemAudioCapturing,
        micProcessingMode: MeetingMicProcessingMode = .raw,
        sourceModeProvider: @escaping @Sendable () -> MeetingAudioSourceMode = { .microphoneAndSystem },
        micHealthConfig: MeetingMicHealthMonitor.Config = .default,
        micHealthNowProvider: @escaping @Sendable () -> Date = { Date() },
        micHealthFeatureEnabled: Bool = AppFeatures.meetingCaptureReliabilityEnabled,
        systemAudioRecoveryDelays: [Duration]? = nil
    ) {
        self.microphoneCapture = microphoneCaptureFactory()
        self.systemAudioCaptureFactory = systemAudioCaptureFactory
        self.micProcessingMode = micProcessingMode
        self.sourceModeProvider = sourceModeProvider
        self.systemAudioRecoveryDelays =
            systemAudioRecoveryDelays
            ?? Self.productionSystemAudioRecoveryDelays
        self.micHealthObserver = MeetingMicHealthTelemetryObserver(
            config: micHealthConfig,
            nowProvider: micHealthNowProvider,
            featureEnabled: micHealthFeatureEnabled
        )
    }

    init(
        microphoneCapture: any MeetingMicrophoneCapturing,
        systemAudioCaptureFactory: @escaping @Sendable () throws -> any MeetingSystemAudioCapturing,
        micProcessingMode: MeetingMicProcessingMode = .raw,
        sourceModeProvider: @escaping @Sendable () -> MeetingAudioSourceMode = { .microphoneAndSystem },
        micHealthConfig: MeetingMicHealthMonitor.Config = .default,
        micHealthNowProvider: @escaping @Sendable () -> Date = { Date() },
        micHealthFeatureEnabled: Bool = AppFeatures.meetingCaptureReliabilityEnabled,
        systemAudioRecoveryDelays: [Duration]? = nil
    ) {
        self.microphoneCapture = microphoneCapture
        self.systemAudioCaptureFactory = systemAudioCaptureFactory
        self.micProcessingMode = micProcessingMode
        self.sourceModeProvider = sourceModeProvider
        self.systemAudioRecoveryDelays =
            systemAudioRecoveryDelays
            ?? Self.productionSystemAudioRecoveryDelays
        self.micHealthObserver = MeetingMicHealthTelemetryObserver(
            config: micHealthConfig,
            nowProvider: micHealthNowProvider,
            featureEnabled: micHealthFeatureEnabled
        )
    }

    public var events: AsyncStream<MeetingAudioCaptureEvent> {
        get async {
            if case .stopping = lifecycleState {
                await waitForStopSettlement()
            }
            return currentEventStream()
        }
    }

    private func currentEventStream() -> AsyncStream<MeetingAudioCaptureEvent> {
        if let cachedEvents {
            return cachedEvents
        }

        var continuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
        let stream = AsyncStream<MeetingAudioCaptureEvent>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        eventContinuation = continuation
        cachedEvents = stream
        return stream
    }

    public func start(sourceMode sourceModeOverride: MeetingAudioSourceMode? = nil) async throws
        -> MeetingAudioCaptureStartReport
    {
        if case .stopping = lifecycleState {
            await waitForStopSettlement()
        }
        _ = currentEventStream()
        let continuation = eventContinuation
        return try await start(sourceMode: sourceModeOverride) { event in
            continuation?.yield(event)
        }
    }

    public func start(
        sourceMode sourceModeOverride: MeetingAudioSourceMode? = nil,
        handler: @escaping EventHandler
    ) async throws -> MeetingAudioCaptureStartReport {
        if case .stopping = lifecycleState {
            await waitForStopSettlement()
        }
        guard lifecycleState == .idle else {
            throw MeetingAudioError.alreadyRunning
        }
        nextAttemptID += 1
        let attemptID = nextAttemptID
        lifecycleState = .starting(attemptID)
        startInFlightAttemptID = attemptID
        defer { settleStartAttemptIfOwned(attemptID) }
        let eventTarget = EventSink(handler: handler)
        activeEventTarget = (attemptID, eventTarget)

        let sourceMode = sourceModeOverride ?? sourceModeProvider()
        var microphoneStartReport: MeetingMicrophoneCaptureStartReport?
        var attemptedMicrophoneStart = false
        var systemCapture: (any MeetingSystemAudioCapturing)?
        var systemCaptureGeneration: Int?
        // Mic health compares microphone energy against system audio, so mic-only capture has no reference stream.
        micHealthObserver.start(
            observing: sourceMode.capturesMicrophone && sourceMode.capturesSystemAudio,
            attemptID: attemptID
        )

        do {
            if sourceMode.capturesSystemAudio {
                systemCapture = try systemAudioCaptureFactory()
                if let systemCapture {
                    systemCaptureGeneration = installSystemAudioCapture(systemCapture)
                }
            }

            if sourceMode.capturesMicrophone {
                attemptedMicrophoneStart = true
                microphoneStartReport = try await microphoneCapture.start(
                    processingMode: micProcessingMode,
                    handler: { [weak self] buffer, time in
                        guard let copy = Self.deepCopyBuffer(buffer) else {
                            Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioCaptureService")
                                .warning(
                                    "deepCopyBuffer nil for microphone capture: format=\(buffer.format.commonFormat.rawValue) rate=\(buffer.format.sampleRate) ch=\(buffer.format.channelCount) interleaved=\(buffer.format.isInterleaved) frames=\(buffer.frameLength)"
                                )
                            eventTarget.emit(
                                .error(
                                    .captureRuntimeFailure(
                                        "microphone buffer copy failed (format=\(buffer.format.commonFormat.rawValue) rate=\(buffer.format.sampleRate) channels=\(buffer.format.channelCount))"
                                    )
                                )
                            )
                            return
                        }
                        let healthEvents =
                            self?.micHealthObserver.observeMicrophoneBuffer(
                                copy,
                                attemptID: attemptID
                            ) ?? []
                        for healthEvent in healthEvents {
                            eventTarget.emit(.microphoneHealth(healthEvent))
                        }
                        eventTarget.emit(.microphoneBuffer(copy, time))
                    },
                    onStall: { error in
                        let event: MeetingAudioCaptureEvent =
                            sourceMode.capturesSystemAudio
                            ? .sourceInterrupted(source: .microphone, error: error)
                            : .error(error)
                        eventTarget.emit(event)
                    }
                )
                try validateStartStillCurrent(attemptID)
            }

            if let systemCapture, let systemCaptureGeneration {
                let startFailureSignal = SystemAudioStartFailureSignal()
                let callbacks = makeSystemAudioCallbacks(
                    attemptID: attemptID,
                    generation: systemCaptureGeneration,
                    sourceMode: sourceMode,
                    eventTarget: eventTarget,
                    startFailureSignal: startFailureSignal
                )
                try await systemCapture.start(
                    handler: callbacks.handler,
                    onStall: callbacks.stallObserver
                )
                if let startFailure = startFailureSignal.promoteToRunning() {
                    throw startFailure
                }
                try validateStartStillCurrent(attemptID)
            }
        } catch {
            let wasInterrupted = lifecycleState != .starting(attemptID)
            if lifecycleState == .starting(attemptID) {
                lifecycleState = .stopping(attemptID)
                retireEventTargetIfOwned(attemptID: attemptID)
                if let systemCaptureGeneration {
                    _ = takeSystemAudioCapture(generation: systemCaptureGeneration)
                }
                if attemptedMicrophoneStart {
                    await microphoneCapture.stop()
                }
                await systemCapture?.stop()
                markStopCleanupCompleted(attemptID: attemptID)
            }
            if wasInterrupted {
                throw CancellationError()
            }
            throw error
        }

        try validateStartStillCurrent(attemptID)
        lifecycleState = .running(attemptID)
        logger.info(
            "Meeting audio capture started source_mode=\(sourceMode.rawValue, privacy: .public) microphone_started=\(microphoneStartReport != nil, privacy: .public) requested_mic_mode=\(String(describing: microphoneStartReport?.requestedMode), privacy: .public) effective_mic_mode=\(microphoneStartReport?.effectiveMode.rawValue ?? "none", privacy: .public)"
        )
        return MeetingAudioCaptureStartReport(
            sourceMode: sourceMode,
            microphone: microphoneStartReport
        )
    }

    public func stop() async {
        guard let attemptID = lifecycleState.attemptID else { return }
        if case .stopping = lifecycleState {
            await waitForStopSettlement()
            return
        }

        lifecycleState = .stopping(attemptID)
        retireEventTargetIfOwned(attemptID: attemptID)
        let recoveryTask = systemAudioRecoveryTask
        recoveryTask?.cancel()
        let systemCapture = takeSystemAudioCapture()

        await microphoneCapture.stop()
        await systemCapture?.stop()
        await recoveryTask?.value

        markStopCleanupCompleted(attemptID: attemptID)
        if completeStopIfReady(attemptID: attemptID) {
            logger.info("Meeting audio capture stopped")
        } else {
            await waitForStopSettlement()
        }
    }

    private func installSystemAudioCapture(
        _ capture: any MeetingSystemAudioCapturing
    ) -> Int {
        assert(systemAudioCapture == nil)
        nextSystemAudioCaptureGeneration += 1
        let generation = nextSystemAudioCaptureGeneration
        systemAudioCapture = capture
        systemAudioCaptureGeneration = generation
        systemAudioCallbackGate.activate(generation: generation)
        return generation
    }

    private func takeSystemAudioCapture(
        generation expectedGeneration: Int? = nil
    ) -> (any MeetingSystemAudioCapturing)? {
        if let expectedGeneration, systemAudioCaptureGeneration != expectedGeneration {
            return nil
        }
        let capture = systemAudioCapture
        if let generation = systemAudioCaptureGeneration {
            systemAudioCallbackGate.invalidate(generation: generation)
        }
        systemAudioCapture = nil
        systemAudioCaptureGeneration = nil
        return capture
    }

    private func makeSystemAudioCallbacks(
        attemptID: Int,
        generation: Int,
        sourceMode: MeetingAudioSourceMode,
        eventTarget: EventSink,
        startFailureSignal: SystemAudioStartFailureSignal? = nil,
        recoverySignal: SystemAudioRecoveryAttemptSignal? = nil
    ) -> (
        handler: MeetingSystemAudioCapturing.AudioBufferHandler,
        stallObserver: MeetingSystemAudioCapturing.StallObserver
    ) {
        let callbackGate = systemAudioCallbackGate
        let micHealthObserver = micHealthObserver
        let reportFailure: @Sendable (MeetingAudioError) -> Void = { [weak self] error in
            guard callbackGate.isActive(generation: generation) else { return }
            if recoverySignal?.recordFailure(error) == true {
                return
            }
            if startFailureSignal?.recordFailure(error) == true {
                return
            }
            Task { [weak self] in
                await self?.handleSystemAudioFailure(
                    error,
                    attemptID: attemptID,
                    generation: generation,
                    sourceMode: sourceMode,
                    eventTarget: eventTarget
                )
            }
        }

        let handler: MeetingSystemAudioCapturing.AudioBufferHandler = { buffer, time in
            guard callbackGate.isActive(generation: generation) else { return }
            guard let copy = Self.deepCopyBuffer(buffer) else {
                Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioCaptureService")
                    .warning(
                        "deepCopyBuffer nil for system capture: format=\(buffer.format.commonFormat.rawValue) rate=\(buffer.format.sampleRate) ch=\(buffer.format.channelCount) interleaved=\(buffer.format.isInterleaved) frames=\(buffer.frameLength)"
                    )
                reportFailure(
                    .captureRuntimeFailure(
                        "system buffer copy failed (format=\(buffer.format.commonFormat.rawValue) rate=\(buffer.format.sampleRate) channels=\(buffer.format.channelCount))"
                    )
                )
                return
            }
            // Stop or a newer recovery generation may win while the copy is in
            // progress. Never publish a late buffer from the retired stream.
            guard callbackGate.isActive(generation: generation) else { return }
            let healthEvents = micHealthObserver.observeSystemBuffer(
                copy,
                attemptID: attemptID
            )
            for healthEvent in healthEvents {
                eventTarget.emit(.microphoneHealth(healthEvent))
            }
            eventTarget.emit(.systemBuffer(copy, time))
            recoverySignal?.recordFirstBuffer()
        }

        return (handler, reportFailure)
    }

    private func handleSystemAudioFailure(
        _ error: MeetingAudioError,
        attemptID: Int,
        generation: Int,
        sourceMode: MeetingAudioSourceMode,
        eventTarget: EventSink
    ) async {
        guard
            lifecycleState == .running(attemptID),
            systemAudioCaptureGeneration == generation
        else {
            return
        }

        // The active recovery attempt owns failures from its replacement
        // stream. Its first-buffer signal decides whether that attempt retries.
        guard activeSystemAudioRecoveryID == nil else { return }

        guard isRecoverableSystemAudioFailure(error) else {
            guard let failedCapture = takeSystemAudioCapture(generation: generation) else {
                return
            }
            nextSystemAudioRecoveryID += 1
            let teardownID = nextSystemAudioRecoveryID
            activeSystemAudioRecoveryID = teardownID
            systemAudioRecoveryTask = Task { [weak self] in
                await failedCapture.stop()
                await self?.completeTerminalSystemAudioFailureTeardown(
                    teardownID: teardownID,
                    attemptID: attemptID,
                    error: error,
                    sourceMode: sourceMode,
                    eventTarget: eventTarget
                )
            }
            return
        }

        nextSystemAudioRecoveryID += 1
        let recoveryID = nextSystemAudioRecoveryID
        activeSystemAudioRecoveryID = recoveryID
        eventTarget.emit(.sourceRecoveryStarted(source: .system, error: error))
        systemAudioRecoveryTask = Task { [weak self] in
            await self?.runSystemAudioRecovery(
                recoveryID: recoveryID,
                attemptID: attemptID,
                stalledGeneration: generation,
                sourceMode: sourceMode,
                originalError: error,
                eventTarget: eventTarget
            )
        }
    }

    private func runSystemAudioRecovery(
        recoveryID: Int,
        attemptID: Int,
        stalledGeneration: Int,
        sourceMode: MeetingAudioSourceMode,
        originalError: MeetingAudioError,
        eventTarget: EventSink
    ) async {
        defer { finishSystemAudioRecoveryIfOwned(recoveryID: recoveryID) }

        guard
            isSystemAudioRecoveryCurrent(recoveryID: recoveryID, attemptID: attemptID),
            let stalledCapture = takeSystemAudioCapture(generation: stalledGeneration)
        else {
            return
        }

        logger.warning("system_audio_recovery_started recovery_id=\(recoveryID, privacy: .public)")
        await stalledCapture.stop()

        for (attemptIndex, delay) in systemAudioRecoveryDelays.enumerated() {
            guard isSystemAudioRecoveryCurrent(recoveryID: recoveryID, attemptID: attemptID) else {
                return
            }

            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
            } catch {
                return
            }

            guard isSystemAudioRecoveryCurrent(recoveryID: recoveryID, attemptID: attemptID) else {
                return
            }

            let replacement: any MeetingSystemAudioCapturing
            do {
                replacement = try systemAudioCaptureFactory()
            } catch {
                logger.warning(
                    "system_audio_recovery_factory_failed recovery_id=\(recoveryID, privacy: .public) attempt=\(attemptIndex + 1, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                )
                continue
            }

            let replacementGeneration = installSystemAudioCapture(replacement)
            let signal = SystemAudioRecoveryAttemptSignal()
            let callbacks = makeSystemAudioCallbacks(
                attemptID: attemptID,
                generation: replacementGeneration,
                sourceMode: sourceMode,
                eventTarget: eventTarget,
                recoverySignal: signal
            )

            do {
                try await replacement.start(
                    handler: callbacks.handler,
                    onStall: callbacks.stallObserver
                )
            } catch {
                logger.warning(
                    "system_audio_recovery_start_failed recovery_id=\(recoveryID, privacy: .public) attempt=\(attemptIndex + 1, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                )
                if let ownedCapture = takeSystemAudioCapture(generation: replacementGeneration) {
                    await ownedCapture.stop()
                }
                continue
            }

            guard isSystemAudioRecoveryCurrent(recoveryID: recoveryID, attemptID: attemptID) else {
                if let ownedCapture = takeSystemAudioCapture(generation: replacementGeneration) {
                    await ownedCapture.stop()
                }
                return
            }

            let outcome = await withTaskCancellationHandler {
                await signal.waitForOutcome()
            } onCancel: {
                signal.cancel()
            }

            switch outcome {
            case .firstBuffer:
                guard
                    isSystemAudioRecoveryCurrent(recoveryID: recoveryID, attemptID: attemptID),
                    systemAudioCaptureGeneration == replacementGeneration
                else {
                    if let ownedCapture = takeSystemAudioCapture(generation: replacementGeneration) {
                        await ownedCapture.stop()
                    }
                    return
                }
                switch signal.promoteAfterFirstBuffer() {
                case .failed(let error):
                    logger.warning(
                        "system_audio_recovery_attempt_failed_after_first_buffer recovery_id=\(recoveryID, privacy: .public) attempt=\(attemptIndex + 1, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                    )
                    if let ownedCapture = takeSystemAudioCapture(generation: replacementGeneration) {
                        await ownedCapture.stop()
                    }
                    guard isRecoverableSystemAudioFailure(error) else {
                        guard
                            isSystemAudioRecoveryCurrent(
                                recoveryID: recoveryID,
                                attemptID: attemptID
                            )
                        else {
                            return
                        }
                        emitTerminalSystemAudioFailure(
                            error,
                            sourceMode: sourceMode,
                            eventTarget: eventTarget
                        )
                        return
                    }
                    continue
                case .unavailable:
                    if let ownedCapture = takeSystemAudioCapture(generation: replacementGeneration) {
                        await ownedCapture.stop()
                    }
                    return
                case .ready:
                    break
                }
                // Promotion is now atomic with callback classification: any
                // subsequent failure is routed as a fresh running-source loss.
                finishSystemAudioRecoveryIfOwned(recoveryID: recoveryID)
                logger.info(
                    "system_audio_recovery_succeeded recovery_id=\(recoveryID, privacy: .public) attempt=\(attemptIndex + 1, privacy: .public)"
                )
                eventTarget.emit(.sourceRecovered(source: .system))
                return

            case .failure(let error):
                logger.warning(
                    "system_audio_recovery_attempt_stalled recovery_id=\(recoveryID, privacy: .public) attempt=\(attemptIndex + 1, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                )
                if let ownedCapture = takeSystemAudioCapture(generation: replacementGeneration) {
                    await ownedCapture.stop()
                }
                guard isRecoverableSystemAudioFailure(error) else {
                    guard
                        isSystemAudioRecoveryCurrent(
                            recoveryID: recoveryID,
                            attemptID: attemptID
                        )
                    else {
                        return
                    }
                    emitTerminalSystemAudioFailure(
                        error,
                        sourceMode: sourceMode,
                        eventTarget: eventTarget
                    )
                    return
                }

            case nil:
                if let ownedCapture = takeSystemAudioCapture(generation: replacementGeneration) {
                    await ownedCapture.stop()
                }
                return
            }
        }

        guard isSystemAudioRecoveryCurrent(recoveryID: recoveryID, attemptID: attemptID) else {
            return
        }
        logger.error("system_audio_recovery_exhausted recovery_id=\(recoveryID, privacy: .public)")
        emitTerminalSystemAudioFailure(
            originalError,
            sourceMode: sourceMode,
            eventTarget: eventTarget
        )
    }

    private func isSystemAudioRecoveryCurrent(recoveryID: Int, attemptID: Int) -> Bool {
        activeSystemAudioRecoveryID == recoveryID && lifecycleState == .running(attemptID)
    }

    private func finishSystemAudioRecoveryIfOwned(recoveryID: Int) {
        guard activeSystemAudioRecoveryID == recoveryID else { return }
        activeSystemAudioRecoveryID = nil
        systemAudioRecoveryTask = nil
    }

    private func isRecoverableSystemAudioFailure(_ error: MeetingAudioError) -> Bool {
        switch error {
        case .systemAudioStalled, .systemAudioStreamStopped:
            return true
        default:
            return false
        }
    }

    private func completeTerminalSystemAudioFailureTeardown(
        teardownID: Int,
        attemptID: Int,
        error: MeetingAudioError,
        sourceMode: MeetingAudioSourceMode,
        eventTarget: EventSink
    ) {
        defer { finishSystemAudioRecoveryIfOwned(recoveryID: teardownID) }
        guard
            isSystemAudioRecoveryCurrent(
                recoveryID: teardownID,
                attemptID: attemptID
            )
        else {
            return
        }
        emitTerminalSystemAudioFailure(
            error,
            sourceMode: sourceMode,
            eventTarget: eventTarget
        )
    }

    private func emitTerminalSystemAudioFailure(
        _ error: MeetingAudioError,
        sourceMode: MeetingAudioSourceMode,
        eventTarget: EventSink
    ) {
        let event: MeetingAudioCaptureEvent =
            sourceMode.capturesMicrophone
            ? .sourceInterrupted(source: .system, error: error)
            : .error(error)
        eventTarget.emit(event)
    }

    private func validateStartStillCurrent(_ attemptID: Int) throws {
        guard lifecycleState == .starting(attemptID) else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    @discardableResult
    private func completeStopIfOwned(attemptID: Int) -> Bool {
        guard lifecycleState == .stopping(attemptID) else { return false }
        systemAudioCallbackGate.invalidateAll()
        systemAudioCaptureGeneration = nil
        activeSystemAudioRecoveryID = nil
        systemAudioRecoveryTask = nil
        stopCleanupCompletedAttemptID = nil
        finishEventStream()
        retireEventTargetIfOwned(attemptID: attemptID)
        micHealthObserver.stop(attemptID: attemptID)
        lifecycleState = .idle
        let waiters = stopSettlementWaiters
        stopSettlementWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return true
    }

    private func retireEventTargetIfOwned(attemptID: Int) {
        guard activeEventTarget?.attemptID == attemptID else { return }
        activeEventTarget?.target.retire()
        activeEventTarget = nil
    }

    private func settleStartAttemptIfOwned(_ attemptID: Int) {
        guard startInFlightAttemptID == attemptID else { return }
        startInFlightAttemptID = nil
        _ = completeStopIfReady(attemptID: attemptID)
    }

    private func markStopCleanupCompleted(attemptID: Int) {
        guard lifecycleState == .stopping(attemptID) else { return }
        stopCleanupCompletedAttemptID = attemptID
    }

    @discardableResult
    private func completeStopIfReady(attemptID: Int) -> Bool {
        guard
            lifecycleState == .stopping(attemptID),
            startInFlightAttemptID != attemptID,
            stopCleanupCompletedAttemptID == attemptID
        else {
            return false
        }
        return completeStopIfOwned(attemptID: attemptID)
    }

    private func waitForStopSettlement() async {
        guard case .stopping = lifecycleState else { return }
        await withCheckedContinuation { continuation in
            if case .stopping = lifecycleState {
                stopSettlementWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    private func finishEventStream() {
        eventContinuation?.finish()
        eventContinuation = nil
        cachedEvents = nil
    }

    private static func deepCopyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format: AVAudioFormat
        if buffer.format.isInterleaved {
            guard
                let nonInterleavedFormat = AVAudioFormat(
                    commonFormat: buffer.format.commonFormat,
                    sampleRate: buffer.format.sampleRate,
                    channels: buffer.format.channelCount,
                    interleaved: false
                )
            else {
                return nil
            }
            format = nonInterleavedFormat
        } else {
            // Preserve channel layout details from Core Audio (for example VPIO
            // multichannel formats) instead of reconstructing from channel count.
            format = buffer.format
        }

        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else {
            return nil
        }

        copy.frameLength = buffer.frameLength
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)

        if buffer.format.isInterleaved {
            let audioBuffer = buffer.audioBufferList.pointee.mBuffers
            guard let sourceData = audioBuffer.mData else { return nil }

            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                guard let destination = copy.floatChannelData else { return nil }
                let source = sourceData.assumingMemoryBound(to: Float.self)
                for frameIndex in 0..<frameCount {
                    for channelIndex in 0..<channelCount {
                        destination[channelIndex][frameIndex] = source[(frameIndex * channelCount) + channelIndex]
                    }
                }
            case .pcmFormatInt16:
                guard let destination = copy.int16ChannelData else { return nil }
                let source = sourceData.assumingMemoryBound(to: Int16.self)
                for frameIndex in 0..<frameCount {
                    for channelIndex in 0..<channelCount {
                        destination[channelIndex][frameIndex] = source[(frameIndex * channelCount) + channelIndex]
                    }
                }
            case .pcmFormatInt32:
                guard let destination = copy.int32ChannelData else { return nil }
                let source = sourceData.assumingMemoryBound(to: Int32.self)
                for frameIndex in 0..<frameCount {
                    for channelIndex in 0..<channelCount {
                        destination[channelIndex][frameIndex] = source[(frameIndex * channelCount) + channelIndex]
                    }
                }
            default:
                return nil
            }
        } else if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<channelCount {
                dst[channel].update(from: src[channel], count: frameCount)
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0..<channelCount {
                dst[channel].update(from: src[channel], count: frameCount)
            }
        } else if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            for channel in 0..<channelCount {
                dst[channel].update(from: src[channel], count: frameCount)
            }
        } else {
            return nil
        }

        return copy
    }
}

private final class SystemAudioCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGeneration: Int?

    func activate(generation: Int) {
        lock.withLock {
            activeGeneration = generation
        }
    }

    func invalidate(generation: Int) {
        lock.withLock {
            guard activeGeneration == generation else { return }
            activeGeneration = nil
        }
    }

    func invalidateAll() {
        lock.withLock {
            activeGeneration = nil
        }
    }

    func isActive(generation: Int) -> Bool {
        lock.withLock { activeGeneration == generation }
    }
}

private final class SystemAudioStartFailureSignal: @unchecked Sendable {
    private enum State {
        case accepting(MeetingAudioError?)
        case promoted
    }

    private let lock = NSLock()
    private var state = State.accepting(nil)

    /// Returns true while the initial start attempt owns the failure. Promotion
    /// is atomic with callback routing, so a later failure enters the running
    /// generation's normal recovery or terminal path.
    func recordFailure(_ error: MeetingAudioError) -> Bool {
        lock.withLock {
            switch state {
            case .accepting(nil):
                state = .accepting(error)
                return true
            case .accepting:
                return true
            case .promoted:
                return false
            }
        }
    }

    func promoteToRunning() -> MeetingAudioError? {
        lock.withLock {
            guard case .accepting(let pendingFailure) = state else {
                return nil
            }
            state = .promoted
            return pendingFailure
        }
    }
}

private final class SystemAudioRecoveryAttemptSignal: @unchecked Sendable {
    enum Outcome: Sendable {
        case firstBuffer
        case failure(MeetingAudioError)
    }

    enum Promotion {
        case ready
        case failed(MeetingAudioError)
        case unavailable
    }

    private enum State {
        case awaiting
        case firstBuffer(pendingFailure: MeetingAudioError?)
        case failure
        case promoted
        case cancelled
    }

    private let lock = NSLock()
    private let stream: AsyncStream<Outcome>
    private let continuation: AsyncStream<Outcome>.Continuation
    private var state = State.awaiting

    init() {
        var capturedContinuation: AsyncStream<Outcome>.Continuation?
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func recordFirstBuffer() {
        let shouldResolve = lock.withLock { () -> Bool in
            guard case .awaiting = state else { return false }
            state = .firstBuffer(pendingFailure: nil)
            return true
        }
        guard shouldResolve else { return }
        continuation.yield(.firstBuffer)
        continuation.finish()
    }

    /// Returns true while this recovery attempt still owns the failure. A
    /// failure racing just behind the first buffer is retained until the actor
    /// promotes that buffer; failures after promotion return false and enter a
    /// fresh recovery episode through the normal callback path.
    func recordFailure(_ error: MeetingAudioError) -> Bool {
        enum Action {
            case yield
            case retained
            case forward
        }
        let action = lock.withLock { () -> Action in
            switch state {
            case .awaiting:
                state = .failure
                return .yield
            case .firstBuffer(let pendingFailure):
                if pendingFailure == nil {
                    state = .firstBuffer(pendingFailure: error)
                }
                return .retained
            case .failure:
                return .retained
            case .promoted, .cancelled:
                return .forward
            }
        }
        switch action {
        case .yield:
            continuation.yield(.failure(error))
            continuation.finish()
            return true
        case .retained:
            return true
        case .forward:
            return false
        }
    }

    func promoteAfterFirstBuffer() -> Promotion {
        lock.withLock {
            guard case .firstBuffer(let pendingFailure) = state else {
                return .unavailable
            }
            state = .promoted
            if let pendingFailure {
                return .failed(pendingFailure)
            }
            return .ready
        }
    }

    func cancel() {
        let shouldFinish = lock.withLock {
            switch state {
            case .awaiting:
                state = .cancelled
                return true
            case .firstBuffer, .failure:
                state = .cancelled
                return false
            case .promoted, .cancelled:
                return false
            }
        }
        guard shouldFinish else { return }
        continuation.finish()
    }

    func waitForOutcome() async -> Outcome? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}

private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: MeetingAudioCaptureService.EventHandler
    private var isActive = true

    init(handler: @escaping MeetingAudioCaptureService.EventHandler) {
        self.handler = handler
    }

    func retire() {
        lock.withLock { isActive = false }
    }

    func emit(_ event: MeetingAudioCaptureEvent) {
        let currentHandler = lock.withLock {
            isActive ? handler : nil
        }
        currentHandler?(event)
    }
}

private final class MeetingMicHealthTelemetryObserver: @unchecked Sendable {
    private struct StallSummary: Sendable {
        let stallCount: Int
        let totalStalledMs: Int

        var totalStalledSeconds: Double {
            Double(totalStalledMs) / 1000.0
        }
    }

    private enum StallTelemetryEmission: Sendable {
        case full(
            signature: MeetingMicHealthMonitor.StallSignature,
            elapsedMs: Int,
            summary: StallSummary
        )
        case summary(StallSummary)
    }

    private static let summaryInterval = 100

    private let lock = NSLock()
    private let config: MeetingMicHealthMonitor.Config
    private let nowProvider: @Sendable () -> Date
    private let featureEnabled: Bool
    private var monitor: MeetingMicHealthMonitor
    private var isObserving = false
    private var activeAttemptID: Int?
    private var didReportFirstStall = false
    private var stallCount = 0
    private var totalStalledMs = 0
    private var lastSummaryStallCount = 0

    init(
        config: MeetingMicHealthMonitor.Config = .default,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        featureEnabled: Bool = AppFeatures.meetingCaptureReliabilityEnabled
    ) {
        self.config = config
        self.nowProvider = nowProvider
        self.featureEnabled = featureEnabled
        self.monitor = MeetingMicHealthMonitor(config: config)
    }

    func start(observing sourceIncludesMicrophone: Bool, attemptID: Int) {
        lock.withLock {
            monitor = MeetingMicHealthMonitor(config: config)
            resetTelemetryCountersLocked()
            activeAttemptID = attemptID
            isObserving = featureEnabled && sourceIncludesMicrophone
        }
    }

    func stop(attemptID: Int) {
        let summary = lock.withLock { () -> StallSummary? in
            guard activeAttemptID == attemptID else { return nil }
            let summary = pendingSummaryLocked()
            monitor.reset()
            resetTelemetryCountersLocked()
            isObserving = false
            activeAttemptID = nil
            return summary
        }
        if let summary {
            sendSummary(summary)
        }
    }

    func observeMicrophoneBuffer(
        _ buffer: AVAudioPCMBuffer,
        attemptID: Int
    ) -> [MeetingMicHealthMonitor.HealthEvent] {
        guard shouldObserve(attemptID: attemptID) else { return [] }
        return observe(
            micSignal: .init(isNonSilent: buffer.rmsLevel >= config.nonSilentLevelThreshold),
            systemSignal: nil,
            attemptID: attemptID
        )
    }

    func observeSystemBuffer(
        _ buffer: AVAudioPCMBuffer,
        attemptID: Int
    ) -> [MeetingMicHealthMonitor.HealthEvent] {
        guard shouldObserve(attemptID: attemptID) else { return [] }
        return observe(
            micSignal: nil,
            systemSignal: .init(isNonSilent: buffer.rmsLevel >= config.nonSilentLevelThreshold),
            attemptID: attemptID
        )
    }

    private func shouldObserve(attemptID: Int) -> Bool {
        lock.withLock { isObserving && activeAttemptID == attemptID }
    }

    private func observe(
        micSignal: MeetingMicHealthMonitor.AudioSignal?,
        systemSignal: MeetingMicHealthMonitor.AudioSignal?,
        attemptID: Int
    ) -> [MeetingMicHealthMonitor.HealthEvent] {
        let now = nowProvider()
        // Resolve emissions inside the lock (the monitor state and counters are both
        // mutated from the audio callback thread), then emit telemetry outside it so
        // `Telemetry.send` never runs under the lock.
        let observed = lock.withLock {
            guard isObserving, activeAttemptID == attemptID else {
                return (
                    events: [MeetingMicHealthMonitor.HealthEvent](),
                    emissions: [StallTelemetryEmission]()
                )
            }
            let events = monitor.ingest(micSignal: micSignal, systemSignal: systemSignal, now: now)
            var emissions: [StallTelemetryEmission] = []
            for event in events {
                // ADR-025 Phase A emits only detection telemetry; warning and recovery
                // surfaces consume `.recovered` in later phases.
                guard case let .stallSuspected(signature, rawElapsedMs) = event else { continue }
                let elapsedMs = max(0, rawElapsedMs)
                stallCount += 1
                totalStalledMs += elapsedMs
                let summary = StallSummary(stallCount: stallCount, totalStalledMs: totalStalledMs)
                if !didReportFirstStall {
                    didReportFirstStall = true
                    emissions.append(.full(signature: signature, elapsedMs: elapsedMs, summary: summary))
                } else if stallCount.isMultiple(of: Self.summaryInterval) {
                    lastSummaryStallCount = stallCount
                    emissions.append(.summary(summary))
                }
            }
            return (events, emissions)
        }

        for emission in observed.emissions {
            send(emission)
        }
        return observed.events
    }

    private func pendingSummaryLocked() -> StallSummary? {
        guard stallCount > 1, lastSummaryStallCount != stallCount else { return nil }
        lastSummaryStallCount = stallCount
        return StallSummary(stallCount: stallCount, totalStalledMs: totalStalledMs)
    }

    private func resetTelemetryCountersLocked() {
        didReportFirstStall = false
        stallCount = 0
        totalStalledMs = 0
        lastSummaryStallCount = 0
    }

    private func send(_ emission: StallTelemetryEmission) {
        switch emission {
        case .full(let signature, let elapsedMs, let summary):
            Telemetry.send(
                .micStallDetected(
                    signature: .init(signature),
                    elapsedMs: elapsedMs,
                    stallCount: summary.stallCount
                ))
        case .summary(let summary):
            sendSummary(summary)
        }
    }

    private func sendSummary(_ summary: StallSummary) {
        Telemetry.send(
            .micStallDetected(
                stallCount: summary.stallCount,
                totalStalledSeconds: summary.totalStalledSeconds
            ))
    }
}

extension AVAudioPCMBuffer {
    public var rmsLevel: Float {
        if let channelData = floatChannelData, frameLength > 0 {
            let samples = channelData[0]
            var sum: Float = 0
            for index in 0..<Int(frameLength) {
                sum += samples[index] * samples[index]
            }
            return min(1.0, sqrt(sum / Float(frameLength)) * 10)
        }

        if let channelData = int16ChannelData, frameLength > 0 {
            let samples = channelData[0]
            var sum: Float = 0
            for index in 0..<Int(frameLength) {
                let normalized = Float(samples[index]) / Float(Int16.max)
                sum += normalized * normalized
            }
            return min(1.0, sqrt(sum / Float(frameLength)) * 10)
        }

        if let channelData = int32ChannelData, frameLength > 0 {
            let samples = channelData[0]
            var sum: Float = 0
            for index in 0..<Int(frameLength) {
                let normalized = Float(samples[index]) / Float(Int32.max)
                sum += normalized * normalized
            }
            return min(1.0, sqrt(sum / Float(frameLength)) * 10)
        }

        return 0
    }
}

extension MeetingAudioCaptureService: MeetingAudioCapturing {}
