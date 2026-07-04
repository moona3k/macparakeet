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

struct MeetingCleanedMicrophoneRenderSummary: Sendable, Equatable {
    let modelVersion: String?
    let renderDurationMs: Int?
    let realtimeFactor: Double?
    let delayEstimateMs: Int?
    let probeWindowsEvaluated: Int?
    let probeBestCorrelation: Float?
}

enum MeetingCleanedMicrophoneRenderCompletion: Sendable, Equatable {
    case rendered(URL, summary: MeetingCleanedMicrophoneRenderSummary? = nil)
    case fallback(MeetingCleanedMicrophoneRoutingReason, summary: MeetingCleanedMicrophoneRenderSummary? = nil)
}

struct MeetingCleanedMicrophoneReadiness: Sendable {
    let outputURL: URL?
    private let candidateOutputURL: URL?
    private let task: Task<MeetingCleanedMicrophoneRenderCompletion, Never>?
    private let fileManager: UncheckedSendableBox<FileManager>?
    private let notScheduledReason: MeetingCleanedMicrophoneRoutingReason?

    private init(
        outputURL: URL?,
        candidateOutputURL: URL?,
        task: Task<MeetingCleanedMicrophoneRenderCompletion, Never>?,
        fileManager: FileManager?,
        notScheduledReason: MeetingCleanedMicrophoneRoutingReason?
    ) {
        self.outputURL = outputURL
        self.candidateOutputURL = candidateOutputURL
        self.task = task
        self.fileManager = fileManager.map(UncheckedSendableBox.init)
        self.notScheduledReason = notScheduledReason
    }

    static func notScheduled(
        reason: MeetingCleanedMicrophoneRoutingReason
    ) -> MeetingCleanedMicrophoneReadiness {
        MeetingCleanedMicrophoneReadiness(
            outputURL: nil,
            candidateOutputURL: nil,
            task: nil,
            fileManager: nil,
            notScheduledReason: reason
        )
    }

