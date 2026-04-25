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
    /// `title` lets callers (e.g., the calendar auto-start path) pre-name
    /// the recording. `nil` or whitespace-only falls back to the default
    /// "Meeting <date>" label.
    func startRecording(title: String?) async throws
    func stopRecording() async throws -> MeetingRecordingOutput
    func completeTranscription(for recording: MeetingRecordingOutput) async
    func cancelRecording() async
    var isRecording: Bool { get async }
    var micLevel: Float { get async }
    var systemLevel: Float { get async }
    var elapsedSeconds: Int { get async }
    var captureMode: CaptureMode { get async }
    var transcriptUpdates: AsyncStream<MeetingTranscriptUpdate> { get async }
}

public extension MeetingRecordingServiceProtocol {
    /// Existing manual / hotkey callers use the no-arg form — the calendar
    /// path is the only caller that has a meaningful title to pass.
    func startRecording() async throws {
        try await startRecording(title: nil)
    }
}

public actor MeetingRecordingService: MeetingRecordingServiceProtocol {
    private struct SourceCaptureMetrics: Sendable {
        var firstHostTime: UInt64?
        var lastHostTime: UInt64?
    }

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
    private let lockFileStore: MeetingRecordingLockFileStoring

    private var currentSession: Session?
    private var writer: MeetingAudioStorageWriter?
    private var processingTask: Task<Void, Never>?
    private var captureOrchestrator = CaptureOrchestrator()
    private var micConditioner: any MicConditioning = SoftwareAECConditioner()
    private var transcriptAssembler = MeetingTranscriptAssembler()
    private var isTranscriptionLagging = false
    private var captureFailed = false
    private var sourceCaptureMetrics: [AudioSource: SourceCaptureMetrics] = [:]
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
        lockFileStore: MeetingRecordingLockFileStoring = MeetingRecordingLockFileStore(),
        fileManager: FileManager = .default
    ) {
        self.requestedMicProcessingMode = micProcessingMode
        self.audioCaptureService = audioCaptureService ?? MeetingAudioCaptureService(
            micProcessingMode: micProcessingMode
        )
        self.audioConverter = audioConverter
        self.lockFileStore = lockFileStore
        self.fileManager = fileManager
        self.liveChunkTranscriber = LiveChunkTranscriber(sttTranscriber: sttTranscriber)
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

    public func startRecording(title: String? = nil) async throws {
        guard currentSession == nil else {
            throw MeetingAudioError.alreadyRunning
        }

        let sessionID = UUID()
        let folderURL = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        let writer = try MeetingAudioStorageWriter(folderURL: folderURL)
        let chunkFolderURL = folderURL.appendingPathComponent("chunks", isDirectory: true)
        try fileManager.createDirectory(at: chunkFolderURL, withIntermediateDirectories: true)
        // Single timestamp shared between displayName fallback and
        // startedAt — back-to-back `Date()` calls would only diverge if
        // the clock ticked over a minute boundary between them, which is
        // vanishingly rare but trivially avoidable.
        let now = Date()
        let session = Session(
            id: sessionID,
            displayName: Self.resolveDisplayName(title: title, fallbackDate: now),
            startedAt: now,
            folderURL: folderURL,
            chunkFolderURL: chunkFolderURL,
            microphoneAudioURL: writer.microphoneAudioURL,
            systemAudioURL: writer.systemAudioURL,
            mixedAudioURL: writer.mixedAudioURL
        )

        do {
            try lockFileStore.write(
                MeetingRecordingLockFile(
                    sessionId: session.id,
                    startedAt: session.startedAt,
                    pid: ProcessInfo.processInfo.processIdentifier,
                    displayName: session.displayName,
                    folderURL: session.folderURL
                ),
                folderURL: session.folderURL
            )
        } catch {
            await writer.finalize()
            try? fileManager.removeItem(at: folderURL)
            throw error
        }

        let events = await audioCaptureService.events
        self.latestLevels = MeetingAudioLevels()
        self.writer = writer
        self.currentSession = session
        await captureOrchestrator.reset()
        micConditioner = SoftwareAECConditioner()
        transcriptAssembler.reset()
        isTranscriptionLagging = false
        captureFailed = false
        sourceCaptureMetrics = [:]
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
            let writer = self.writer
            self.writer = nil
            await writer?.finalize()
            cleanupState()
            try? lockFileStore.delete(folderURL: folderURL)
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
        let finalizedWriter = writer
        writer = nil
        await finalizedWriter?.finalize()
        let writerMetrics = [
            AudioSource.microphone: finalizedWriter?.metrics(for: .microphone),
            AudioSource.system: finalizedWriter?.metrics(for: .system),
        ]
        await liveChunkTranscriber.cancelPendingTasks(waitForCancellation: false)

        let inputURLs = try existingSourceURLs(for: session)
        guard !inputURLs.isEmpty else {
            await liveChunkTranscriber.finishSession()
            try? lockFileStore.delete(folderURL: session.folderURL)
            cleanupState()
            try? fileManager.removeItem(at: session.folderURL)
            throw MeetingAudioError.noAudioCaptured
        }

        let sourceAlignment = buildSourceAlignment(
            availableSources: Set(inputURLs.map(source(for:))),
            writerMetrics: writerMetrics
        )
        do {
            try MeetingRecordingMetadataStore.save(
                MeetingRecordingMetadata(sourceAlignment: sourceAlignment),
                folderURL: session.folderURL
            )
        } catch {
            await liveChunkTranscriber.finishSession()
            cleanupState()
            throw MeetingAudioError.storageFailed(error.localizedDescription)
        }

        do {
            try await audioConverter.mixToM4A(inputURLs: inputURLs, outputURL: session.mixedAudioURL)
        } catch {
            await liveChunkTranscriber.finishSession()
            cleanupState()
            throw MeetingAudioError.mixFailed(error.localizedDescription)
        }

        try? lockFileStore.write(
            MeetingRecordingLockFile(
                sessionId: session.id,
                startedAt: session.startedAt,
                pid: ProcessInfo.processInfo.processIdentifier,
                displayName: session.displayName,
                state: .awaitingTranscription,
                folderURL: session.folderURL
            ),
            folderURL: session.folderURL
        )

        let durationSeconds = max(0, Date().timeIntervalSince(session.startedAt))
        let output = MeetingRecordingOutput(
            sessionID: session.id,
            displayName: session.displayName,
            folderURL: session.folderURL,
            mixedAudioURL: session.mixedAudioURL,
            microphoneAudioURL: session.microphoneAudioURL,
            systemAudioURL: session.systemAudioURL,
            durationSeconds: durationSeconds,
            sourceAlignment: sourceAlignment
        )

        await liveChunkTranscriber.finishSession()
        cleanupState()
        logger.info("Meeting recording finalized: \(session.id.uuidString, privacy: .public)")
        return output
    }

    public func completeTranscription(for recording: MeetingRecordingOutput) async {
        do {
            try lockFileStore.delete(folderURL: recording.folderURL)
        } catch {
            logger.error("meeting_recording_lock_cleanup_failed session=\(recording.sessionID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    public func cancelRecording() async {
        guard let session = currentSession else { return }

        await audioCaptureService.stop()
        processingTask?.cancel()
        await processingTask?.value
        processingTask = nil
        await liveChunkTranscriber.cancelPendingTasks(waitForCancellation: true)
        await liveChunkTranscriber.finishSession()
        let finalizedWriter = writer
        writer = nil
        await finalizedWriter?.finalize()
        try? lockFileStore.delete(folderURL: session.folderURL)
        cleanupState()
        try? fileManager.removeItem(at: session.folderURL)
        logger.info("Meeting recording cancelled: \(session.id.uuidString, privacy: .public)")
    }

    private func handleCaptureEvent(_ event: MeetingAudioCaptureEvent) async {
        switch event {
        case .microphoneBuffer(let buffer, let time):
            guard !captureFailed else { return }
            do {
                recordCaptureMetrics(for: .microphone, time: time)
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
                await failCapture(error)
            }
        case .systemBuffer(let buffer, let time):
            guard !captureFailed else { return }
            do {
                recordCaptureMetrics(for: .system, time: time)
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
                await failCapture(error)
            }
        case .error(let error):
            guard !captureFailed else { return }
            await failCapture(error)
        }
    }

    private func failCapture(_ error: Error) async {
        captureFailed = true
        latestLevels = MeetingAudioLevels()
        logger.error("Meeting capture failed: \(error.localizedDescription, privacy: .public)")
        await audioCaptureService.stop()
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
                let micRms = chunkRms(for: chunk.chunk.samples)
                if micRms <= Self.chunkSignalFloor {
                    logger.notice(
                        "mic_chunk_dropped reason=low_signal flushed=\(flushed, privacy: .public) rms=\(micRms, privacy: .public) floor=\(Self.chunkSignalFloor, privacy: .public)"
                    )
                } else if shouldSuppressMicrophoneChunkTranscription() {
                    let ratio = recentSystemRms / max(recentProcessedMicRms, Self.rmsEpsilon)
                    logger.notice(
                        "mic_chunk_dropped reason=system_dominant flushed=\(flushed, privacy: .public) sys_rms=\(self.recentSystemRms, privacy: .public) proc_mic_rms=\(self.recentProcessedMicRms, privacy: .public) ratio=\(ratio, privacy: .public) threshold=\(Self.systemDominanceRatio, privacy: .public)"
                    )
                } else {
                    await liveChunkTranscriber.enqueue(chunk: chunk.chunk, source: .microphone)
                }
            case .system:
                if shouldTranscribeChunk(chunk.chunk) {
                    await liveChunkTranscriber.enqueue(chunk: chunk.chunk, source: .system)
                } else {
                    let sysRms = chunkRms(for: chunk.chunk.samples)
                    logger.notice(
                        "system_chunk_dropped reason=low_signal flushed=\(flushed, privacy: .public) rms=\(sysRms, privacy: .public) floor=\(Self.chunkSignalFloor, privacy: .public)"
                    )
                }
            }
        }
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

    private func recordCaptureMetrics(for source: AudioSource, time: AVAudioTime) {
        guard time.isHostTimeValid else { return }
        var metrics = sourceCaptureMetrics[source] ?? SourceCaptureMetrics()
        if metrics.firstHostTime == nil {
            metrics.firstHostTime = time.hostTime
        }
        metrics.lastHostTime = time.hostTime
        sourceCaptureMetrics[source] = metrics
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

    private func source(for url: URL) -> AudioSource {
        if url == currentSession?.microphoneAudioURL {
            return .microphone
        }
        if url != currentSession?.systemAudioURL {
            assertionFailure("Unexpected URL passed to source(for:): \(url.path)")
        }
        return .system
    }

    private func buildSourceAlignment(
        availableSources: Set<AudioSource>,
        writerMetrics: [AudioSource: MeetingAudioStorageWriter.SourceWriteMetrics?]
    ) -> MeetingSourceAlignment {
        let candidateOrigins = availableSources.compactMap { sourceCaptureMetrics[$0]?.firstHostTime }
        let meetingOriginHostTime = candidateOrigins.min()

        let microphone = availableSources.contains(.microphone)
            ? makeAlignedTrack(
                source: .microphone,
                meetingOriginHostTime: meetingOriginHostTime,
                writerMetrics: writerMetrics[.microphone] ?? nil
            )
            : nil
        let system = availableSources.contains(.system)
            ? makeAlignedTrack(
                source: .system,
                meetingOriginHostTime: meetingOriginHostTime,
                writerMetrics: writerMetrics[.system] ?? nil
            )
            : nil

        return .make(
            meetingOriginHostTime: meetingOriginHostTime,
            microphone: microphone,
            system: system
        )
    }

    private func makeAlignedTrack(
        source: AudioSource,
        meetingOriginHostTime: UInt64?,
        writerMetrics: MeetingAudioStorageWriter.SourceWriteMetrics?
    ) -> MeetingSourceAlignment.Track {
        let captureMetrics = sourceCaptureMetrics[source]
        return MeetingSourceAlignment.Track(
            firstHostTime: captureMetrics?.firstHostTime,
            lastHostTime: captureMetrics?.lastHostTime,
            startOffsetMs: MeetingSourceAlignment.startOffsetMs(
                hostTime: captureMetrics?.firstHostTime,
                originHostTime: meetingOriginHostTime
            ),
            writtenFrameCount: writerMetrics?.writtenFrameCount ?? 0,
            sampleRate: writerMetrics?.sampleRate ?? 48_000
        )
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
        sourceCaptureMetrics = [:]
        recentSystemRms = 0
        recentProcessedMicRms = 0
        latestSystemSignalAt = nil
        syncLagEmaMs = nil
        syncLagWarningActive = false
        lastLoggedSyncLagBucketMs = nil
        transcriptAssembler.reset()
        isTranscriptionLagging = false
        captureFailed = false
        transcriptContinuation?.finish()
        transcriptContinuation = nil
        cachedTranscriptUpdates = nil
    }

    private static func resolveDisplayName(title: String?, fallbackDate: Date) -> String {
        if let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        return makeDisplayName(for: fallbackDate)
    }

    private static func makeDisplayName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Meeting \(formatter.string(from: date))"
    }
}
