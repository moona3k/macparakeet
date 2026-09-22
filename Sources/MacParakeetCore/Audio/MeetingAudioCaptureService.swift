import Foundation
import OSLog
@preconcurrency import AVFoundation

public enum MeetingAudioCaptureEvent: Sendable {
    case captureStarting(sourceMode: MeetingAudioSourceMode)
    case sourceStartupState(source: AudioSource, state: MeetingAudioCaptureSourceStartupState)
    case microphoneStarted(report: MeetingMicrophoneCaptureStartReport)
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
    typealias DiagnosticSink = @Sendable (String) -> Void

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
    private let startupTimeout: Duration
    private let diagnosticSink: DiagnosticSink
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
    private var initialSystemStartSignal: SystemAudioStartFailureSignal?
    private var nextSystemAudioCaptureGeneration = 0
    private var activeSystemAudioRecoveryID: Int?
    private var nextSystemAudioRecoveryID = 0
    private var systemAudioRecoveryTask: Task<Void, Never>?
    private var initialSystemCleanup: (attemptID: Int, task: Task<Void, Never>)?
    private var lifecycleState: LifecycleState = .idle
    private var nextAttemptID = 0
    private var stopSettlementWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeEventTarget: (attemptID: Int, target: EventSink)?
    private var startupSignal: MeetingCaptureStartupSignal?
    private var microphoneLease: MicrophoneLease?

    /// A native microphone call may outlive its meeting. Retain the one shared
    /// consumer until start AND cleanup settle; replacement meetings can still
    /// own independent system capture while this lease remains occupied.
    private struct MicrophoneLease {
        let attemptID: Int
        var startTask: Task<Void, Never>?
        var stopTask: Task<Void, Never>?
        var startSettled = false
        var stopSettled = false
        var retired = false
        var stopGeneration = 0
    }

    private var eventContinuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
    private var cachedEvents: AsyncStream<MeetingAudioCaptureEvent>?

    /// Native setup completion remains distinct from frame-based readiness.
    /// Internal diagnostics and lifecycle tests can observe the actual boundary.
    var isSystemAudioStartPending: Bool { initialSystemStartSignal?.isAwaitingPromotion ?? false }

    public init(
        micProcessingMode: MeetingMicProcessingMode = .raw,
        sourceModeProvider: @escaping @Sendable () -> MeetingAudioSourceMode = { .microphoneAndSystem },
        sharedMicStream: SharedMicrophoneStream
    ) {
        self.microphoneCapture = MicrophoneCapture(sharedStream: sharedMicStream)
        self.micProcessingMode = micProcessingMode
        self.sourceModeProvider = sourceModeProvider
        self.systemAudioRecoveryDelays = Self.productionSystemAudioRecoveryDelays
        self.startupTimeout = .seconds(12)
        self.diagnosticSink = { AudioCaptureDiagnostics.append($0) }
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
        systemAudioRecoveryDelays: [Duration]? = nil,
        startupTimeout: Duration = .seconds(12),
        diagnosticSink: @escaping DiagnosticSink = { AudioCaptureDiagnostics.append($0) }
    ) {
        self.microphoneCapture = microphoneCaptureFactory()
        self.systemAudioCaptureFactory = systemAudioCaptureFactory
        self.micProcessingMode = micProcessingMode
        self.sourceModeProvider = sourceModeProvider
        self.startupTimeout = startupTimeout
        self.systemAudioRecoveryDelays =
            systemAudioRecoveryDelays
            ?? Self.productionSystemAudioRecoveryDelays
        self.diagnosticSink = diagnosticSink
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
        systemAudioRecoveryDelays: [Duration]? = nil,
        startupTimeout: Duration = .seconds(12),
        diagnosticSink: @escaping DiagnosticSink = { AudioCaptureDiagnostics.append($0) }
    ) {
        self.microphoneCapture = microphoneCapture
        self.systemAudioCaptureFactory = systemAudioCaptureFactory
        self.micProcessingMode = micProcessingMode
        self.sourceModeProvider = sourceModeProvider
        self.startupTimeout = startupTimeout
        self.systemAudioRecoveryDelays =
            systemAudioRecoveryDelays
            ?? Self.productionSystemAudioRecoveryDelays
        self.diagnosticSink = diagnosticSink
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
        let eventTarget = EventSink(handler: handler)
        activeEventTarget = (attemptID, eventTarget)
        let sourceMode = sourceModeOverride ?? sourceModeProvider()
        let signal = MeetingCaptureStartupSignal(sourceMode: sourceMode, eventTarget: eventTarget)
        startupSignal = signal
        eventTarget.emit(.captureStarting(sourceMode: sourceMode))
        signal.publishInitialStates()
        signal.scheduleDeadline(after: startupTimeout)
        micHealthObserver.start(
            observing: sourceMode.capturesMicrophone && sourceMode.capturesSystemAudio,
            attemptID: attemptID
        )

        if sourceMode.capturesMicrophone {
            if microphoneLease == nil {
                microphoneLease = MicrophoneLease(attemptID: attemptID)
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.runMicrophoneStart(
                        attemptID: attemptID,
                        sourceMode: sourceMode,
                        eventTarget: eventTarget,
                        signal: signal
                    )
                }
                microphoneLease?.startTask = task
            } else {
                signal.recordFailure(source: .microphone, error: .microphoneCleanupPending)
            }
        }
        if sourceMode.capturesSystemAudio {
            do {
                let capture = try systemAudioCaptureFactory()
                let generation = installSystemAudioCapture(capture)
                let failureSignal = SystemAudioStartFailureSignal()
                initialSystemStartSignal = failureSignal
                Task { [weak self] in
                    await self?.runSystemAudioStart(
                        capture: capture,
                        generation: generation,
                        attemptID: attemptID,
                        sourceMode: sourceMode,
                        eventTarget: eventTarget,
                        signal: signal,
                        failureSignal: failureSignal
                    )
                }
            } catch {
                signal.recordFailure(source: .system, error: Self.captureError(error))
            }
        }