    static func scheduled(
        outputURL: URL,
        task: Task<MeetingCleanedMicrophoneRenderCompletion, Never>,
        candidateOutputURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> MeetingCleanedMicrophoneReadiness {
        MeetingCleanedMicrophoneReadiness(
            outputURL: outputURL,
            candidateOutputURL: candidateOutputURL,
            task: task,
            fileManager: fileManager,
            notScheduledReason: nil
        )
    }

    func awaitCompletion(timeoutSeconds: TimeInterval) async throws -> MeetingCleanedMicrophoneRenderCompletion? {
        if let notScheduledReason {
            return .fallback(notScheduledReason)
        }
        guard let task else { return nil }

        let race = MeetingCleanedMicrophoneReadinessRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation)
                let renderWaiter = Task {
                    let completion = await task.value
                    race.resumeFromRender(
                        resolveCompletedRender(completion),
                        onLose: discardCandidateOutputs
                    )
                }
                race.setRenderWaiter(renderWaiter)
                let timeoutWaiter = Task {
                    do {
                        try await Task.sleep(nanoseconds: Self.nanoseconds(for: timeoutSeconds))
                    } catch {
                        return
                    }
                    _ = race.resume(
                        nil,
                        cancelRenderWaiter: true,
                        cancelTimeout: false,
                        beforeResume: {
                            task.cancel()
                            discardCandidateOutputs()
                        }
                    )
                }
                race.setTimeoutWaiter(timeoutWaiter)
            }
        } onCancel: {
            _ = race.cancel {
                task.cancel()
                discardCandidateOutputs()
            }
        }
    }

    private func resolveCompletedRender(
        _ completion: MeetingCleanedMicrophoneRenderCompletion
    ) -> MeetingCleanedMicrophoneRenderCompletion {
        guard case .rendered(let renderedURL, let summary) = completion,
            let outputURL,
            let candidateOutputURL
        else {
            return completion
        }

        let fileManager = fileManager?.value ?? .default
        do {
            try? fileManager.removeItem(at: outputURL)
            try fileManager.moveItem(at: renderedURL, to: outputURL)
            if renderedURL != candidateOutputURL {
                try? fileManager.removeItem(at: candidateOutputURL)
            }
            return .rendered(outputURL, summary: summary)
        } catch {
            discardCandidateOutputs()
            return .fallback(.rawRenderFailed)
        }
    }

    private func discardCandidateOutputs() {
        let fileManager = fileManager?.value ?? .default
        if let candidateOutputURL {
            try? fileManager.removeItem(at: candidateOutputURL)
        }
        if let outputURL {
            try? fileManager.removeItem(at: outputURL)
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
    private var continuation: CheckedContinuation<MeetingCleanedMicrophoneRenderCompletion?, Error>?
    private var pendingCancellation = false

    func start(
        _ continuation: CheckedContinuation<MeetingCleanedMicrophoneRenderCompletion?, Error>
    ) {
        let shouldCancel = lock.withLock {
            self.continuation = continuation
            guard pendingCancellation, !didResume else { return false }
            didResume = true
            self.continuation = nil
            return true
        }
        if shouldCancel {
            continuation.resume(throwing: CancellationError())
        }
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

    func resumeFromRender(
        _ value: @autoclosure () -> MeetingCleanedMicrophoneRenderCompletion,
        onLose: () -> Void
    ) {
        let resumeState:
            (
                continuation: CheckedContinuation<MeetingCleanedMicrophoneRenderCompletion?, Error>?,
                timeoutWaiter: Task<Void, Never>?,
                lost: Bool
            ) = lock.withLock {
                guard !didResume else { return (nil, nil, true) }
                didResume = true
                let continuation = self.continuation
                self.continuation = nil
                return (continuation, timeoutWaiter, false)
            }

        if resumeState.lost {
            onLose()
            return
        }
        guard let continuation = resumeState.continuation else {
            return
        }
        resumeState.timeoutWaiter?.cancel()
        continuation.resume(returning: value())
    }

    func resume(
        _ value: MeetingCleanedMicrophoneRenderCompletion?,
        cancelRenderWaiter: Bool,
        cancelTimeout: Bool,
        beforeResume: (() -> Void)? = nil
    ) -> Bool {
        let resumeState:
            (
                continuation: CheckedContinuation<MeetingCleanedMicrophoneRenderCompletion?, Error>?,
                tasksToCancel: [Task<Void, Never>]
            ) = lock.withLock {
                guard !didResume else { return (nil, []) }
                didResume = true
                let continuation = self.continuation
                self.continuation = nil
                let tasks = [
                    cancelRenderWaiter ? renderWaiter : nil,
                    cancelTimeout ? timeoutWaiter : nil,
                ].compactMap { $0 }
                return (continuation, tasks)
            }
        guard let continuation = resumeState.continuation else {
            return false
        }
        beforeResume?()
        for task in resumeState.tasksToCancel {
            task.cancel()
        }
        continuation.resume(returning: value)
        return true
    }

    func cancel(beforeResume: () -> Void) -> Bool {
        let resumeState:
            (
                continuation: CheckedContinuation<MeetingCleanedMicrophoneRenderCompletion?, Error>?,
                tasksToCancel: [Task<Void, Never>],
                shouldCancelRender: Bool
            ) = lock.withLock {
                guard !didResume else { return (nil, [], false) }
                let tasks = [renderWaiter, timeoutWaiter].compactMap { $0 }
                guard let continuation else {
                    pendingCancellation = true
                    return (nil, tasks, true)
                }
                didResume = true
                self.continuation = nil
                return (continuation, tasks, true)
            }
        guard resumeState.shouldCancelRender else {
            return false
        }
        beforeResume()
        for task in resumeState.tasksToCancel {
            task.cancel()
        }
        resumeState.continuation?.resume(throwing: CancellationError())
        return true
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
        let candidateOutputURL = candidateOutputURL(for: outputURL, sessionID: sessionID)
        discardArtifact(
            at: outputURL,
            sessionID: sessionID,
            reason: "prepare_candidate_render",
            fileManager: fileManager,
            eventName: eventName
        )
        discardArtifact(
            at: candidateOutputURL,
            sessionID: sessionID,
            reason: "prepare_candidate_render",
            fileManager: fileManager,
            eventName: eventName
        )
        let task = Task.detached(priority: .utility) {
            do {
                let outcome = try await MeetingCleanedMicRenderer(
                    fileManager: rendererFileManager.value
                ).render(
                    microphoneURL: microphoneURL,
                    systemURL: systemURL,
                    sourceAlignment: sourceAlignment,
                    outputURL: candidateOutputURL,
                    conditionerFactory: conditionerFactory
                )
                return handleOutcome(
                    outcome,
                    outputURL: candidateOutputURL,
                    sessionID: sessionID,
                    fileManager: rendererFileManager.value,
                    eventName: eventName
                )
            } catch is CancellationError {
                discardArtifact(
                    at: candidateOutputURL,
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
                    at: candidateOutputURL,
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
        return .scheduled(
            outputURL: outputURL,
            task: task,
            candidateOutputURL: candidateOutputURL,
            fileManager: fileManager
        )
    }

    private static func candidateOutputURL(for outputURL: URL, sessionID: UUID) -> URL {
        let basename = outputURL.deletingPathExtension().lastPathComponent
        let pathExtension = outputURL.pathExtension.isEmpty ? "tmp" : outputURL.pathExtension
        return
            outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(basename)-\(sessionID.uuidString).tmp")
            .appendingPathExtension(pathExtension)
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
                "\(eventName) session=\(sessionID.uuidString) outcome=rendered duration_s=\(String(format: "%.3f", result.durationSeconds)) render_duration_ms=\(result.renderDurationMs) realtime_factor=\(formatOptional(result.renderRealtimeFactor)) processed_frames=\(result.processedFrames) raw_fallback_frames=\(result.rawFallbackFrames) failures=\(result.processingFailures) rms_ratio=\(String(format: "%.2f", result.outputToRawRmsRatio)) probe_windows=\(result.echoProbe.windowsEvaluated) probe_best_correlation=\(formatOptional(result.echoProbe.bestCorrelation))"
            )
            return .rendered(result.outputURL, summary: summary(for: result))
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
                detail: skipDetail(for: reason)
            )
            return .fallback(routingReason, summary: summary(for: reason))
        }
    }

    private static func summary(
        for result: MeetingCleanedMicRenderer.Result
    ) -> MeetingCleanedMicrophoneRenderSummary {
        MeetingCleanedMicrophoneRenderSummary(
            modelVersion: result.modelVersion,
            renderDurationMs: result.renderDurationMs,
            realtimeFactor: result.renderRealtimeFactor,
            delayEstimateMs: result.delayEstimateMs,
            probeWindowsEvaluated: result.echoProbe.windowsEvaluated,
            probeBestCorrelation: result.echoProbe.bestCorrelation
        )
    }

    private static func summary(
        for skipReason: MeetingCleanedMicRenderer.SkipReason
    ) -> MeetingCleanedMicrophoneRenderSummary? {
        guard case .noEchoPath(let probe) = skipReason else { return nil }
        return MeetingCleanedMicrophoneRenderSummary(
            modelVersion: nil,
            renderDurationMs: nil,
            realtimeFactor: nil,
            delayEstimateMs: nil,
            probeWindowsEvaluated: probe.windowsEvaluated,
            probeBestCorrelation: probe.bestCorrelation
        )
    }

    private static func skipDetail(for reason: MeetingCleanedMicRenderer.SkipReason) -> String {
        switch reason {
        case .noEchoPath(let probe):
            return
                "renderer_reason=no_echo_path probe_detail=\(probe.detail) probe_windows=\(probe.windowsEvaluated) probe_best_correlation=\(formatOptional(probe.bestCorrelation))"
        default:
            return "renderer_reason=\(String(describing: reason))"
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
        case .noEchoPath:
            return .skippedNoEchoPath
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
                    "\(eventName)_cleanup session=\(sessionID.uuidString) outcome=truncated reason=\(reason) remove_error=\(removeError.localizedDescription)"
                )
            } else {
                AudioCaptureDiagnostics.append(
                    "\(eventName)_cleanup session=\(sessionID.uuidString) outcome=failed reason=\(reason) remove_error=\(removeError.localizedDescription) truncate_error=createFile returned false"
                )
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

    private static func formatOptional(_ value: Double?) -> String {
        guard let value else { return "none" }
        return String(format: "%.2f", value)
    }

    private static func formatOptional(_ value: Float?) -> String {
        guard let value else { return "none" }
        return String(format: "%.3f", value)
    }
}

extension MeetingRecordingOutput {
    func resolvedMicrophoneTranscriptionSource(
        policy: MeetingCleanedMicrophoneReadinessPolicy = .production,
        fileManager: FileManager = .default
    ) async throws -> MeetingCleanedMicrophoneSourceDecision {
        let timeoutSeconds = policy.timeoutSeconds(for: durationSeconds)
        let decision: MeetingCleanedMicrophoneSourceDecision
        let renderSummary: MeetingCleanedMicrophoneRenderSummary?
        if let cleanedMicrophoneReadiness {
            guard
                let completion = try await cleanedMicrophoneReadiness.awaitCompletion(
                    timeoutSeconds: timeoutSeconds
                )
            else {
                decision = .init(url: microphoneAudioURL, reason: .rawTimeout)
                renderSummary = nil
                recordEchoSuppressionResolution(
                    reason: decision.reason,
                    renderSummary: renderSummary,
                    fileManager: fileManager
                )
                return decision
            }
            switch completion {
            case .rendered(let url, let summary):
                renderSummary = summary
                if Self.isViableCleanedMicrophoneFile(at: url, fileManager: fileManager) {
                    decision = .init(url: url, reason: .cleanedUsed)
                } else {
                    decision = .init(url: microphoneAudioURL, reason: .rawInvalidArtifact)
                }
            case .fallback(let reason, let summary):
                renderSummary = summary
                decision = .init(url: microphoneAudioURL, reason: reason)
            }
        } else if let cleanedMicrophoneAudioURL {
            renderSummary = nil
            if Self.isViableCleanedMicrophoneFile(
                at: cleanedMicrophoneAudioURL,
                fileManager: fileManager
            ) {
                decision = .init(url: cleanedMicrophoneAudioURL, reason: .cleanedUsed)
            } else {
                decision = .init(url: microphoneAudioURL, reason: .rawInvalidArtifact)
            }
        } else {
            renderSummary = nil
            decision = .init(
                url: microphoneAudioURL,
                reason: sourceAlignment.system == nil ? .rawMissingSystemReference : .rawNoAECAssets
            )
        }

        recordEchoSuppressionResolution(
            reason: decision.reason,
            renderSummary: renderSummary,
            fileManager: fileManager
        )
        return decision
    }

    private func recordEchoSuppressionResolution(
        reason: MeetingCleanedMicrophoneRoutingReason,
        renderSummary: MeetingCleanedMicrophoneRenderSummary?,
        fileManager: FileManager
    ) {
        let metadata = echoSuppressionMetadata(
            reason: reason,
            renderSummary: renderSummary,
            fileManager: fileManager
        )
        do {
            try MeetingRecordingMetadataStore.updateEchoSuppression(
                metadata,
                folderURL: folderURL,
                fileManager: fileManager
            )
        } catch {
            AudioCaptureDiagnostics.append(
                "meeting_echo_suppression_metadata_update_failed session=\(sessionID.uuidString) error_type=\(AudioCaptureDiagnostics.errorType(error))"
            )
        }

        AudioCaptureDiagnostics.append(
            [
                "meeting_echo_suppression_resolution",
                "session=\(sessionID.uuidString)",
                "reason_code=\(reason.rawValue)",
                "model_version=\(renderSummary?.modelVersion ?? "none")",
                "render_duration_ms=\(renderSummary?.renderDurationMs.map(String.init) ?? "none")",
                "realtime_factor=\(formatOptional(renderSummary?.realtimeFactor))",
                "delay_estimate_ms=\(renderSummary?.delayEstimateMs.map(String.init) ?? "none")",
                "probe_windows=\(renderSummary?.probeWindowsEvaluated.map(String.init) ?? "none")",
                "probe_best_correlation=\(formatOptional(renderSummary?.probeBestCorrelation))",
            ].joined(separator: " "))
    }

    private func echoSuppressionMetadata(
        reason: MeetingCleanedMicrophoneRoutingReason,
        renderSummary: MeetingCleanedMicrophoneRenderSummary?,
        fileManager: FileManager
    ) -> MeetingEchoSuppressionMetadata {
        if reason == .cleanedUsed,
            renderSummary == nil,
            let existing = try? MeetingRecordingMetadataStore.load(
                from: folderURL,
                fileManager: fileManager
            ).echoSuppression,
            existing.reasonCode == .cleanedUsed
        {
            return existing
        }

        return MeetingEchoSuppressionMetadata(
            reasonCode: reason,
            modelVersion: renderSummary?.modelVersion,
            renderDurationMs: renderSummary?.renderDurationMs,
            delayEstimateMs: renderSummary?.delayEstimateMs,
            probeBestCorrelation: renderSummary?.probeBestCorrelation
        )
    }

    private func formatOptional(_ value: Double?) -> String {
        guard let value else { return "none" }
        return String(format: "%.2f", value)
    }

    private func formatOptional(_ value: Float?) -> String {
        guard let value else { return "none" }
        return String(format: "%.3f", value)
    }
}
