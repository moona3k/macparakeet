import AVFAudio
import Foundation
import OSLog

public struct MeetingAudioLevels: Sendable, Equatable {
    public var microphone: Float
    public var system: Float

    public init(microphone: Float = 0, system: Float = 0) {
        self.microphone = microphone
        self.system = system
    }
}

public enum CaptureMode: Sendable, Equatable {
    case full
    case stopped
}

public protocol MeetingRecordingServiceProtocol: Sendable {
    func startRecording() async throws
    func stopRecording() async throws -> MeetingRecordingOutput
    func cancelRecording() async
    var isRecording: Bool { get async }
    var micLevel: Float { get async }
    var systemLevel: Float { get async }
    var elapsedSeconds: Int { get async }
    var captureMode: CaptureMode { get async }
    var transcriptUpdates: AsyncStream<MeetingTranscriptUpdate> { get async }
}

public actor MeetingRecordingService: MeetingRecordingServiceProtocol {
    private struct Session: Sendable {
        let id: UUID
        let displayName: String
        let startedAt: Date
        let folderURL: URL
        let chunkFolderURL: URL
        let microphoneAudioURL: URL
        let systemAudioURL: URL
        let mixedAudioURL: URL
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingRecordingService")
    private let clock = ContinuousClock()
    private let audioCaptureService: any MeetingAudioCapturing
    private let audioConverter: any AudioFileConverting
    private let fileManager: FileManager
    private let requestedMicProcessingMode: MeetingMicProcessingMode
    private let liveChunkTranscriber: LiveChunkTranscriber

    private var currentSession: Session?
    private var writer: MeetingAudioStorageWriter?
    private var processingTask: Task<Void, Never>?
    private var captureOrchestrator = CaptureOrchestrator()
    private var micConditioner: any MicConditioning = SoftwareAECConditioner()
    private var transcriptAssembler = MeetingTranscriptAssembler()
    private var chunkTranscriptionFailed = false
    private var isTranscriptionLagging = false
    private var captureFailed = false
    private var latestLevels = MeetingAudioLevels()
    private var recentSystemRms: Float = 0
    private var recentProcessedMicRms: Float = 0
    private var latestSystemSignalAt: ContinuousClock.Instant?
    private var syncLagEmaMs: Double?
    private var syncLagWarningActive = false
    private var lastLoggedSyncLagBucketMs: Int?

    private var transcriptContinuation: AsyncStream<MeetingTranscriptUpdate>.Continuation?
    private var cachedTranscriptUpdates: AsyncStream<MeetingTranscriptUpdate>?

    private static let rmsEmaAlpha: Float = 0.3
    private static let systemDominanceRatio: Float = 10.0
    private static let systemActiveFloor: Float = 0.02
    private static let systemSignalFreshnessWindow: Duration = .milliseconds(750)
    private static let rmsEpsilon: Float = 0.0001
    private static let chunkSignalFloor: Float = 0.00025
    private static let syncLagEmaAlpha: Double = 0.2
    private static let syncLagLogBucketMs: Int = 20
    private static let syncLagWarningThresholdMs: Double = 120

    public init(
        micProcessingMode: MeetingMicProcessingMode = .raw,
        audioCaptureService: (any MeetingAudioCapturing)? = nil,
        audioConverter: any AudioFileConverting = AudioFileConverter(),
        sttTranscriber: STTTranscribing,
        fileManager: FileManager = .default
    ) {
        self.requestedMicProcessingMode = micProcessingMode
        self.audioCaptureService = audioCaptureService ?? MeetingAudioCaptureService(
            micProcessingMode: micProcessingMode
        )
        self.audioConverter = audioConverter
        self.fileManager = fileManager
        self.liveChunkTranscriber = LiveChunkTranscriber(
            sttTranscriber: sttTranscriber,
            fileManager: fileManager
        )
    }

    public var isRecording: Bool {
        currentSession != nil
    }

    public var micLevel: Float {
        latestLevels.microphone
    }

    public var systemLevel: Float {
        latestLevels.system
    }

    public var elapsedSeconds: Int {
        guard let startedAt = currentSession?.startedAt else { return 0 }
        return max(0, Int(Date().timeIntervalSince(startedAt)))
    }

    public var captureMode: CaptureMode {
        (currentSession == nil || captureFailed) ? .stopped : .full
    }

    public var transcriptUpdates: AsyncStream<MeetingTranscriptUpdate> {
        if let cachedTranscriptUpdates {
            return cachedTranscriptUpdates
        }

        var continuation: AsyncStream<MeetingTranscriptUpdate>.Continuation?
        let stream = AsyncStream<MeetingTranscriptUpdate>(bufferingPolicy: .bufferingNewest(12)) {
            continuation = $0
        }
        transcriptContinuation = continuation
        cachedTranscriptUpdates = stream
        return stream
    }

    public func startRecording() async throws {
        guard currentSession == nil else {
            throw MeetingAudioError.alreadyRunning
        }

        let sessionID = UUID()
        let folderURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        let writer = try MeetingAudioStorageWriter(folderURL: folderURL)
        let chunkFolderURL = folderURL.appendingPathComponent("chunks", isDirectory: true)
        try fileManager.createDirectory(at: chunkFolderURL, withIntermediateDirectories: true)
        let session = Session(
            id: sessionID,
            displayName: Self.makeDisplayName(for: Date()),
            startedAt: Date(),
            folderURL: folderURL,
            chunkFolderURL: chunkFolderURL,
            microphoneAudioURL: writer.microphoneAudioURL,
            systemAudioURL: writer.systemAudioURL,
            mixedAudioURL: writer.mixedAudioURL
        )

        let events = await audioCaptureService.events
        self.latestLevels = MeetingAudioLevels()
        self.writer = writer
        self.currentSession = session
        await captureOrchestrator.reset()
        micConditioner = SoftwareAECConditioner()
        transcriptAssembler.reset()
        chunkTranscriptionFailed = false
        isTranscriptionLagging = false
        captureFailed = false
        recentSystemRms = 0
        recentProcessedMicRms = 0
        latestSystemSignalAt = nil
        syncLagEmaMs = nil
        syncLagWarningActive = false
        lastLoggedSyncLagBucketMs = nil

        await liveChunkTranscriber.startSession(
            .init(id: session.id, chunkFolderURL: session.chunkFolderURL),
            onEvent: { [weak self] event in
                await self?.handleLiveChunkTranscriberEvent(event, sessionID: session.id)
            }
        )

        do {
            let captureStartReport = try await audioCaptureService.start()
            configureMicConditioner(from: captureStartReport.microphone)
            processingTask = Task { [weak self] in
                guard let self else { return }
                for await event in events {
                    await self.handleCaptureEvent(event)
                }
            }
            logger.info("Meeting recording started: \(sessionID.uuidString, privacy: .public)")
        } catch {
            processingTask?.cancel()
            processingTask = nil
            await liveChunkTranscriber.finishSession()
            self.writer?.finalize()
            self.writer = nil
            cleanupState()
            try? fileManager.removeItem(at: folderURL)
            throw error
        }
    }

    public func stopRecording() async throws -> MeetingRecordingOutput {
        guard let session = currentSession else {
            throw MeetingAudioError.notRunning
        }

        await audioCaptureService.stop()
        await processingTask?.value
        processingTask = nil
        await flushPendingJoinedFrames()
        await flushTranscriptChunkers()
        // If live preview falls behind, discard partial speaker metadata so
        // finalization can rebuild speakers from the mixed recording instead.
        let preparedTranscriptReady = await liveChunkTranscriber.waitForPendingTasksToDrain(
            timeout: .milliseconds(150)
        )
        if !preparedTranscriptReady {
            await liveChunkTranscriber.cancelPendingTasks(waitForCancellation: false)
        }
        writer?.finalize()
        writer = nil

        let inputURLs = try existingSourceURLs(for: session)
        guard !inputURLs.isEmpty else {
            await liveChunkTranscriber.finishSession()
            cleanupState()
            throw MeetingAudioError.noAudioCaptured
        }

        do {
            try await audioConverter.mixToM4A(inputURLs: inputURLs, outputURL: session.mixedAudioURL)
        } catch {
            await liveChunkTranscriber.finishSession()
            cleanupState()
            throw MeetingAudioError.mixFailed(error.localizedDescription)
        }

        let durationSeconds = max(0, Date().timeIntervalSince(session.startedAt))
        let output = MeetingRecordingOutput(
            sessionID: session.id,
            displayName: session.displayName,
            folderURL: session.folderURL,
            mixedAudioURL: session.mixedAudioURL,
            microphoneAudioURL: session.microphoneAudioURL,
            systemAudioURL: session.systemAudioURL,
            durationSeconds: durationSeconds,
            preparedTranscript: (chunkTranscriptionFailed || !preparedTranscriptReady)
                ? nil
                : transcriptAssembler.finalizedTranscript(durationMs: Int(durationSeconds * 1000))
        )

        await liveChunkTranscriber.finishSession()
        cleanupState()
        logger.info("Meeting recording finalized: \(session.id.uuidString, privacy: .public)")
        return output
    }

    public func cancelRecording() async {
        guard let session = currentSession else { return }

        await audioCaptureService.stop()
        processingTask?.cancel()
        await processingTask?.value
        processingTask = nil
        await liveChunkTranscriber.cancelPendingTasks(waitForCancellation: true)
        await liveChunkTranscriber.finishSession()
        writer?.finalize()
        writer = nil
        cleanupState()
        try? fileManager.removeItem(at: session.folderURL)
        logger.info("Meeting recording cancelled: \(session.id.uuidString, privacy: .public)")
    }

    private func handleCaptureEvent(_ event: MeetingAudioCaptureEvent) async {
        switch event {
        case .microphoneBuffer(let buffer, let time):
            guard !captureFailed else { return }
            do {
                try writer?.write(buffer, source: .microphone)
                latestLevels.microphone = buffer.rmsLevel
                if let samples = AudioChunker.extractAndResample(from: buffer) {
                    await ingestResampledSamples(
                        samples,
                        source: .microphone,
                        hostTime: time.isHostTimeValid ? time.hostTime : nil
                    )
                }
            } catch {
                logger.error("Failed to write microphone audio: \(error.localizedDescription, privacy: .public)")
            }
        case .systemBuffer(let buffer, let time):
            guard !captureFailed else { return }
            do {
                try writer?.write(buffer, source: .system)
                latestLevels.system = buffer.rmsLevel
                updateSystemRms(with: latestLevels.system)
                if let samples = AudioChunker.extractAndResample(from: buffer) {
                    await ingestResampledSamples(
                        samples,
                        source: .system,
                        hostTime: time.isHostTimeValid ? time.hostTime : nil
                    )
                }
            } catch {
                logger.error("Failed to write system audio: \(error.localizedDescription, privacy: .public)")
            }
        case .error(let error):
            guard !captureFailed else { return }
            captureFailed = true
            latestLevels = MeetingAudioLevels()
            logger.error("Meeting capture event error: \(error.localizedDescription, privacy: .public)")
            await audioCaptureService.stop()
        }
    }

    private func ingestResampledSamples(
        _ samples: [Float],
        source: AudioSource,
        hostTime: UInt64?
    ) async {
        let output = await captureOrchestrator.ingest(
            samples: samples,
            source: source,
            hostTime: hostTime,
            micConditioner: micConditioner
        )
        await handleCaptureOrchestratorOutput(output)
    }

    private func handleCaptureOrchestratorOutput(
        _ output: CaptureOrchestratorOutput,
        flushed: Bool = false
    ) async {
        logJoinerDiagnostics(output.diagnostics)

        for pair in output.pairMetadata {
            observePairSyncLag(microphoneHostTime: pair.microphoneHostTime, systemHostTime: pair.systemHostTime)
            if let processedMicRms = pair.processedMicrophoneRms {
                updateProcessedMicrophoneRms(with: processedMicRms)
            }
        }

        for chunk in output.chunks {
            switch chunk.source {
            case .microphone:
                if !shouldTranscribeChunk(chunk.chunk) {
                    if flushed {
                        logger.debug("Skipping low-signal flushed microphone chunk")
                    } else {
                        logger.debug("Skipping low-signal microphone chunk")
                    }
                } else if shouldSuppressMicrophoneChunkTranscription() {
                    if flushed {
                        logger.debug("Suppressing flushed microphone chunk due to dominant recent system audio")
                    } else {
                        logger.debug("Suppressing microphone chunk due to dominant recent system audio")
                    }
                } else {
                    await liveChunkTranscriber.enqueue(chunk: chunk.chunk, source: .microphone)
                }
            case .system:
                if shouldTranscribeChunk(chunk.chunk) {
                    await liveChunkTranscriber.enqueue(chunk: chunk.chunk, source: .system)
                } else {
                    if flushed {
                        logger.debug("Skipping low-signal flushed system chunk")
                    } else {
                        logger.debug("Skipping low-signal system chunk")
                    }
                }
            }
        }
    }

    private func flushTranscriptChunkers() async {
        let chunks = await captureOrchestrator.flushChunkers()
        var output = CaptureOrchestratorOutput()
        output.chunks = chunks
        await handleCaptureOrchestratorOutput(output, flushed: true)
    }

    private func flushPendingJoinedFrames() async {
        let output = await captureOrchestrator.flushPendingPairs(micConditioner: micConditioner)
        await handleCaptureOrchestratorOutput(output)
    }

    private func handleLiveChunkTranscriberEvent(
        _ event: LiveChunkTranscriber.Event,
        sessionID: UUID
    ) {
        guard currentSession?.id == sessionID else { return }
        switch event {
        case .orderedResults(let readyResults):
            for ready in readyResults {
                let update = transcriptAssembler.apply(
                    result: ready.result,
                    chunk: ready.chunk,
                    source: ready.source
                )
                yieldTranscriptUpdate(update)
            }
        case .backpressureDrop:
            isTranscriptionLagging = true
            logger.notice("Meeting live chunk dropped by scheduler backpressure")
        case .transcriptionFailed(let message):
            chunkTranscriptionFailed = true
            logger.error("Meeting chunk transcription failed: \(message, privacy: .public)")
        }
    }

    private func configureMicConditioner(from report: MeetingMicrophoneCaptureStartReport) {
        switch report.effectiveMode {
        case .vpio:
            micConditioner = VPIOConditioner()
        case .raw:
            micConditioner = SoftwareAECConditioner()
        }

        if report.fellBackToRaw {
            logger.notice(
                "meeting_mic_conditioner_fallback requested=\(String(describing: report.requestedMode), privacy: .public) effective=raw requested_policy=\(String(describing: self.requestedMicProcessingMode), privacy: .public)"
            )
        } else {
            logger.info(
                "meeting_mic_conditioner_selected requested=\(String(describing: report.requestedMode), privacy: .public) effective=\(report.effectiveMode.rawValue, privacy: .public)"
            )
        }
    }

    private func yieldTranscriptUpdate(_ update: MeetingTranscriptUpdate) {
        if isTranscriptionLagging && !update.isTranscriptionLagging {
            transcriptContinuation?.yield(
                MeetingTranscriptUpdate(
                    words: update.words,
                    speakers: update.speakers,
                    isTranscriptionLagging: true
                )
            )
            isTranscriptionLagging = false
            return
        }

        transcriptContinuation?.yield(update)
    }

    private func existingSourceURLs(for session: Session) throws -> [URL] {
        // Preserve deterministic channel mapping for dual-source sessions:
        // input[0] = microphone (L), input[1] = system (R).
        let candidates = [session.microphoneAudioURL, session.systemAudioURL]
        return try candidates.filter { url in
            guard fileManager.fileExists(atPath: url.path) else { return false }
            let size = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard (size?.intValue ?? 0) > 0 else { return false }
            return hasDecodableAudioFrames(at: url)
        }
    }

    private func hasDecodableAudioFrames(at url: URL) -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            return file.length > 0
        } catch {
            logger.error("Failed to inspect recorded source audio: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func updateSystemRms(with bufferRms: Float) {
        recentSystemRms = exponentialMovingAverage(previous: recentSystemRms, sample: bufferRms)
        if bufferRms > Self.systemActiveFloor {
            latestSystemSignalAt = clock.now
        }
    }

    private func updateProcessedMicrophoneRms(with rms: Float) {
        recentProcessedMicRms = exponentialMovingAverage(previous: recentProcessedMicRms, sample: rms)
    }

    private func exponentialMovingAverage(previous: Float, sample: Float) -> Float {
        let alpha = Self.rmsEmaAlpha
        return (previous * (1 - alpha)) + (sample * alpha)
    }

    private func shouldSuppressMicrophoneChunkTranscription() -> Bool {
        guard recentSystemRms > Self.systemActiveFloor else { return false }
        guard let latestSystemSignalAt else { return false }
        guard latestSystemSignalAt.duration(to: clock.now) <= Self.systemSignalFreshnessWindow else { return false }

        let ratio = recentSystemRms / max(recentProcessedMicRms, Self.rmsEpsilon)
        return ratio >= Self.systemDominanceRatio
    }

    private func logJoinerDiagnostics(_ diagnostics: [MeetingAudioJoinerDiagnostic]) {
        guard !diagnostics.isEmpty else { return }
        for diagnostic in diagnostics {
            switch diagnostic.kind {
            case .queueOverflow(let source, let droppedFrames, let queueDepth):
                logger.notice(
                    "Meeting joiner overflow source=\(source.rawValue, privacy: .public) dropped_frames=\(droppedFrames) queue_depth=\(queueDepth)"
                )
            }
        }
    }

    private func observePairSyncLag(
        microphoneHostTime: UInt64?,
        systemHostTime: UInt64?
    ) {
        guard let micHostTime = microphoneHostTime, let systemHostTime = systemHostTime else { return }
        let micSeconds = AVAudioTime.seconds(forHostTime: micHostTime)
        let systemSeconds = AVAudioTime.seconds(forHostTime: systemHostTime)
        let lagMs = (micSeconds - systemSeconds) * 1000

        let ema: Double
        if let existing = syncLagEmaMs {
            ema = existing + Self.syncLagEmaAlpha * (lagMs - existing)
        } else {
            ema = lagMs
        }
        syncLagEmaMs = ema

        let bucket = Int((ema / Double(Self.syncLagLogBucketMs)).rounded()) * Self.syncLagLogBucketMs
        if bucket != lastLoggedSyncLagBucketMs {
            logger.debug(
                "Meeting sync lag raw_ms=\(lagMs, privacy: .public) ema_ms=\(ema, privacy: .public)"
            )
            lastLoggedSyncLagBucketMs = bucket
        }

        let warning = abs(ema) >= Self.syncLagWarningThresholdMs
        if warning != syncLagWarningActive {
            if warning {
                logger.notice("Meeting sync lag warning ema_ms=\(ema, privacy: .public)")
            } else {
                logger.info("Meeting sync lag recovered ema_ms=\(ema, privacy: .public)")
            }
            syncLagWarningActive = warning
        }
    }

    private func shouldTranscribeChunk(_ chunk: AudioChunker.AudioChunk) -> Bool {
        chunkRms(for: chunk.samples) > Self.chunkSignalFloor
    }

    private func chunkRms(for samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        return sqrt(sumSquares / Float(samples.count))
    }

    private func cleanupState() {
        currentSession = nil
        micConditioner = SoftwareAECConditioner()
        latestLevels = MeetingAudioLevels()
        recentSystemRms = 0
        recentProcessedMicRms = 0
        latestSystemSignalAt = nil
        syncLagEmaMs = nil
        syncLagWarningActive = false
        lastLoggedSyncLagBucketMs = nil
        transcriptAssembler.reset()
        chunkTranscriptionFailed = false
        isTranscriptionLagging = false
        captureFailed = false
        transcriptContinuation?.finish()
        transcriptContinuation = nil
        cachedTranscriptUpdates = nil
    }

    private static func makeDisplayName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Meeting \(formatter.string(from: date))"
    }
}
