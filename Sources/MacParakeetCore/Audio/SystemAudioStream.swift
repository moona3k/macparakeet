import AVFoundation
import CoreMedia
import Darwin
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit

public final class SystemAudioStream: NSObject, @unchecked Sendable {
    public typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    public typealias StallObserver = @Sendable (MeetingAudioError) -> Void

    private static let sampleRate = 48_000
    private static let channelCount = 2
    private static let firstBufferTimeoutSeconds = 2
    private static let firstBufferTimeout: DispatchTimeInterval = .seconds(firstBufferTimeoutSeconds)
    private static let heartbeatInterval: DispatchTimeInterval = .seconds(1)
    private static let heartbeatStallThreshold: TimeInterval = 5.0

    private enum LifecycleState {
        case idle
        case starting
        case running
        case stopping
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "SystemAudioStream")
    private let stateQueue = DispatchQueue(label: "com.macparakeet.systemaudiostream.state")
    private let sampleQueue = DispatchQueue(label: "com.macparakeet.systemaudiostream.samples", qos: .userInitiated)
    private let screenFrameQueue = DispatchQueue(label: "com.macparakeet.systemaudiostream.screenframes", qos: .utility)
    private let watchdogQueue = DispatchQueue(label: "com.macparakeet.systemaudiostream.watchdog", qos: .utility)
    private let watchdogLock = NSLock()
    private let converter = CMSampleBufferToPCMBuffer()

    private var state: LifecycleState = .idle
    private var stream: SCStream?
    private var screenOutputAttached = false
    private var bufferHandler: AudioBufferHandler?
    private var stallObserver: StallObserver?
    private var firstBufferReceived = false
    private var watchdogWorkItem: DispatchWorkItem?
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastBufferAtNanos: UInt64 = 0
    private var hasReportedStall = false

    public override init() {}

    deinit {
        let streamToStop = clearStateForDeinit()
        streamToStop?.stopCapture(completionHandler: nil)
    }

    public func start(
        handler: @escaping AudioBufferHandler,
        onStall: StallObserver? = nil
    ) async throws {
        try beginStart(handler: handler, onStall: onStall)

        do {
            let stream = try await makeStream()
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            attachDiscardingScreenOutput(to: stream)
            try storeStreamIfStarting(stream)
            try await startCapture(stream)
            try markRunning()
            scheduleSilentBufferWatchdog()
            logger.info(
                "system_audio_stream_started sample_rate=\(Self.sampleRate, privacy: .public) channels=\(Self.channelCount, privacy: .public)"
            )
            AudioCaptureDiagnostics.append(
                "system_audio_stream_started sr=\(Self.sampleRate) ch=\(Self.channelCount)"
            )
        } catch {
            AudioCaptureDiagnostics.append(
                "system_audio_stream_start_failed \(AudioCaptureDiagnostics.errorFields(error))"
            )
            await tearDownAfterFailedStart()
            throw MeetingAudioError.systemAudioCaptureFailed(error.localizedDescription)
        }
    }

    public func stop() async {
        guard let stream = beginStop() else { return }
        removeStreamOutputs(from: stream)
        await stopCapture(stream)
        logger.info("system_audio_stream_stopped")
        AudioCaptureDiagnostics.append("system_audio_stream_stopped")
    }

    private func beginStart(
        handler: @escaping AudioBufferHandler,
        onStall: StallObserver?
    ) throws {
        var startError: Error?
        stateQueue.sync {
            guard state == .idle else {
                startError = MeetingAudioError.alreadyRunning
                return
            }
            state = .starting
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
        }
        if let startError {
            throw startError
        }
    }

    private func storeStreamIfStarting(_ stream: SCStream) throws {
        var shouldReject = false
        stateQueue.sync {
            guard state == .starting else {
                shouldReject = true
                return
            }
            self.stream = stream
        }
        if shouldReject {
            throw MeetingAudioError.notRunning
        }
    }

    private func markRunning() throws {
        var shouldReject = false
        stateQueue.sync {
            guard state == .starting else {
                shouldReject = true
                return
            }
            state = .running
        }
        if shouldReject {
            throw MeetingAudioError.notRunning
        }
    }

    private func beginStop() -> SCStream? {
        stateQueue.sync {
            guard state != .idle else { return nil }
            state = .stopping
            let stream = self.stream
            self.stream = nil
            bufferHandler = nil
            state = .idle
            resetDiagnosticsState()
            return stream
        }
    }

    private func clearStateForDeinit() -> SCStream? {
        stateQueue.sync {
            let stream = self.stream
            self.stream = nil
            bufferHandler = nil
            state = .idle
            resetDiagnosticsState()
            return stream
        }
    }

    private func tearDownAfterFailedStart() async {
        let stream = beginStop()
        guard let stream else { return }
        removeStreamOutputs(from: stream)
        await stopCapture(stream)
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
            logger.debug("system_audio_stream_screen_output_attach_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
        }
    }

    private func removeStreamOutputs(from stream: SCStream) {
        do {
            try stream.removeStreamOutput(self, type: .audio)
        } catch {
            logger.debug("system_audio_stream_remove_audio_output_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
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
            logger.debug("system_audio_stream_remove_screen_output_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
        }
    }

    private func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func stopCapture(_ stream: SCStream) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stream.stopCapture { _ in
                continuation.resume()
            }
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
              seconds >= 0 else {
            return mach_absolute_time()
        }

        return AVAudioTime.hostTime(forSeconds: seconds)
    }

    private func scheduleSilentBufferWatchdog() {
        let workItem = watchdogLock.withLock { () -> DispatchWorkItem? in
            guard !firstBufferReceived, !hasReportedStall else { return nil }
            watchdogWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.handleFirstBufferTimeout()
            }
            watchdogWorkItem = item
            return item
        }
        guard let workItem else { return }
        watchdogQueue.asyncAfter(deadline: .now() + Self.firstBufferTimeout, execute: workItem)
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
            .captureRuntimeFailure(
                "system audio stream delivered no buffers within \(Self.firstBufferTimeoutSeconds)s of start"
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
            .captureRuntimeFailure(
                "system audio stream stopped delivering buffers (gap \(String(format: "%.1f", snapshot.gap))s)"
            )
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
            logger.warning("system_audio_stream_buffer_conversion_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
            let observer = watchdogLock.withLock { stallObserver }
            observer?(
                .captureRuntimeFailure(
                    "system audio stream buffer conversion failed: \(error.localizedDescription)"
                )
            )
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("system_audio_stream_stopped_with_error error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
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
        observer?(.captureRuntimeFailure("system audio stream stopped: \(error.localizedDescription)"))
    }
}
