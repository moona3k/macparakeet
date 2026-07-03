import Foundation

public enum MeetingCleanedMicrophoneRoutingReason: String, Sendable, Codable, CaseIterable {
    case cleanedUsed
    case rawTimeout
    case rawInvalidArtifact
    case rawRenderFailed
    case rawMissingSystemReference
    case rawNoAECAssets
    case skippedNoEchoPath
}

public struct MeetingCleanedMicrophoneReadinessPolicy: Sendable, Equatable {
    /// The v1.4 LocalVQE AEC model measured on this worktree at 16.33x realtime
    /// for the conditioning core: 60.0 s synthetic meeting audio in 3.674 s on
    /// an Apple M4 Pro via `MeetingAecRenderThroughputTests`. A 0.25x duration
    /// budget assumes only 4x realtime, leaving roughly 3x margin for file
    /// decode/encode and cold system load while still bounding final-STT delay.
    public static let production = MeetingCleanedMicrophoneReadinessPolicy(
        floorSeconds: 60,
        durationMultiplier: 0.25,
        capSeconds: 10 * 60
    )

    public let floorSeconds: TimeInterval
    public let durationMultiplier: Double
    public let capSeconds: TimeInterval

    public init(
        floorSeconds: TimeInterval,
        durationMultiplier: Double,
        capSeconds: TimeInterval
    ) {
        self.floorSeconds = max(0, floorSeconds)
        self.durationMultiplier = max(0, durationMultiplier)
        self.capSeconds = max(0, capSeconds)
    }

    public func timeoutSeconds(for recordingDuration: TimeInterval) -> TimeInterval {
        let scaled: TimeInterval
        if recordingDuration.isFinite {
            scaled = max(0, recordingDuration) * durationMultiplier
        } else {
            scaled = capSeconds
        }
        return max(floorSeconds, min(scaled, capSeconds))
    }
}

public struct MeetingCleanedMicrophoneSourceDecision: Sendable, Equatable {
    public let url: URL
    public let reason: MeetingCleanedMicrophoneRoutingReason

    public var usesCleanedMicrophone: Bool {
        reason == .cleanedUsed
    }
}

enum MeetingCleanedMicrophoneRenderCompletion: Sendable, Equatable {
    case rendered(URL)
    case fallback(MeetingCleanedMicrophoneRoutingReason)
}

struct MeetingCleanedMicrophoneReadiness: Sendable {
    let outputURL: URL?
    private let task: Task<MeetingCleanedMicrophoneRenderCompletion, Never>?
    private let notScheduledReason: MeetingCleanedMicrophoneRoutingReason?

    static func notScheduled(
        reason: MeetingCleanedMicrophoneRoutingReason
    ) -> MeetingCleanedMicrophoneReadiness {
        MeetingCleanedMicrophoneReadiness(
            outputURL: nil,
            task: nil,
            notScheduledReason: reason
        )
    }

    static func scheduled(
        outputURL: URL,
        task: Task<MeetingCleanedMicrophoneRenderCompletion, Never>
    ) -> MeetingCleanedMicrophoneReadiness {
        MeetingCleanedMicrophoneReadiness(
            outputURL: outputURL,
            task: task,
            notScheduledReason: nil
        )
    }

    func awaitCompletion(timeoutSeconds: TimeInterval) async -> MeetingCleanedMicrophoneRenderCompletion? {
        if let notScheduledReason {
            return .fallback(notScheduledReason)
        }
        guard let task else { return nil }

        return await withCheckedContinuation { continuation in
            let race = MeetingCleanedMicrophoneReadinessRace(continuation: continuation)
            let renderWaiter = Task {
                let completion = await task.value
                race.resume(completion, cancelRenderWaiter: false, cancelTimeout: true)
            }
            race.setRenderWaiter(renderWaiter)
            let timeoutWaiter = Task {
                try? await Task.sleep(nanoseconds: Self.nanoseconds(for: timeoutSeconds))
                race.resume(nil, cancelRenderWaiter: true, cancelTimeout: false)
            }
            race.setTimeoutWaiter(timeoutWaiter)
        }
    }

    private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        let clamped = max(0, seconds)
        let maxSeconds = Double(UInt64.max) / 1_000_000_000
        guard clamped < maxSeconds else { return UInt64.max }
        return UInt64((clamped * 1_000_000_000).rounded())
    }
}

