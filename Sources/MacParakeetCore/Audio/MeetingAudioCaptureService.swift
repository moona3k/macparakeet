import Foundation
import OSLog
@preconcurrency import AVFoundation

public enum MeetingAudioCaptureEvent: Sendable {
    case microphoneBuffer(AVAudioPCMBuffer, AVAudioTime)
    case systemBuffer(AVAudioPCMBuffer, AVAudioTime)
    case microphoneHealth(MeetingMicHealthMonitor.HealthEvent)
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
    func stop()
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

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioCaptureService")
    private let microphoneCapture: any MeetingMicrophoneCapturing
    private let systemAudioCaptureFactory: @Sendable () throws -> any MeetingSystemAudioCapturing
    private let micProcessingMode: MeetingMicProcessingMode
    private let sourceModeProvider: @Sendable () -> MeetingAudioSourceMode
    private let eventSink = EventSink()
    private let micHealthObserver: MeetingMicHealthTelemetryObserver

    private var systemAudioCapture: (any MeetingSystemAudioCapturing)?
    private var isCapturing = false

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
        micHealthFeatureEnabled: Bool = AppFeatures.meetingCaptureReliabilityEnabled
    ) {
        self.microphoneCapture = microphoneCaptureFactory()
        self.systemAudioCaptureFactory = systemAudioCaptureFactory
        self.micProcessingMode = micProcessingMode
        self.sourceModeProvider = sourceModeProvider
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
        micHealthFeatureEnabled: Bool = AppFeatures.meetingCaptureReliabilityEnabled
    ) {
        self.microphoneCapture = microphoneCapture
        self.systemAudioCaptureFactory = systemAudioCaptureFactory
        self.micProcessingMode = micProcessingMode
        self.sourceModeProvider = sourceModeProvider
        self.micHealthObserver = MeetingMicHealthTelemetryObserver(
            config: micHealthConfig,
            nowProvider: micHealthNowProvider,
            featureEnabled: micHealthFeatureEnabled
        )
    }

    public var events: AsyncStream<MeetingAudioCaptureEvent> {
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

    public func start(sourceMode sourceModeOverride: MeetingAudioSourceMode? = nil) async throws -> MeetingAudioCaptureStartReport {
        _ = events
        let continuation = eventContinuation
        return try await start(sourceMode: sourceModeOverride) { event in
            continuation?.yield(event)
        }
    }

    public func start(
        sourceMode sourceModeOverride: MeetingAudioSourceMode? = nil,
        handler: @escaping EventHandler
    ) async throws -> MeetingAudioCaptureStartReport {
        guard !isCapturing else {
            throw MeetingAudioError.alreadyRunning
        }

        let sourceMode = sourceModeOverride ?? sourceModeProvider()
        var microphoneStartReport: MeetingMicrophoneCaptureStartReport?
        var attemptedMicrophoneStart = false
        let systemCapture: (any MeetingSystemAudioCapturing)?
        if sourceMode.capturesSystemAudio {
            systemCapture = try systemAudioCaptureFactory()
        } else {
            systemCapture = nil
        }
        eventSink.setHandler(handler)
        // Mic health compares microphone energy against system audio, so mic-only capture has no reference stream.
        micHealthObserver.start(observing: sourceMode.capturesMicrophone && sourceMode.capturesSystemAudio)
        let systemAudioFailureEvent: @Sendable (MeetingAudioError) -> MeetingAudioCaptureEvent = { error in
            sourceMode.capturesMicrophone
                ? .sourceInterrupted(source: .system, error: error)
                : .error(error)
        }

        do {
            if sourceMode.capturesMicrophone {
                attemptedMicrophoneStart = true
                microphoneStartReport = try await microphoneCapture.start(
                    processingMode: micProcessingMode,
                    handler: { [weak self] buffer, time in
                        guard let copy = Self.deepCopyBuffer(buffer) else {
                            Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioCaptureService")
                                .warning("deepCopyBuffer nil for microphone capture: format=\(buffer.format.commonFormat.rawValue) rate=\(buffer.format.sampleRate) ch=\(buffer.format.channelCount) interleaved=\(buffer.format.isInterleaved) frames=\(buffer.frameLength)")
                            self?.eventSink.emit(
                                .error(
                                    .captureRuntimeFailure(
                                        "microphone buffer copy failed (format=\(buffer.format.commonFormat.rawValue) rate=\(buffer.format.sampleRate) channels=\(buffer.format.channelCount))"
                                    )
                                )
                            )
                            return
                        }
                        let healthEvents = self?.micHealthObserver.observeMicrophoneBuffer(copy) ?? []
                        for healthEvent in healthEvents {
                            self?.eventSink.emit(.microphoneHealth(healthEvent))
                        }
                        self?.eventSink.emit(.microphoneBuffer(copy, time))
                    },
                    onStall: { [weak self] error in
                        self?.eventSink.emit(.error(error))
                    }
                )
            }

            if let systemCapture {
                try await systemCapture.start(
                    handler: { [weak self] buffer, time in
                        guard let copy = Self.deepCopyBuffer(buffer) else {
                            Logger(subsystem: "com.macparakeet.core", category: "MeetingAudioCaptureService")
                                .warning("deepCopyBuffer nil for system capture: format=\(buffer.format.commonFormat.rawValue) rate=\(buffer.format.sampleRate) ch=\(buffer.format.channelCount) interleaved=\(buffer.format.isInterleaved) frames=\(buffer.frameLength)")
                            self?.eventSink.emit(
                                systemAudioFailureEvent(
                                    .captureRuntimeFailure(
                                        "system buffer copy failed (format=\(buffer.format.commonFormat.rawValue) rate=\(buffer.format.sampleRate) channels=\(buffer.format.channelCount))"
                                    )
                                )
                            )
                            return
                        }
                        let healthEvents = self?.micHealthObserver.observeSystemBuffer(copy) ?? []
                        for healthEvent in healthEvents {
                            self?.eventSink.emit(.microphoneHealth(healthEvent))
                        }
                        self?.eventSink.emit(.systemBuffer(copy, time))
                    },
                    onStall: { [weak self] error in
                        self?.eventSink.emit(systemAudioFailureEvent(error))
                    }
                )
            }
        } catch {
            if attemptedMicrophoneStart {
                microphoneCapture.stop()
            }
            await systemCapture?.stop()
            finishEventStream()
            eventSink.setHandler(nil)
            micHealthObserver.stop()
            throw error
        }

        systemAudioCapture = systemCapture
        isCapturing = true
        logger.info(
            "Meeting audio capture started source_mode=\(sourceMode.rawValue, privacy: .public) microphone_started=\(microphoneStartReport != nil, privacy: .public) requested_mic_mode=\(String(describing: microphoneStartReport?.requestedMode), privacy: .public) effective_mic_mode=\(microphoneStartReport?.effectiveMode.rawValue ?? "none", privacy: .public)"
        )
        return MeetingAudioCaptureStartReport(
            sourceMode: sourceMode,
            microphone: microphoneStartReport
        )
    }

    public func stop() async {
        guard isCapturing else { return }

        microphoneCapture.stop()
        await systemAudioCapture?.stop()
        systemAudioCapture = nil
        isCapturing = false

        eventContinuation?.finish()
        finishEventStream()
        eventSink.setHandler(nil)
        micHealthObserver.stop()
        logger.info("Meeting audio capture stopped")
    }

    private func finishEventStream() {
        eventContinuation?.finish()
        eventContinuation = nil
        cachedEvents = nil
    }

    private static func deepCopyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format: AVAudioFormat
        if buffer.format.isInterleaved {
            guard let nonInterleavedFormat = AVAudioFormat(
                commonFormat: buffer.format.commonFormat,
                sampleRate: buffer.format.sampleRate,
                channels: buffer.format.channelCount,
                interleaved: false
            ) else {
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

private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: MeetingAudioCaptureService.EventHandler?

    func setHandler(_ handler: MeetingAudioCaptureService.EventHandler?) {
        lock.withLock {
            self.handler = handler
        }
    }

    func emit(_ event: MeetingAudioCaptureEvent) {
        let currentHandler = lock.withLock { handler }
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

    func start(observing sourceIncludesMicrophone: Bool) {
        lock.withLock {
            monitor = MeetingMicHealthMonitor(config: config)
            resetTelemetryCountersLocked()
            isObserving = featureEnabled && sourceIncludesMicrophone
        }
    }

    func stop() {
        let summary = lock.withLock {
            let summary = pendingSummaryLocked()
            monitor.reset()
            resetTelemetryCountersLocked()
            isObserving = false
            return summary
        }
        if let summary {
            sendSummary(summary)
        }
    }

    func observeMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) -> [MeetingMicHealthMonitor.HealthEvent] {
        guard shouldObserve else { return [] }
        return observe(
            micSignal: .init(isNonSilent: buffer.rmsLevel >= config.nonSilentLevelThreshold),
            systemSignal: nil
        )
    }

    func observeSystemBuffer(_ buffer: AVAudioPCMBuffer) -> [MeetingMicHealthMonitor.HealthEvent] {
        guard shouldObserve else { return [] }
        return observe(
            micSignal: nil,
            systemSignal: .init(isNonSilent: buffer.rmsLevel >= config.nonSilentLevelThreshold)
        )
    }

    private var shouldObserve: Bool {
        lock.withLock { isObserving }
    }

    private func observe(
        micSignal: MeetingMicHealthMonitor.AudioSignal?,
        systemSignal: MeetingMicHealthMonitor.AudioSignal?
    ) -> [MeetingMicHealthMonitor.HealthEvent] {
        let now = nowProvider()
        // Resolve emissions inside the lock (the monitor state and counters are both
        // mutated from the audio callback thread), then emit telemetry outside it so
        // `Telemetry.send` never runs under the lock.
        let observed = lock.withLock {
            guard isObserving else {
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
            Telemetry.send(.micStallDetected(
                signature: .init(signature),
                elapsedMs: elapsedMs,
                stallCount: summary.stallCount
            ))
        case .summary(let summary):
            sendSummary(summary)
        }
    }

    private func sendSummary(_ summary: StallSummary) {
        Telemetry.send(.micStallDetected(
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
