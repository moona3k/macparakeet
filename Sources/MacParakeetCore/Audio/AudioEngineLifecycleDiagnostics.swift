import Foundation
import os

/// A content-free snapshot of one microphone engine lifecycle operation.
/// Route labels are finite categories, and errors contain classifications only.
public struct AudioEngineLifecycleSnapshot: Sendable, Equatable {
    public enum Operation: String, Sendable, CaseIterable {
        case start, prepare, recovery, stop
    }

    public enum Scope: String, Sendable {
        /// Waiting to enter the shared subscription queue, before native engine work.
        case sharedSubscriptionQueue = "shared_subscription_queue"
    }

    public enum Outcome: String, Sendable {
        case success, failure, cancelled, slow
    }

    public enum Phase: String, Sendable, CaseIterable {
        case queueWait = "queue_wait"
        case routeResolution = "route_resolution"
        case setDevice = "set_device"
        case inputNode = "input_node"
        case voiceProcessing = "voice_processing"
        case ducking
        case inputFormat = "input_format"
        case installTap = "install_tap"
        case prepareEngine = "prepare_engine"
        case startEngine = "start_engine"
        case firstBuffer = "first_buffer"
        case validateRoute = "validate_route"
        case teardown
        case ready
    }

    public let attemptID: String
    public let operation: Operation
    public let scope: Scope?
    public let outcome: Outcome
    public let phase: Phase
    public let elapsedMilliseconds: Int
    public let phaseMilliseconds: Int
    public let attemptCount: Int
    public let prepared: Bool
    public let vpioEnabled: Bool
    public let bufferSize: UInt32
    public let routeSource: String
    public let transport: String
    public let lastErrorType: String?
    public let lastErrorPhase: Phase?
    public let wasSlow: Bool
    public let phaseDurationsMilliseconds: [Phase: Int]
    public let workflowID: String?
    public let consumer: String?

    /// Shared schema for the local record and the consent-gated telemetry event.
    /// Only phases actually visited are included; the full schema stays below
    /// the telemetry boundary's 40-property limit.
    public var props: [String: String] {
        var result = [
            "attempt_id": attemptID,
            "operation": operation.rawValue,
            "outcome": outcome.rawValue,
            "phase": phase.rawValue,
            "elapsed_ms": String(elapsedMilliseconds),
            "phase_ms": String(phaseMilliseconds),
            "attempt_count": String(attemptCount),
            "prepared": String(prepared),
            "vpio": String(vpioEnabled),
            "buffer_size": String(bufferSize),
            "route_source": routeSource,
            "transport": transport,
            "was_slow": String(wasSlow),
        ]
        result["last_error_type"] = lastErrorType
        result["last_error_phase"] = lastErrorPhase?.rawValue
        result["scope"] = scope?.rawValue
        result["workflow_id"] = workflowID
        result["consumer"] = consumer
        for (phase, duration) in phaseDurationsMilliseconds {
            result["phase_\(phase.rawValue)_ms"] = String(duration)
        }
        return result
    }

    public var localLogLine: String {
        let fields = props.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        return "audio_engine_lifecycle \(fields)"
    }
}

/// Records lifecycle progress without depending on the native audio queue.
///
/// Each operation emits at most one slow checkpoint and one terminal record.
/// A checkpoint observes pending work; it does not time out or recover audio.
/// Start/recovery always emit a terminal record. Prepare/stop emit only when
/// slow, including failures, so recurring idle preparation does not fill logs.
/// Scoped subscription queue observations also emit only when slow. Their
/// success means queue entry, not completion of native engine startup.
/// Never call this recorder from an audio render callback.
///
/// Mutable state is protected by `state`; the timer handle is immutable after
/// initialization and Dispatch permits concurrent cancellation. Sink work runs
/// on a separate serial queue, with only queue submission under the state lock.
final class AudioEngineLifecycleDiagnostics: @unchecked Sendable {
    typealias Operation = AudioEngineLifecycleSnapshot.Operation
    typealias Phase = AudioEngineLifecycleSnapshot.Phase

