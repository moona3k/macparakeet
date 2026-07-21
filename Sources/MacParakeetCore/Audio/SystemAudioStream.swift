import AVFoundation
import CoreMedia
import Darwin
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit

enum SystemAudioStreamStopDisposition: Equatable {
    case userStopped
    case unexpected

    static func classify(errorDomain: String, errorCode: Int) -> Self {
        if errorDomain == SCStreamErrorDomain,
            errorCode == SCStreamError.Code.userStopped.rawValue
        {
            return .userStopped
        }
        return .unexpected
    }
}

struct SystemAudioStreamLifecycleState {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case stopping
    }

    private(set) var phase: Phase = .idle
    private(set) var attemptID = 0

    mutating func beginStart() -> Int? {
        guard phase == .idle else { return nil }
        attemptID += 1
        phase = .starting
        return attemptID
    }

    func ownsStarting(_ attemptID: Int) -> Bool {
        phase == .starting && self.attemptID == attemptID
    }

    mutating func markRunning(attemptID: Int) -> Bool {
        guard ownsStarting(attemptID) else { return false }
        phase = .running
        return true
    }

    func ownsRunning(_ attemptID: Int) -> Bool {
        phase == .running && self.attemptID == attemptID
    }

    mutating func beginStop(expectedAttemptID: Int? = nil) -> Int? {
        guard phase != .idle, phase != .stopping else { return nil }
        if let expectedAttemptID, attemptID != expectedAttemptID { return nil }
        phase = .stopping
        return attemptID
    }

    mutating func finishStop(attemptID: Int) {
        guard phase == .stopping, self.attemptID == attemptID else { return }
        phase = .idle
    }

    mutating func reset() {
        phase = .idle
    }
}

public final class SystemAudioStream: NSObject, @unchecked Sendable {
    public typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    public typealias StallObserver = @Sendable (MeetingAudioError) -> Void

