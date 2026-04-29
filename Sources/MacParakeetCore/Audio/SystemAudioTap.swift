import AudioToolbox
import CoreAudio
import Foundation
import OSLog
@preconcurrency import AVFoundation

@available(macOS 14.2, *)
public final class SystemAudioTap: @unchecked Sendable {
    public typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    public typealias StallObserver = @Sendable (MeetingAudioError) -> Void

    /// Budget for the very first buffer to arrive after `start`. If Core Audio
    /// produces nothing in this window, the tap is treated as dead-on-arrival.
    /// Kept in sync with `firstBufferTimeoutSeconds` so the user-visible
    /// stall message reports the actual wait duration.
    private static let firstBufferTimeoutSeconds = 2
    private static let firstBufferTimeout: DispatchTimeInterval = .seconds(firstBufferTimeoutSeconds)
    /// How frequently the heartbeat checker runs after first buffer is received.
    private static let heartbeatInterval: DispatchTimeInterval = .seconds(1)
    /// Mid-session silence that should be considered a tap stall (BT disconnect,
    /// driver hiccup, tap revoked). Core Audio normally fires every 10–20ms, so
    /// 5s of silence is unambiguously a stall, not a transient hiccup.
    private static let heartbeatStallThreshold: TimeInterval = 5.0

    private enum LifecycleState {
        case idle
        case starting
        case running
        case stopping
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "SystemAudioTap")
    private let queue = DispatchQueue(label: "com.macparakeet.systemaudiotap", qos: .userInitiated)
    private let watchdogQueue = DispatchQueue(label: "com.macparakeet.systemaudiotap.watchdog", qos: .utility)

    private var tapID: AudioObjectID = .meetingUnknown
    private var aggregateDeviceID: AudioObjectID = .meetingUnknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var tapStreamDescription: AudioStreamBasicDescription?
    private var tapUUIDString: String?
    private var lastPinnedOutputUID: String?
    private let watchdogLock = NSLock()
    private var firstBufferReceived = false
    private var watchdogWorkItem: DispatchWorkItem?
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastBufferAtNanos: UInt64 = 0
    private var hasReportedStall = false
    private var stallObserver: StallObserver?

    private var state: LifecycleState = .idle
    private var bufferHandler: AudioBufferHandler?

    public init() {}

    deinit {
        stop()
    }

    public func start(
        handler: @escaping AudioBufferHandler,
        onStall: StallObserver? = nil
    ) throws {
        var startError: Error?
        var didStart = false

        queue.sync {
            guard state == .idle else {
                startError = MeetingAudioError.alreadyRunning
                return
            }

            state = .starting
            bufferHandler = handler
            watchdogLock.withLock { stallObserver = onStall }

            do {
                try createProcessTap()
                try createAggregateDevice()
                try startDeviceIO()
                state = .running
                didStart = true
            } catch {
                tearDownResources(clearHandler: true)
                startError = error
            }
        }

        if let startError {
            throw startError
        }
        if didStart {
            logger.info(
                "system_audio_tap_started aggregate_device_id=\(self.aggregateDeviceID, privacy: .public) tap_id=\(self.tapID, privacy: .public) pinned_output_uid=\(self.lastPinnedOutputUID ?? "unknown", privacy: .public) sample_rate=\(self.tapStreamDescription?.mSampleRate ?? 0, privacy: .public) channels=\(self.tapStreamDescription?.mChannelsPerFrame ?? 0, privacy: .public)"
            )
        }
    }

    public func stop() {
        var didStop = false
        queue.sync {
            guard state != .idle || aggregateDeviceID.isMeetingValid || tapID.isMeetingValid else { return }
            state = .stopping
            tearDownResources(clearHandler: true)
            didStop = true
        }
        if didStop {
            logger.info("system_audio_tap_stopped")
        }
    }

    private func tearDownResources(clearHandler: Bool) {
        if aggregateDeviceID.isMeetingValid, let procID = deviceProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            deviceProcID = nil
        }

        if aggregateDeviceID.isMeetingValid {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .meetingUnknown
        }