    private struct State {
        var phase: Phase = .queueWait
        var phaseStartedAt: UInt64
        var latestTime: UInt64
        var phaseDurations: [Phase: UInt64] = [:]
        var attemptCount = 0
        var prepared = false
        var routeSource = "unknown"
        var transport = "unknown"
        var lastErrorType: String?
        var lastErrorPhase: Phase?
        var reportedSlow = false
        var finished = false

        mutating func observe(_ time: UInt64) -> UInt64 {
            // A faulty injected clock must not underflow or count a span twice.
            latestTime = max(latestTime, time)
            return latestTime
        }
    }

    private let attemptID = UUID().uuidString.lowercased()
    private let operation: Operation
    private let scope: AudioEngineLifecycleSnapshot.Scope?
    private let vpioEnabled: Bool
    private let bufferSize: UInt32
    private let workflowID: String?
    private let consumer: String?
    private let startedAt: UInt64
    private let slowThresholdNanoseconds: UInt64
    private let now: @Sendable () -> UInt64
    private let sink: @Sendable (AudioEngineLifecycleSnapshot) -> Void
    private let state: OSAllocatedUnfairLock<State>
    private let timer: DispatchSourceTimer?
    private let emissionQueue = DispatchQueue(
        label: "com.macparakeet.audio-engine-lifecycle-diagnostics.emit",
        qos: .utility
    )

    init(
        operation: Operation,
        scope: AudioEngineLifecycleSnapshot.Scope? = nil,
        vpioEnabled: Bool,
        bufferSize: UInt32,
        slowThreshold: TimeInterval = 5,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        automaticallySchedule: Bool = true,
        sink: @escaping @Sendable (AudioEngineLifecycleSnapshot) -> Void = {
            AudioCaptureDiagnostics.appendAsync($0.localLogLine, correlation: nil)
            Telemetry.send(.audioEngineLifecycle($0))
        }
    ) {
        self.operation = operation
        self.scope = scope
        self.vpioEnabled = vpioEnabled
        self.bufferSize = bufferSize
        let correlation = Observability.currentCaptureCorrelation
        self.workflowID =
            correlation.flatMap { UUID(uuidString: $0.workflowID) != nil ? $0.workflowID : nil }
        self.consumer = correlation?.consumer.rawValue
        self.now = now
        self.sink = sink
        startedAt = now()
        slowThresholdNanoseconds = Self.nanoseconds(slowThreshold)
        state = OSAllocatedUnfairLock(initialState: State(phaseStartedAt: startedAt, latestTime: startedAt))
        if automaticallySchedule {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            self.timer = timer
            let deadline = Self.addClamping(DispatchTime.now().uptimeNanoseconds, slowThresholdNanoseconds)
            timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
            timer.setEventHandler { [weak self] in self?.reportIfSlow() }
            timer.resume()
        } else {
            timer = nil
        }
    }

    deinit {
        timer?.cancel()
    }

    func enter(_ phase: Phase) {
        let time = now()
        state.withLock { state in
            guard !state.finished else { return }
            let time = state.observe(time)
            guard state.phase != phase else { return }
            state.phaseDurations[state.phase] = Self.addClamping(
                state.phaseDurations[state.phase, default: 0], time - state.phaseStartedAt
            )
            state.phase = phase
            state.phaseStartedAt = time
        }
    }

    func beginAttempt(source: String, transport: String, prepared: Bool) {
        let source = Self.safeRouteSource(source)
        let transport = Self.safeTransport(transport)
        state.withLock { state in
            guard !state.finished else { return }
            if state.attemptCount < Int.max { state.attemptCount += 1 }
            state.routeSource = source
            state.transport = transport
            state.prepared = prepared
        }
    }

    func noteError(_ error: Error) {
        let errorType = TelemetryErrorClassifier.classify(error)
        state.withLock { state in
            guard !state.finished else { return }
            state.lastErrorType = errorType
            state.lastErrorPhase = state.phase
        }
    }