        do {
            try await signal.waitForAudio()
            try validateStartStillCurrent(attemptID)
            lifecycleState = .running(attemptID)
            let report = signal.report
            logger.info(
                "Meeting audio capture started source_mode=\(sourceMode.rawValue, privacy: .public) microphone_started=\(report.microphoneStarted, privacy: .public)"
            )
            return report
        } catch {
            // Stop retires this attempt and releases its waiter independently
            // of native startup. A stale result never stops a newer session.
            if lifecycleState == .starting(attemptID) {
                await stop()
                throw error
            }
            throw CancellationError()
        }
    }

    private func runMicrophoneStart(
        attemptID: Int,
        sourceMode: MeetingAudioSourceMode,
        eventTarget: EventSink,
        signal: MeetingCaptureStartupSignal
    ) async {
        guard microphoneLease?.attemptID == attemptID else { return }
        guard isCaptureAttemptActive(attemptID), microphoneLease?.retired == false else {
            microphoneLease?.startSettled = true
            releaseMicrophoneLeaseIfSettled(attemptID: attemptID)
            return
        }
        let healthObserver = micHealthObserver
        do {
            let report = try await microphoneCapture.start(
                processingMode: micProcessingMode,
                handler: { buffer, time in
                    guard eventTarget.isAcceptingEvents, signal.acceptsBuffers(from: .microphone) else { return }
                    guard Self.hasUsableFrames(buffer) else { return }
                    guard let copy = Self.deepCopyBuffer(buffer) else {
                        let error = MeetingAudioError.captureRuntimeFailure("microphone buffer copy failed")
                        signal.recordFailure(source: .microphone, error: error)
                        return
                    }
                    let healthEvents = healthObserver.observeMicrophoneBuffer(copy, attemptID: attemptID)
                    signal.deliverBuffer(
                        source: .microphone,
                        event: .microphoneBuffer(copy, time),
                        healthEvents: healthEvents
                    )
                },
                onStall: { error in
                    signal.recordFailure(source: .microphone, error: error)
                }
            )
            guard microphoneLease?.attemptID == attemptID else { return }
            microphoneLease?.startSettled = true
            if isCaptureAttemptActive(attemptID), microphoneLease?.retired == false {
                signal.recordMicrophoneReport(report)
            } else {
                // An async start may begin after an early stop observed idle.
                // Re-stop a successful retired start before releasing its lease.
                requestMicrophoneStop(attemptID: attemptID, repeatCleanup: true)
            }
        } catch {
            guard microphoneLease?.attemptID == attemptID else { return }
            microphoneLease?.startSettled = true
            if isCaptureAttemptActive(attemptID), microphoneLease?.retired == false {
                signal.recordFailure(source: .microphone, error: Self.captureError(error))
                requestMicrophoneStop(attemptID: attemptID)
            }
        }
        releaseMicrophoneLeaseIfSettled(attemptID: attemptID)
    }

    private func runSystemAudioStart(
        capture: any MeetingSystemAudioCapturing,
        generation: Int,
        attemptID: Int,
        sourceMode: MeetingAudioSourceMode,
        eventTarget: EventSink,
        signal: MeetingCaptureStartupSignal,
        failureSignal: SystemAudioStartFailureSignal
    ) async {
        defer {
            if initialSystemStartSignal === failureSignal { initialSystemStartSignal = nil }
        }
        guard isCaptureAttemptActive(attemptID), systemAudioCaptureGeneration == generation else { return }
        let callbacks = makeSystemAudioCallbacks(
            attemptID: attemptID,
            generation: generation,
            sourceMode: sourceMode,
            eventTarget: eventTarget,
            startFailureSignal: failureSignal,
            startupSignal: signal
        )
        do {
            try await capture.start(handler: callbacks.handler, onStall: callbacks.stallObserver)
            guard isCaptureAttemptActive(attemptID), systemAudioCaptureGeneration == generation else {
                await capture.stop()
                return
            }
            if let failure = failureSignal.promoteToRunning() {
                signal.recordFailure(source: .system, error: failure)
                if let failedCapture = takeSystemAudioCapture(generation: generation) {
                    await stopFailedInitialSystemCapture(failedCapture, attemptID: attemptID)
                }
            }
        } catch {
            guard isCaptureAttemptActive(attemptID), systemAudioCaptureGeneration == generation else {
                await capture.stop()
                return
            }
            signal.recordFailure(source: .system, error: Self.captureError(error))
            if let failedCapture = takeSystemAudioCapture(generation: generation) {
                await stopFailedInitialSystemCapture(failedCapture, attemptID: attemptID)
            }
        }
    }

    private func isCaptureAttemptActive(_ attemptID: Int) -> Bool {
        lifecycleState == .starting(attemptID) || lifecycleState == .running(attemptID)
    }

    private func stopFailedInitialSystemCapture(
        _ capture: any MeetingSystemAudioCapturing,
        attemptID: Int
    ) async {
        let task = Task { await capture.stop() }
        initialSystemCleanup = (attemptID, task)
        await task.value
        if initialSystemCleanup?.attemptID == attemptID {
            initialSystemCleanup = nil
        }
    }

    private static func captureError(_ error: Error) -> MeetingAudioError {
        (error as? MeetingAudioError) ?? .captureRuntimeFailure(error.localizedDescription)
    }

    private func requestMicrophoneStop(attemptID: Int, repeatCleanup: Bool = false) {
        guard microphoneLease?.attemptID == attemptID else { return }
        microphoneLease?.retired = true
        guard repeatCleanup || microphoneLease?.stopTask == nil else { return }
        microphoneLease?.stopSettled = false
        microphoneLease?.stopGeneration += 1
        guard let generation = microphoneLease?.stopGeneration else { return }
        let capture = microphoneCapture
        microphoneLease?.stopTask = Task { [weak self] in
            await capture.stop()
            await self?.microphoneStopSettled(attemptID: attemptID, generation: generation)
        }
    }

    private func microphoneStopSettled(attemptID: Int, generation: Int) {
        guard microphoneLease?.attemptID == attemptID,
            microphoneLease?.stopGeneration == generation
        else { return }
        microphoneLease?.stopSettled = true
        releaseMicrophoneLeaseIfSettled(attemptID: attemptID)
    }

    private func releaseMicrophoneLeaseIfSettled(attemptID: Int) {
        guard let lease = microphoneLease,
            lease.attemptID == attemptID, lease.startSettled, lease.stopSettled
        else { return }
        microphoneLease = nil
    }

    public func stop() async {
        guard let attemptID = lifecycleState.attemptID else { return }
        if case .stopping = lifecycleState {
            await waitForStopSettlement()
            return
        }

        lifecycleState = .stopping(attemptID)
        retireEventTargetIfOwned(attemptID: attemptID)
        startupSignal?.retire()
        startupSignal = nil
        let recoveryTask = systemAudioRecoveryTask
        recoveryTask?.cancel()
        let systemCapture = takeSystemAudioCapture()
        let systemCleanup = initialSystemCleanup?.task
        requestMicrophoneStop(attemptID: attemptID)
        await systemCapture?.stop()
        await systemCleanup?.value
        await recoveryTask?.value
        if completeStopIfOwned(attemptID: attemptID) {
            logger.info("Meeting audio capture stopped")
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
        initialSystemStartSignal = nil
        return capture
    }

    private func makeSystemAudioCallbacks(
        attemptID: Int,
        generation: Int,
        sourceMode: MeetingAudioSourceMode,
        eventTarget: EventSink,
        startFailureSignal: SystemAudioStartFailureSignal? = nil,
        startupSignal: MeetingCaptureStartupSignal? = nil,
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
                startupSignal?.recordFailure(source: .system, error: error)
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
            guard callbackGate.isActive(generation: generation), eventTarget.isAcceptingEvents,
                startupSignal?.acceptsBuffers(from: .system) != false
            else { return }
            guard Self.hasUsableFrames(buffer) else { return }
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
            if let startupSignal {
                startupSignal.deliverBuffer(
                    source: .system,
                    event: .systemBuffer(copy, time),
                    healthEvents: healthEvents
                )
            } else {
                for healthEvent in healthEvents {
                    eventTarget.emit(.microphoneHealth(healthEvent))
                }
                eventTarget.emit(.systemBuffer(copy, time))
            }
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
            isCaptureAttemptActive(attemptID),
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
        diagnosticSink(
            "system_audio_recovery_started recovery_id=\(recoveryID) \(AudioCaptureDiagnostics.errorFields(originalError))"
        )
        await stalledCapture.stop()

        for (attemptIndex, delay) in systemAudioRecoveryDelays.enumerated() {
            let attempt = attemptIndex + 1
            guard isSystemAudioRecoveryCurrent(recoveryID: recoveryID, attemptID: attemptID) else {
                logSystemAudioRecoveryCancellation(
                    recoveryID: recoveryID,
                    attempt: attempt,
                    phase: "before_attempt"
                )
                return
            }

            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
            } catch {
                logSystemAudioRecoveryCancellation(
                    recoveryID: recoveryID,
                    attempt: attempt,
                    phase: "retry_delay"
                )
                return
            }

            guard isSystemAudioRecoveryCurrent(recoveryID: recoveryID, attemptID: attemptID) else {
                logSystemAudioRecoveryCancellation(
                    recoveryID: recoveryID,
                    attempt: attempt,
                    phase: "before_factory"
                )
                return
            }

            diagnosticSink(
                "system_audio_recovery_attempt_started recovery_id=\(recoveryID) attempt=\(attempt)"
            )

            let replacement: any MeetingSystemAudioCapturing
            do {
                replacement = try systemAudioCaptureFactory()
            } catch {
                logger.warning(
                    "system_audio_recovery_factory_failed recovery_id=\(recoveryID, privacy: .public) attempt=\(attemptIndex + 1, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                )
                diagnosticSink(
                    "system_audio_recovery_factory_failed recovery_id=\(recoveryID) attempt=\(attempt) \(AudioCaptureDiagnostics.errorFields(error))"
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
                startupSignal: startupSignal,
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
                diagnosticSink(
                    "system_audio_recovery_start_failed recovery_id=\(recoveryID) attempt=\(attempt) \(AudioCaptureDiagnostics.errorFields(error))"
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
                logSystemAudioRecoveryCancellation(
                    recoveryID: recoveryID,
                    attempt: attempt,
                    phase: "after_start"
                )
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
                    logSystemAudioRecoveryCancellation(
                        recoveryID: recoveryID,
                        attempt: attempt,
                        phase: "first_buffer_promotion"
                    )
                    return
                }
                switch signal.promoteAfterFirstBuffer() {
                case .failed(let error):
                    logger.warning(
                        "system_audio_recovery_attempt_failed_after_first_buffer recovery_id=\(recoveryID, privacy: .public) attempt=\(attemptIndex + 1, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                    )
                    diagnosticSink(
                        "system_audio_recovery_attempt_failed_after_first_buffer recovery_id=\(recoveryID) attempt=\(attempt) \(AudioCaptureDiagnostics.errorFields(error))"
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
                    logSystemAudioRecoveryCancellation(
                        recoveryID: recoveryID,
                        attempt: attempt,
                        phase: "first_buffer_unavailable"
                    )
                    return
                case .ready:
                    break
                }
                diagnosticSink(
                    "system_audio_recovery_first_buffer recovery_id=\(recoveryID) attempt=\(attempt)"
                )
                startupSignal?.recordRecoveredSource(.system)
                // Promotion is now atomic with callback classification: any
                // subsequent failure is routed as a fresh running-source loss.
                finishSystemAudioRecoveryIfOwned(recoveryID: recoveryID)
                logger.info(
                    "system_audio_recovery_succeeded recovery_id=\(recoveryID, privacy: .public) attempt=\(attemptIndex + 1, privacy: .public)"
                )
                diagnosticSink(
                    "system_audio_recovery_succeeded recovery_id=\(recoveryID) attempt=\(attempt)"
                )
                eventTarget.emit(.sourceRecovered(source: .system))
                return

            case .failure(let error):
                logger.warning(
                    "system_audio_recovery_attempt_stalled recovery_id=\(recoveryID, privacy: .public) attempt=\(attemptIndex + 1, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
                )
                diagnosticSink(
                    "system_audio_recovery_attempt_stalled recovery_id=\(recoveryID) attempt=\(attempt) \(AudioCaptureDiagnostics.errorFields(error))"
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
                logSystemAudioRecoveryCancellation(
                    recoveryID: recoveryID,
                    attempt: attempt,
                    phase: "waiting_for_first_buffer"
                )
                return
            }
        }

        guard isSystemAudioRecoveryCurrent(recoveryID: recoveryID, attemptID: attemptID) else {
            return
        }
        logger.error("system_audio_recovery_exhausted recovery_id=\(recoveryID, privacy: .public)")
        diagnosticSink(
            "system_audio_recovery_exhausted recovery_id=\(recoveryID) attempts=\(systemAudioRecoveryDelays.count) \(AudioCaptureDiagnostics.errorFields(originalError))"
        )
        emitTerminalSystemAudioFailure(
            originalError,
            sourceMode: sourceMode,
            eventTarget: eventTarget
        )
    }

    private func logSystemAudioRecoveryCancellation(
        recoveryID: Int,
        attempt: Int,
        phase: String
    ) {
        guard Task.isCancelled else { return }
        diagnosticSink(
            "system_audio_recovery_cancelled recovery_id=\(recoveryID) attempt=\(attempt) phase=\(phase)"
        )
    }

    private func isSystemAudioRecoveryCurrent(recoveryID: Int, attemptID: Int) -> Bool {
        // Native source setup can finish before the meeting's first-frame
        // waiter resumes. Its runtime failures still own normal recovery in
        // that handoff window; the meeting does not need premature promotion.
        activeSystemAudioRecoveryID == recoveryID && isCaptureAttemptActive(attemptID)
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
        if case .starting = lifecycleState {
            startupSignal?.recordFailure(source: .system, error: error)
            return
        }
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

    private static func hasUsableFrames(_ buffer: AVAudioPCMBuffer) -> Bool {
        buffer.frameLength > 0 && buffer.format.sampleRate.isFinite
            && buffer.format.sampleRate > 0 && buffer.format.channelCount > 0
    }

    private static func deepCopyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard hasUsableFrames(buffer) else { return nil }
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

/// Arbitration stays off the native lifecycle queues. A usable buffer commits
/// the attempt even if its source fails before the awaiting actor resumes: the
/// caller must preserve audio through durable Stop instead of failed-start
/// deletion. The deadline also updates still-pending sources in a partial live
/// session, without cancelling an uninterruptible native call.
private final class MeetingCaptureStartupSignal: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let sourceMode: MeetingAudioSourceMode
    private let eventTarget: EventSink
    private var states: [AudioSource: MeetingAudioCaptureSourceStartupState]
    private var failedSources = Set<AudioSource>()
    private var deliveredSources = Set<AudioSource>()
    private var microphoneReport: MeetingMicrophoneCaptureStartReport?
    private var outcome: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?
    private var retired = false

    init(sourceMode: MeetingAudioSourceMode, eventTarget: EventSink) {
        self.sourceMode = sourceMode
        self.eventTarget = eventTarget
        self.states = [
            .microphone: sourceMode.capturesMicrophone ? .starting : .notSelected,
            .system: sourceMode.capturesSystemAudio ? .starting : .notSelected,
        ]
    }

    var report: MeetingAudioCaptureStartReport {
        lock.withLock {
            MeetingAudioCaptureStartReport(
                sourceMode: sourceMode,
                microphone: microphoneReport,
                microphoneState: states[.microphone],
                systemState: states[.system]
            )
        }
    }

    func publishInitialStates() {
        lock.withLock {
            for source in [AudioSource.microphone, .system] {
                if let state = states[source] {
                    eventTarget.emit(.sourceStartupState(source: source, state: state))
                }
            }
        }
    }

    func acceptsBuffers(from source: AudioSource) -> Bool {
        lock.withLock { !retired && states[source] != .notSelected && !failedSources.contains(source) }
    }

    func deliverBuffer(
        source: AudioSource,
        event: MeetingAudioCaptureEvent,
        healthEvents: [MeetingMicHealthMonitor.HealthEvent]
    ) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !retired, !failedSources.contains(source), eventTarget.isAcceptingEvents else { return nil }
            if case .failure? = outcome { return nil }
            deliveredSources.insert(source)
            let becameReady = states[source] != .ready
            states[source] = .ready
            let continuation = resolveLocked(.success(()))
            // Registration precedes emission under the same recursive lock as
            // failure and retirement. Even a reentrant failure from the event
            // handler sees a real capture and cannot resolve an empty startup.
            eventTarget.emit(event)
            for healthEvent in healthEvents {
                eventTarget.emit(.microphoneHealth(healthEvent))
            }
            if becameReady, states[source] == .ready, !retired {
                eventTarget.emit(.sourceStartupState(source: source, state: .ready))
            }
            return continuation
        }
        continuation?.resume()
    }

    func recordMicrophoneReport(_ report: MeetingMicrophoneCaptureStartReport) {
        lock.withLock {
            guard !retired, !failedSources.contains(.microphone) else { return }
            microphoneReport = report
            eventTarget.emit(.microphoneStarted(report: report))
        }
    }

    func recordRecoveredSource(_ source: AudioSource) {
        lock.withLock {
            guard !retired else { return }
            failedSources.remove(source)
            deliveredSources.insert(source)
            states[source] = .ready
            eventTarget.emit(.sourceStartupState(source: source, state: .ready))
        }
    }

    func recordFailure(source: AudioSource, error: MeetingAudioError) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !retired, failedSources.insert(source).inserted else { return nil }
            states[source] = .unavailable
            eventTarget.emit(.sourceStartupState(source: source, state: .unavailable))
            let allFailed = states.allSatisfy { source, state in
                state == .notSelected || failedSources.contains(source)
            }
            let dual = sourceMode.capturesMicrophone && sourceMode.capturesSystemAudio
            if deliveredSources.contains(source) {
                eventTarget.emit(dual ? .sourceInterrupted(source: source, error: error) : .error(error))
            }
            guard allFailed else { return nil }
            if deliveredSources.isEmpty {
                return resolveLocked(.failure(error))
            }
            if dual { eventTarget.emit(.error(error)) }
            return nil
        }
        continuation?.resume(throwing: error)
    }

    func scheduleDeadline(after duration: Duration) {
        let components = duration.components
        let seconds = max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.deadlineReached()
        }
    }

    private func deadlineReached() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !retired else { return nil }
            for source in [AudioSource.microphone, .system] where states[source] == .starting {
                states[source] = .unavailable
                eventTarget.emit(.sourceStartupState(source: source, state: .unavailable))
            }
            guard deliveredSources.isEmpty else { return nil }
            return resolveLocked(.failure(MeetingAudioError.captureStartupTimedOut))
        }
        continuation?.resume(throwing: MeetingAudioError.captureStartupTimedOut)
    }

    func retire() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            retired = true
            return resolveLocked(.failure(CancellationError()))
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func resolveLocked(_ result: Result<Void, Error>) -> CheckedContinuation<Void, Error>? {
        guard outcome == nil else { return nil }
        outcome = result
        defer { waiter = nil }
        return waiter
    }

    func waitForAudio() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = lock.withLock { () -> Result<Void, Error>? in
                    if let outcome { return outcome }
                    waiter = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            self.retire()
        }
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

    var isAwaitingPromotion: Bool {
        lock.withLock {
            if case .accepting = state { return true }
            return false
        }
    }

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

    var isAcceptingEvents: Bool {
        lock.withLock { isActive }
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