        if tapID.isMeetingValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .meetingUnknown
        }

        if clearHandler {
            bufferHandler = nil
        }
        state = .idle
        tapUUIDString = nil
        lastPinnedOutputUID = nil
        resetDiagnosticsState()
    }

    private func createProcessTap() throws {
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        let tapUUID = UUID()
        tapDescription.uuid = tapUUID
        tapDescription.muteBehavior = .unmuted
        tapUUIDString = tapUUID.uuidString

        var newTapID: AudioObjectID = .meetingUnknown
        let status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)

        guard status == noErr else {
            throw MeetingAudioError.tapCreationFailed(status)
        }

        tapID = newTapID
        tapStreamDescription = try newTapID.readMeetingTapStreamDescription()
    }

    private func createAggregateDevice() throws {
        guard let tapUUIDString else {
            throw MeetingAudioError.invalidTapFormat
        }

        let systemOutputID = try AudioObjectID.readMeetingDefaultSystemOutputDevice()
        let outputUID = try systemOutputID.readMeetingDeviceUID()
        let aggregateUID = "com.macparakeet.aggregate.\(UUID().uuidString)"
        lastPinnedOutputUID = outputUID

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacParakeet Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUIDString,
                ]
            ]
        ]

        var newDeviceID: AudioObjectID = .meetingUnknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDeviceID)

        guard status == noErr else {
            throw MeetingAudioError.aggregateDeviceCreationFailed(status)
        }

        aggregateDeviceID = newDeviceID
    }

    private func startDeviceIO() throws {
        guard var streamDesc = tapStreamDescription,
              let format = AVAudioFormat(streamDescription: &streamDesc) else {
            throw MeetingAudioError.invalidTapFormat
        }

        let ioBlock: AudioDeviceIOBlock = { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self,
                  let callback = self.bufferHandler,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: inInputData,
                    deallocator: nil
                  ) else {
                return
            }

            self.recordBufferDelivery()
            let time = AVAudioTime(hostTime: inInputTime.pointee.mHostTime)
            callback(buffer, time)
        }

        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, queue, ioBlock)

        guard status == noErr else {
            throw MeetingAudioError.aggregateDeviceCreationFailed(status)
        }

        deviceProcID = procID
        scheduleSilentBufferWatchdog()
        status = AudioDeviceStart(aggregateDeviceID, procID)

        guard status == noErr else {
            throw MeetingAudioError.aggregateDeviceCreationFailed(status)
        }
    }

    private func scheduleSilentBufferWatchdog() {
        let workItem = watchdogLock.withLock { () -> DispatchWorkItem in
            firstBufferReceived = false
            hasReportedStall = false
            watchdogWorkItem?.cancel()
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
            let item = DispatchWorkItem { [weak self] in
                self?.handleFirstBufferTimeout()
            }
            watchdogWorkItem = item
            return item
        }
        watchdogQueue.asyncAfter(deadline: .now() + Self.firstBufferTimeout, execute: workItem)
    }

    private func handleFirstBufferTimeout() {
        let snapshot: (observer: StallObserver?, deviceID: AudioObjectID, pinnedUID: String?)? =
            watchdogLock.withLock {
                guard !firstBufferReceived, !hasReportedStall else { return nil }
                hasReportedStall = true
                return (stallObserver, aggregateDeviceID, lastPinnedOutputUID)
            }
        guard let snapshot else { return }
        logger.warning(
            "system_audio_tap_no_buffers_within_timeout pinned_output_uid=\(snapshot.pinnedUID ?? "unknown", privacy: .public) aggregate_device_id=\(snapshot.deviceID, privacy: .public)"
        )
        snapshot.observer?(
            .captureRuntimeFailure(
                "system audio tap delivered no buffers within \(Self.firstBufferTimeoutSeconds)s of start"
            )
        )
    }

    /// Called from the Core Audio IO block on every buffer. Bumps the heartbeat
    /// timestamp and, on first invocation, transitions the watchdog from the
    /// "first buffer" budget to the mid-session heartbeat checker.
    private func recordBufferDelivery() {
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        enum Action { case none, firstBuffer }
        let action = watchdogLock.withLock { () -> Action in
            self.lastBufferAtNanos = nowNanos
            guard !self.firstBufferReceived, !self.hasReportedStall else { return .none }
            self.firstBufferReceived = true
            self.watchdogWorkItem?.cancel()
            self.watchdogWorkItem = nil
            return .firstBuffer
        }
        guard action == .firstBuffer else { return }
        logger.info(
            "system_audio_tap_first_buffer_received pinned_output_uid=\(self.lastPinnedOutputUID ?? "unknown", privacy: .public)"
        )
        startHeartbeatChecker()
    }

    private func startHeartbeatChecker() {
        let timer: DispatchSourceTimer = watchdogLock.withLock {
            heartbeatTimer?.cancel()
            let source = DispatchSource.makeTimerSource(queue: watchdogQueue)
            source.schedule(
                deadline: .now() + Self.heartbeatInterval,
                repeating: Self.heartbeatInterval
            )
            source.setEventHandler { [weak self] in
                self?.checkHeartbeat()
            }
            heartbeatTimer = source
            return source
        }
        timer.resume()
    }

    private func checkHeartbeat() {
        let nowNanos = DispatchTime.now().uptimeNanoseconds
        let snapshot: (gap: TimeInterval, observer: StallObserver?, deviceID: AudioObjectID, pinnedUID: String?)? =
            watchdogLock.withLock {
                guard firstBufferReceived, !hasReportedStall else { return nil }
                let lastNanos = lastBufferAtNanos
                guard nowNanos > lastNanos else { return nil }
                let gap = TimeInterval(nowNanos - lastNanos) / 1_000_000_000.0
                guard gap >= Self.heartbeatStallThreshold else { return nil }
                hasReportedStall = true
                heartbeatTimer?.cancel()
                heartbeatTimer = nil
                return (gap, stallObserver, aggregateDeviceID, lastPinnedOutputUID)
            }
        guard let snapshot else { return }
        logger.warning(
            "system_audio_tap_buffer_stall gap_seconds=\(snapshot.gap, privacy: .public) pinned_output_uid=\(snapshot.pinnedUID ?? "unknown", privacy: .public) aggregate_device_id=\(snapshot.deviceID, privacy: .public)"
        )
        snapshot.observer?(
            .captureRuntimeFailure(
                "system audio tap stopped delivering buffers (gap \(String(format: "%.1f", snapshot.gap))s)"
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