    func finish(error: Error? = nil) {
        let time = now()
        let errorType = error.map(TelemetryErrorClassifier.classify)
        let cancelled =
            error is CancellationError
            || error as? AVAudioEngineMicrophonePlatformError == .startupCancelled
        state.withLock { state in
            guard !state.finished else { return }
            let time = state.observe(time)
            state.finished = true
            // Native cleanup may have advanced to teardown after noteError.
            // These fields describe the last recorded attempt error. The
            // platform can throw an earlier fallback error, so do not replace
            // the last known origin with the phase at terminal emission.
            if let errorType, state.lastErrorType == nil {
                state.lastErrorType = errorType
                state.lastErrorPhase = state.phase
            }
            let wasSlow = state.reportedSlow || time - startedAt >= slowThresholdNanoseconds
            let alwaysEmitTerminal = scope == nil && (operation == .start || operation == .recovery)
            guard alwaysEmitTerminal || wasSlow else { return }
            enqueue(
                snapshot(
                    state: state,
                    time: time,
                    outcome: error == nil ? .success : (cancelled ? .cancelled : .failure),
                    wasSlow: wasSlow
                )
            )
        }
        timer?.cancel()
    }

    func reportIfSlow() {
        let time = now()
        state.withLock { state in
            guard !state.finished, !state.reportedSlow else { return }
            let time = state.observe(time)
            guard time - startedAt >= slowThresholdNanoseconds else { return }
            state.reportedSlow = true
            enqueue(snapshot(state: state, time: time, outcome: .slow, wasSlow: true))
        }
    }

    /// Awaits snapshots already submitted, without waiting for the lifecycle to
    /// finish. This drains the injected sink, not its downstream file/network I/O.
    func flushPendingEmissions() async {
        await withCheckedContinuation { continuation in
            emissionQueue.async { continuation.resume() }
        }
    }

    private func enqueue(_ snapshot: AudioEngineLifecycleSnapshot) {
        // Submit while holding state so a racing terminal cannot overtake its
        // checkpoint. The actual sink never executes on the lifecycle caller.
        emissionQueue.async { [sink] in sink(snapshot) }
    }

    private func snapshot(
        state: State,
        time: UInt64,
        outcome: AudioEngineLifecycleSnapshot.Outcome,
        wasSlow: Bool
    ) -> AudioEngineLifecycleSnapshot {
        let phaseDuration = time - state.phaseStartedAt
        var durations = state.phaseDurations
        durations[state.phase] = Self.addClamping(durations[state.phase, default: 0], phaseDuration)
        return AudioEngineLifecycleSnapshot(
            attemptID: attemptID,
            operation: operation,
            scope: scope,
            outcome: outcome,
            phase: state.phase,
            elapsedMilliseconds: Self.milliseconds(time - startedAt),
            phaseMilliseconds: Self.milliseconds(phaseDuration),
            attemptCount: state.attemptCount,
            prepared: state.prepared,
            vpioEnabled: vpioEnabled,
            bufferSize: bufferSize,
            routeSource: state.routeSource,
            transport: state.transport,
            lastErrorType: state.lastErrorType,
            lastErrorPhase: state.lastErrorPhase,
            wasSlow: wasSlow,
            phaseDurationsMilliseconds: durations.mapValues(Self.milliseconds),
            workflowID: workflowID,
            consumer: consumer
        )
    }

    private static func safeRouteSource(_ source: String) -> String {
        switch source {
        case "selected", "system_default", "built_in": return source
        default: return "unknown"
        }
    }

    private static func safeTransport(_ transport: String) -> String {
        // Exactly the categories emitted by AudioCaptureDiagnostics. Aggregate
        // members use safeTransportLabel, which never returns "none".
        switch transport {
        case "none", "built-in", "bluetooth", "bluetooth-le", "usb", "aggregate", "virtual", "unknown",
            "aggregate-built-in", "aggregate-bluetooth", "aggregate-bluetooth-le", "aggregate-usb",
            "aggregate-aggregate", "aggregate-virtual", "aggregate-unknown":
            return transport
        default: return "unknown"
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard !seconds.isNaN, seconds > 0 else { return 0 }
        let value = seconds * 1_000_000_000
        guard value.isFinite, value < Double(UInt64.max) else { return .max }
        return UInt64(value)
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Int {
        Int(clamping: nanoseconds / 1_000_000)
    }

    private static func addClamping(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