    private static let sampleRate = 48_000
    private static let channelCount = 2
    private static let firstBufferTimeoutSeconds = 2
    private static let firstBufferTimeout: DispatchTimeInterval = .seconds(firstBufferTimeoutSeconds)
    private static let heartbeatInterval: DispatchTimeInterval = .seconds(1)
    private static let heartbeatStallThreshold: TimeInterval = 5.0
    private static let defaultStartTimeoutSeconds: TimeInterval = 10
    private static let defaultStopTimeoutSeconds: TimeInterval = 5

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "SystemAudioStream")
    private let stateQueue = DispatchQueue(label: "com.macparakeet.systemaudiostream.state")
    private let sampleQueue = DispatchQueue(label: "com.macparakeet.systemaudiostream.samples", qos: .userInitiated)
    private let screenFrameQueue = DispatchQueue(label: "com.macparakeet.systemaudiostream.screenframes", qos: .utility)
    private let watchdogQueue = DispatchQueue(label: "com.macparakeet.systemaudiostream.watchdog", qos: .utility)
    private let watchdogLock = NSLock()
    private let converter = CMSampleBufferToPCMBuffer()
    private let startTimeoutSeconds: TimeInterval
    private let stopTimeoutSeconds: TimeInterval

    private var lifecycleState = SystemAudioStreamLifecycleState()
    private var stream: SCStream?
    private var lifecycleController: ScreenCaptureLifecycleController?
    private var screenOutputAttached = false
    private var bufferHandler: AudioBufferHandler?
    private var stallObserver: StallObserver?
    private var firstBufferReceived = false
    private var watchdogWorkItem: DispatchWorkItem?
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastBufferAtNanos: UInt64 = 0
    private var hasReportedStall = false

    public override init() {
        self.startTimeoutSeconds = Self.defaultStartTimeoutSeconds
        self.stopTimeoutSeconds = Self.defaultStopTimeoutSeconds
        super.init()
    }

    init(startTimeoutSeconds: TimeInterval, stopTimeoutSeconds: TimeInterval) {
        self.startTimeoutSeconds = max(0, startTimeoutSeconds)
        self.stopTimeoutSeconds = max(0, stopTimeoutSeconds)
        super.init()
    }

    deinit {
        let streamToStop = clearStateForDeinit()
        streamToStop?.stopCapture(completionHandler: nil)
    }

    public func start(
        handler: @escaping AudioBufferHandler,
        onStall: StallObserver? = nil
    ) async throws {
        let attemptID = try beginStart(handler: handler, onStall: onStall)

        do {
            try await BoundedCaptureStartAttempt.run(
                timeoutSeconds: startTimeoutSeconds
            ) { [self] in
                try await performStart(attemptID: attemptID)
            }
            guard armSilentBufferWatchdogIfRunning(attemptID: attemptID) else {
                throw CancellationError()
            }
            logger.info(
                "system_audio_stream_started sample_rate=\(Self.sampleRate, privacy: .public) channels=\(Self.channelCount, privacy: .public)"
            )
            AudioCaptureDiagnostics.append(
                "system_audio_stream_started sr=\(Self.sampleRate) ch=\(Self.channelCount)"
            )
        } catch {
            if error as? CaptureLifecycleDeadlineError == .startTimedOut {
                let timeout = String(format: "%.3f", startTimeoutSeconds)
                logger.error("system_audio_stream_start_timed_out")
                AudioCaptureDiagnostics.append(
                    "system_audio_stream_start_timeout timeout_s=\(timeout)"
                )
            }
            AudioCaptureDiagnostics.append(
                "system_audio_stream_start_failed \(AudioCaptureDiagnostics.errorFields(error))"
            )
            await tearDownAfterFailedStart(attemptID: attemptID)
            throw MeetingAudioError.systemAudioCaptureFailed(error.localizedDescription)
        }
    }

    public func stop() async {
        guard let stopOperation = beginStop() else { return }
        defer { finishStop(attemptID: stopOperation.attemptID) }
        if let stream = stopOperation.stream {
            removeStreamOutputs(from: stream)
        }
        let outcome =
            if let lifecycleController = stopOperation.lifecycleController {
                await lifecycleController.stop()
            } else {
                ScreenCaptureStopOutcome.completed
            }
        if outcome == .timedOut {
            let timeout = String(format: "%.3f", stopTimeoutSeconds)
            logger.error("system_audio_stream_stop_timed_out")
            AudioCaptureDiagnostics.append(
                "system_audio_stream_stop_timeout timeout_s=\(timeout)"
            )
        }
        logger.info("system_audio_stream_stopped")
        AudioCaptureDiagnostics.append(
            "system_audio_stream_stopped outcome=\(String(describing: outcome))"
        )
    }

    private func beginStart(
        handler: @escaping AudioBufferHandler,
        onStall: StallObserver?
    ) throws -> Int {
        let attemptID = stateQueue.sync { () -> Int? in
            guard let attemptID = lifecycleState.beginStart() else { return nil }
            screenOutputAttached = false
            bufferHandler = handler
            watchdogLock.withLock {
                firstBufferReceived = false
                hasReportedStall = false
                watchdogWorkItem?.cancel()
                watchdogWorkItem = nil
                heartbeatTimer?.cancel()
                heartbeatTimer = nil
                lastBufferAtNanos = 0
                stallObserver = onStall
            }
            return attemptID
        }
        guard let attemptID else { throw MeetingAudioError.alreadyRunning }
        return attemptID
    }

    private func performStart(attemptID: Int) async throws {
        let stream = try await makeStream()
        try validateStartStillCurrent(attemptID)

        let lifecycleController = ScreenCaptureLifecycleController(
            session: ScreenCaptureKitLifecycleSession(stream: stream),
            startTimeoutSeconds: startTimeoutSeconds,
            stopTimeoutSeconds: stopTimeoutSeconds
        )
        var stored = false
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            attachDiscardingScreenOutput(to: stream)
            try validateStartStillCurrent(attemptID)
            try storeStreamIfStarting(
                stream,
                lifecycleController: lifecycleController,
                attemptID: attemptID
            )
            stored = true
            try await lifecycleController.start()
            try markRunning(attemptID: attemptID)
        } catch {
            if !stored {
                removeStreamOutputs(from: stream)
                _ = await lifecycleController.stop()
            }
            throw error
        }
    }

    private func validateStartStillCurrent(_ attemptID: Int) throws {
        let isCurrent = stateQueue.sync {
            lifecycleState.ownsStarting(attemptID)
        }
        guard isCurrent else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func storeStreamIfStarting(
        _ stream: SCStream,
        lifecycleController: ScreenCaptureLifecycleController,
        attemptID: Int
    ) throws {
        var shouldReject = false
        stateQueue.sync {
            guard lifecycleState.ownsStarting(attemptID) else {
                shouldReject = true
                return
            }
            self.stream = stream
            self.lifecycleController = lifecycleController
        }
        if shouldReject {
            throw MeetingAudioError.notRunning
        }
    }

    private func markRunning(attemptID: Int) throws {
        var shouldReject = false
        stateQueue.sync {
            guard lifecycleState.markRunning(attemptID: attemptID) else {
                shouldReject = true
                return
            }
        }
        if shouldReject {
            throw MeetingAudioError.notRunning
        }
    }

    private struct StopOperation {
        let attemptID: Int
        let stream: SCStream?
        let lifecycleController: ScreenCaptureLifecycleController?
    }

    private func beginStop(expectedAttemptID: Int? = nil) -> StopOperation? {
        let snapshot = stateQueue.sync { () -> StopOperation? in
            guard
                let stoppingAttemptID = lifecycleState.beginStop(
                    expectedAttemptID: expectedAttemptID
                )
            else {
                return nil
            }
            let stream = self.stream
            let lifecycleController = self.lifecycleController
            self.stream = nil
            self.lifecycleController = nil
            bufferHandler = nil
            resetDiagnosticsState()
            return StopOperation(
                attemptID: stoppingAttemptID,
                stream: stream,
                lifecycleController: lifecycleController
            )
        }
        snapshot?.lifecycleController?.cancelPendingStart()
        return snapshot
    }

    private func finishStop(attemptID: Int) {
        stateQueue.sync {
            lifecycleState.finishStop(attemptID: attemptID)
        }
    }

    private func clearStateForDeinit() -> SCStream? {
        stateQueue.sync {
            let stream = self.stream
            self.stream = nil
            lifecycleController?.cancelPendingStart()
            lifecycleController = nil
            bufferHandler = nil
            lifecycleState.reset()
            resetDiagnosticsState()
            return stream
        }
    }

    private func tearDownAfterFailedStart(attemptID: Int) async {
        guard let stopOperation = beginStop(expectedAttemptID: attemptID) else { return }
        defer { finishStop(attemptID: stopOperation.attemptID) }
        if let stream = stopOperation.stream {
            removeStreamOutputs(from: stream)
        }
        let outcome =
            if let lifecycleController = stopOperation.lifecycleController {
                await lifecycleController.stop()
            } else {
                ScreenCaptureStopOutcome.completed
            }
        if outcome == .timedOut {
            let timeout = String(format: "%.3f", stopTimeoutSeconds)
            logger.error("system_audio_stream_failed_start_teardown_timed_out")
            AudioCaptureDiagnostics.append(
                "system_audio_stream_stop_timeout phase=failed_start timeout_s=\(timeout)"
            )
        }
    }

    private func makeStream() async throws -> SCStream {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw MeetingAudioError.systemAudioCaptureFailed("no capturable display available")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.sampleRate = Self.sampleRate
        configuration.channelCount = Self.channelCount
        configuration.excludesCurrentProcessAudio = true

        return SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    private func attachDiscardingScreenOutput(to stream: SCStream) {
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenFrameQueue)
            stateQueue.sync {
                screenOutputAttached = true
            }
            AudioCaptureDiagnostics.append("system_audio_stream_screen_output_attached mode=discard")
        } catch {
            logger.debug(
                "system_audio_stream_screen_output_attach_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func removeStreamOutputs(from stream: SCStream) {
        do {
            try stream.removeStreamOutput(self, type: .audio)
        } catch {
            logger.debug(
                "system_audio_stream_remove_audio_output_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
        }

        let shouldRemoveScreenOutput = stateQueue.sync { () -> Bool in
            let attached = screenOutputAttached
            screenOutputAttached = false
            return attached
        }
        guard shouldRemoveScreenOutput else { return }
        do {
            try stream.removeStreamOutput(self, type: .screen)
        } catch {
            logger.debug(
                "system_audio_stream_remove_screen_output_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    // ScreenCaptureKit timestamps audio samples on the host-time clock; using
    // callback time here makes system audio drift relative to the mic stream.
    static func hostTime(for sampleBuffer: CMSampleBuffer) -> UInt64 {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = presentationTime.seconds
        guard presentationTime.isValid,
            !presentationTime.isIndefinite,
            seconds.isFinite,
            seconds >= 0
        else {
            return mach_absolute_time()
        }

        return AVAudioTime.hostTime(forSeconds: seconds)
    }

    private func armSilentBufferWatchdogIfRunning(attemptID: Int) -> Bool {
        stateQueue.sync {
            guard lifecycleState.ownsRunning(attemptID) else { return false }
            let workItem = watchdogLock.withLock { () -> DispatchWorkItem? in
                guard !firstBufferReceived, !hasReportedStall else { return nil }
                watchdogWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    self?.handleFirstBufferTimeout()
                }
                watchdogWorkItem = item
                return item
            }
            if let workItem {
                watchdogQueue.asyncAfter(deadline: .now() + Self.firstBufferTimeout, execute: workItem)
            }
            return true
        }
    }

    private func handleFirstBufferTimeout() {
        let observer = watchdogLock.withLock { () -> StallObserver? in
            guard !firstBufferReceived, !hasReportedStall else { return nil }
            hasReportedStall = true
            return stallObserver
        }
        guard let observer else { return }
        logger.warning("system_audio_stream_no_buffers_within_timeout")
        AudioCaptureDiagnostics.append(
            "system_audio_stream_no_buffers_within_timeout timeout_s=\(Self.firstBufferTimeoutSeconds)"
        )
        observer(
            .systemAudioStalled(
                .firstBufferTimeout(seconds: TimeInterval(Self.firstBufferTimeoutSeconds))
            )
        )
    }

    private func recordBufferDelivery() {
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        enum Action { case none, firstBuffer }
        let action = watchdogLock.withLock { () -> Action in
            lastBufferAtNanos = nowNanos
            guard !firstBufferReceived, !hasReportedStall else { return .none }
            firstBufferReceived = true
            watchdogWorkItem?.cancel()
            watchdogWorkItem = nil
            return .firstBuffer
        }
        guard action == .firstBuffer else { return }
        logger.info("system_audio_stream_first_buffer_received")
        AudioCaptureDiagnostics.append(
            "system_audio_stream_first_buffer sr=\(Self.sampleRate) ch=\(Self.channelCount)"
        )
        startHeartbeatTimer()
    }

    private func startHeartbeatTimer() {
        watchdogLock.withLock {
            heartbeatTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
            timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
            timer.setEventHandler { [weak self] in
                self?.checkHeartbeat()
            }
            heartbeatTimer = timer
            timer.resume()
        }
    }

    private func checkHeartbeat() {
        let snapshot: (observer: StallObserver?, gap: TimeInterval)? = watchdogLock.withLock {
            guard firstBufferReceived, !hasReportedStall else { return nil }
            let elapsedNanos = DispatchTime.now().uptimeNanoseconds - lastBufferAtNanos
            let gap = TimeInterval(elapsedNanos) / 1_000_000_000
            guard gap >= Self.heartbeatStallThreshold else { return nil }
            hasReportedStall = true
            return (stallObserver, gap)
        }
        guard let snapshot else { return }
        logger.warning("system_audio_stream_stalled gap_seconds=\(snapshot.gap, privacy: .public)")
        AudioCaptureDiagnostics.append(
            "system_audio_stream_stalled gap_s=\(String(format: "%.2f", snapshot.gap))"
        )
        snapshot.observer?(
            .systemAudioStalled(.bufferGap(seconds: snapshot.gap))
        )
    }

    private func resetDiagnosticsState() {
        watchdogLock.withLock {
            firstBufferReceived = false
            hasReportedStall = false
            watchdogWorkItem?.cancel()
            watchdogWorkItem = nil
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
            lastBufferAtNanos = 0
            stallObserver = nil
        }
    }
}

private final class ScreenCaptureKitLifecycleSession: ScreenCaptureLifecycleSession, @unchecked Sendable {
    // A late start callback may outlive its controller. Keep only a weak stream
    // target: if the stream is gone there is no capture left to stop, and if it
    // is still framework-owned the callback can issue one final stop request.
    private final class WeakStream: @unchecked Sendable {
        weak var value: SCStream?

        init(_ value: SCStream) {
            self.value = value
        }
    }

    private let stream: SCStream

    init(stream: SCStream) {
        self.stream = stream
    }

    func startCapture(completionHandler: @escaping (Error?) -> Void) {
        stream.startCapture(completionHandler: completionHandler)
    }

    func stopCapture(completionHandler: @escaping (Error?) -> Void) {
        stream.stopCapture(completionHandler: completionHandler)
    }

    func makeLateStartStopAction() -> @Sendable () -> Void {
        let target = WeakStream(stream)
        return {
            target.value?.stopCapture(completionHandler: nil)
        }
    }
}

extension SystemAudioStream: SCStreamOutput, SCStreamDelegate {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        do {
            let buffer = try converter.makePCMBuffer(from: sampleBuffer)
            recordBufferDelivery()
            let time = AVAudioTime(hostTime: Self.hostTime(for: sampleBuffer))
            let handler = stateQueue.sync { bufferHandler }
            handler?(buffer, time)
        } catch {
            logger.warning(
                "system_audio_stream_buffer_conversion_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
            let observer = watchdogLock.withLock { stallObserver }
            observer?(
                .captureRuntimeFailure(
                    "system audio stream buffer conversion failed: \(error.localizedDescription)"
                )
            )
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error(
            "system_audio_stream_stopped_with_error error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
        )
        AudioCaptureDiagnostics.append(
            "system_audio_stream_stopped_with_error \(AudioCaptureDiagnostics.errorFields(error))"
        )
        let observer = watchdogLock.withLock { () -> StallObserver? in
            guard !hasReportedStall else { return nil }
            hasReportedStall = true
            watchdogWorkItem?.cancel()
            watchdogWorkItem = nil
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
            return stallObserver
        }
        let nsError = error as NSError
        switch SystemAudioStreamStopDisposition.classify(
            errorDomain: nsError.domain,
            errorCode: nsError.code
        ) {
        case .userStopped:
            observer?(
                .captureRuntimeFailure(
                    "system audio sharing was stopped by the user"
                )
            )
        case .unexpected:
            observer?(.systemAudioStreamStopped(error.localizedDescription))
        }
    }
}