private final class MeetingCleanedMicrophoneReadinessRace: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var renderWaiter: Task<Void, Never>?
    private var timeoutWaiter: Task<Void, Never>?
    private let continuation: CheckedContinuation<MeetingCleanedMicrophoneRenderCompletion?, Never>

    init(
        continuation: CheckedContinuation<MeetingCleanedMicrophoneRenderCompletion?, Never>
    ) {
        self.continuation = continuation
    }

    func setRenderWaiter(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            renderWaiter = task
            return didResume
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func setTimeoutWaiter(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            timeoutWaiter = task
            return didResume
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func resume(
        _ value: MeetingCleanedMicrophoneRenderCompletion?,
        cancelRenderWaiter: Bool,
        cancelTimeout: Bool
    ) {
        let resumeState: (shouldResume: Bool, tasksToCancel: [Task<Void, Never>]) = lock.withLock {
            guard !didResume else { return (false, []) }
            didResume = true
            let tasks = [
                cancelRenderWaiter ? renderWaiter : nil,
                cancelTimeout ? timeoutWaiter : nil,
            ].compactMap { $0 }
            return (true, tasks)
        }
        guard resumeState.shouldResume else {
            return
        }
        continuation.resume(returning: value)
        for task in resumeState.tasksToCancel {
            task.cancel()
        }
    }
}

enum MeetingCleanedMicrophoneRenderScheduler {
    static func schedule(
        outputURL: URL,
        microphoneURL: URL?,
        systemURL: URL?,
        sourceAlignment: MeetingSourceAlignment,
        sessionID: UUID,
        conditionerFactory: @escaping @Sendable () -> any MicConditioning,
        fileManager: FileManager,
        eventName: String
    ) -> MeetingCleanedMicrophoneReadiness {
        guard let microphoneURL else {
            discardArtifact(
                at: outputURL,
                sessionID: sessionID,
                reason: "missing_microphone",
                fileManager: fileManager,
                eventName: eventName
            )
            appendDiagnostic(
                eventName: eventName,
                sessionID: sessionID,
                outcome: "not_scheduled",
                reason: .rawRenderFailed
            )
            return .notScheduled(reason: .rawRenderFailed)
        }
        guard let systemURL else {
            discardArtifact(
                at: outputURL,
                sessionID: sessionID,
                reason: "missing_system_reference",
                fileManager: fileManager,
                eventName: eventName
            )
            appendDiagnostic(
                eventName: eventName,
                sessionID: sessionID,
                outcome: "not_scheduled",
                reason: .rawMissingSystemReference
            )
            return .notScheduled(reason: .rawMissingSystemReference)
        }

        let rendererFileManager = UncheckedSendableBox(fileManager)
        let task = Task.detached(priority: .utility) {
            do {
                let outcome = try await MeetingCleanedMicRenderer(
                    fileManager: rendererFileManager.value
                ).render(
                    microphoneURL: microphoneURL,
                    systemURL: systemURL,
                    sourceAlignment: sourceAlignment,
                    outputURL: outputURL,
                    conditioner: conditionerFactory()
                )
                return handleOutcome(
                    outcome,
                    outputURL: outputURL,
                    sessionID: sessionID,
                    fileManager: rendererFileManager.value,
                    eventName: eventName
                )
            } catch is CancellationError {
                discardArtifact(
                    at: outputURL,
                    sessionID: sessionID,
                    reason: "renderer_cancelled",
                    fileManager: rendererFileManager.value,
                    eventName: eventName
                )
                appendDiagnostic(
                    eventName: eventName,
                    sessionID: sessionID,
                    outcome: "cancelled",
                    reason: .rawRenderFailed
                )
                return .fallback(.rawRenderFailed)
            } catch {
                discardArtifact(
                    at: outputURL,
                    sessionID: sessionID,
                    reason: "renderer_threw",
                    fileManager: rendererFileManager.value,
                    eventName: eventName
                )
                appendDiagnostic(
                    eventName: eventName,
                    sessionID: sessionID,
                    outcome: "skipped",
                    reason: .rawRenderFailed,
                    detail: "error=\(AudioCaptureDiagnostics.errorType(error))"
                )
                return .fallback(.rawRenderFailed)
            }
        }

        AudioCaptureDiagnostics.append(
            "\(eventName) session=\(sessionID.uuidString) outcome=scheduled")
        return .scheduled(outputURL: outputURL, task: task)
    }

    private static func handleOutcome(
        _ outcome: MeetingCleanedMicRenderer.Outcome,
        outputURL: URL,
        sessionID: UUID,
        fileManager: FileManager,
        eventName: String
    ) -> MeetingCleanedMicrophoneRenderCompletion {
        switch outcome {
        case .rendered(let result):
            AudioCaptureDiagnostics.append(
                "\(eventName) session=\(sessionID.uuidString) outcome=rendered duration_s=\(String(format: "%.3f", result.durationSeconds)) processed_frames=\(result.processedFrames) raw_fallback_frames=\(result.rawFallbackFrames) failures=\(result.processingFailures) rms_ratio=\(String(format: "%.2f", result.outputToRawRmsRatio))"
            )
            return .rendered(result.outputURL)
        case .skipped(let reason):
            let routingReason = routingReason(for: reason)
            discardArtifact(
                at: outputURL,
                sessionID: sessionID,
                reason: "renderer_skipped_\(String(describing: reason))",
                fileManager: fileManager,
                eventName: eventName
            )
            appendDiagnostic(
                eventName: eventName,
                sessionID: sessionID,
                outcome: "skipped",
                reason: routingReason,
                detail: "renderer_reason=\(String(describing: reason))"
            )
            return .fallback(routingReason)
        }
    }

    private static func routingReason(
        for skipReason: MeetingCleanedMicRenderer.SkipReason
    ) -> MeetingCleanedMicrophoneRoutingReason {
        switch skipReason {
        case .conditionerUnavailable:
            return .rawNoAECAssets
        case .missingSystemReference:
            return .rawMissingSystemReference
        case .missingMicrophoneSource, .emptyMicrophone, .inputTooLong, .decodeFailed, .renderFailed:
            return .rawRenderFailed
        }
    }

    private static func discardArtifact(
        at outputURL: URL,
        sessionID: UUID,
        reason: String,
        fileManager: FileManager,
        eventName: String
    ) {
        guard fileManager.fileExists(atPath: outputURL.path) else { return }
        do {
            try fileManager.removeItem(at: outputURL)
        } catch {
            let removeError = error
            if fileManager.createFile(atPath: outputURL.path, contents: Data(), attributes: nil) {
                AudioCaptureDiagnostics.append(
                    "\(eventName)_cleanup session=\(sessionID.uuidString) outcome=truncated reason=\(reason) remove_error=\(removeError.localizedDescription)")
            } else {
                AudioCaptureDiagnostics.append(
                    "\(eventName)_cleanup session=\(sessionID.uuidString) outcome=failed reason=\(reason) remove_error=\(removeError.localizedDescription) truncate_error=createFile returned false")
            }
        }
    }

    private static func appendDiagnostic(
        eventName: String,
        sessionID: UUID,
        outcome: String,
        reason: MeetingCleanedMicrophoneRoutingReason,
        detail: String? = nil
    ) {
        let suffix = detail.map { " \($0)" } ?? ""
        AudioCaptureDiagnostics.append(
            "\(eventName) session=\(sessionID.uuidString) outcome=\(outcome) reason=\(reason.rawValue)\(suffix)")
    }
}

extension MeetingRecordingOutput {
    func resolvedMicrophoneTranscriptionSource(
        policy: MeetingCleanedMicrophoneReadinessPolicy = .production,
        fileManager: FileManager = .default
    ) async -> MeetingCleanedMicrophoneSourceDecision {
        if let cleanedMicrophoneReadiness {
            let timeoutSeconds = policy.timeoutSeconds(for: durationSeconds)
            guard let completion = await cleanedMicrophoneReadiness.awaitCompletion(
                timeoutSeconds: timeoutSeconds
            ) else {
                return .init(url: microphoneAudioURL, reason: .rawTimeout)
            }
            switch completion {
            case .rendered(let url):
                if Self.isViableCleanedMicrophoneFile(at: url, fileManager: fileManager) {
                    return .init(url: url, reason: .cleanedUsed)
                }
                return .init(url: microphoneAudioURL, reason: .rawInvalidArtifact)
            case .fallback(let reason):
                return .init(url: microphoneAudioURL, reason: reason)
            }
        }

        if let cleanedMicrophoneAudioURL {
            if Self.isViableCleanedMicrophoneFile(
                at: cleanedMicrophoneAudioURL,
                fileManager: fileManager
            ) {
                return .init(url: cleanedMicrophoneAudioURL, reason: .cleanedUsed)
            }
            return .init(url: microphoneAudioURL, reason: .rawInvalidArtifact)
        }

        return .init(
            url: microphoneAudioURL,
            reason: sourceAlignment.system == nil ? .rawMissingSystemReference : .rawNoAECAssets
        )
    }
}
