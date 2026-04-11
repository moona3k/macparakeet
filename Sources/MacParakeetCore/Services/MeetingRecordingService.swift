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

    private struct PendingChunkTask: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingRecordingService")
    private let clock = ContinuousClock()
    private let audioCaptureService: any MeetingAudioCapturing
    private let audioConverter: any AudioFileConverting
    private let sttTranscriber: STTTranscribing
    private let fileManager: FileManager

    private var currentSession: Session?
    private var writer: MeetingAudioStorageWriter?
    private var processingTask: Task<Void, Never>?
    private var pendingChunkTasks: [PendingChunkTask] = []
    private var nextChunkSequence: [AudioSource: Int] = [:]
    private var sourceTimelineOffsetsMs: [AudioSource: Int] = [:]
    private var pairJoiner = MeetingAudioPairJoiner()
    private var microphoneChunker = AudioChunker()
    private var systemChunker = AudioChunker()
    private var chunkResultBuffer = MeetingChunkResultBuffer()
    private var transcriptAssembler = MeetingTranscriptAssembler()
    private var chunkTranscriptionFailed = false
    private var isTranscriptionLagging = false
    private var captureFailed = false
    private var latestLevels = MeetingAudioLevels()
    private var recentSystemRms: Float = 0
    private var recentProcessedMicRms: Float = 0
    private var latestSystemSignalAt: ContinuousClock.Instant?
    private var softwareAEC = MeetingSoftwareAEC()
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
        audioCaptureService: any MeetingAudioCapturing = MeetingAudioCaptureService(),
        audioConverter: any AudioFileConverting = AudioFileConverter(),
        sttTranscriber: STTTranscribing,
        fileManager: FileManager = .default
    ) {
        self.audioCaptureService = audioCaptureService
        self.audioConverter = audioConverter
        self.sttTranscriber = sttTranscriber
        self.fileManager = fileManager
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
        self.pendingChunkTasks = []
        self.nextChunkSequence = [:]
        pairJoiner.reset()
        await microphoneChunker.reset()
        await systemChunker.reset()
        chunkResultBuffer.reset()
        transcriptAssembler.reset()
        chunkTranscriptionFailed = false
        isTranscriptionLagging = false
        captureFailed = false
        recentSystemRms = 0
        recentProcessedMicRms = 0
        latestSystemSignalAt = nil
        softwareAEC.reset()
        syncLagEmaMs = nil
        syncLagWarningActive = false
        lastLoggedSyncLagBucketMs = nil

        processingTask = Task { [weak self] in
            guard let self else { return }
            for await event in events {
                await self.handleCaptureEvent(event)
            }
        }

        do {
            try await audioCaptureService.start()
            logger.info("Meeting recording started: \(sessionID.uuidString, privacy: .public)")
        } catch {
            processingTask?.cancel()
            processingTask = nil
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
        await flushPendingJoinedFrames(for: session)
        await flushTranscriptChunkers(for: session)
        // If live preview falls behind, discard partial speaker metadata so
        // finalization can rebuild speakers from the mixed recording instead.
        let preparedTranscriptReady = await waitForPendingChunkTasksToDrain(timeout: .milliseconds(150))
        if !preparedTranscriptReady {
            await cancelPendingChunkTasks(waitForCancellation: false)
        }
        writer?.finalize()
        writer = nil

        let inputURLs = try existingSourceURLs(for: session)
        guard !inputURLs.isEmpty else {
            cleanupState()
            throw MeetingAudioError.noAudioCaptured
        }

        do {
            try await audioConverter.mixToM4A(inputURLs: inputURLs, outputURL: session.mixedAudioURL)
        } catch {
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
        await cancelPendingChunkTasks(waitForCancellation: true)
        writer?.finalize()
        writer = nil
        cleanupState()
        try? fileManager.removeItem(at: session.folderURL)
        logger.info("Meeting recording cancelled: \(session.id.uuidString, privacy: .public)")
    }

    private func handleCaptureEvent(_ event: MeetingAudioCaptureEvent) async {
        switch event {
        case .microphoneBuffer(let buffer, let time):
            do {
                try writer?.write(buffer, source: .microphone)
                latestLevels.microphone = buffer.rmsLevel
                if let samples = AudioChunker.extractAndResample(from: buffer),
                   let session = currentSession {
                    await ingestResampledSamples(
                        samples,
                        source: .microphone,
                        hostTime: time.isHostTimeValid ? time.hostTime : nil,
                        session: session
                    )
                }
            } catch {
                logger.error("Failed to write microphone audio: \(error.localizedDescription, privacy: .public)")
            }
        case .systemBuffer(let buffer, let time):
            do {
                try writer?.write(buffer, source: .system)
                latestLevels.system = buffer.rmsLevel
                updateSystemRms(with: latestLevels.system)
                if let samples = AudioChunker.extractAndResample(from: buffer),
                   let session = currentSession {
                    await ingestResampledSamples(
                        samples,
                        source: .system,
                        hostTime: time.isHostTimeValid ? time.hostTime : nil,
                        session: session
                    )
                }
            } catch {
                logger.error("Failed to write system audio: \(error.localizedDescription, privacy: .public)")
            }
        case .error(let error):
            captureFailed = true
            logger.error("Meeting capture event error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ingestResampledSamples(
        _ samples: [Float],
        source: AudioSource,
        hostTime: UInt64?,
        session: Session
    ) async {
        pairJoiner.push(samples: samples, hostTime: hostTime, source: source)
        logJoinerDiagnostics(pairJoiner.drainDiagnostics())
        for pair in pairJoiner.drainPairs() {
            await processJoinedPair(pair, session: session)
        }
    }

    private func processJoinedPair(_ pair: MeetingAudioPair, session: Session) async {
        observePairSyncLag(pair)

        if pair.hasMicrophoneSignal {
            let processedMicrophone = softwareAEC.process(
                microphone: pair.microphoneSamples,
                speaker: pair.systemSamples
            )
            updateProcessedMicrophoneRms(with: chunkRms(for: processedMicrophone))
            if let microphoneChunk = offsetChunk(
                await microphoneChunker.addSamples(processedMicrophone),
                source: .microphone,
                hostTime: pair.microphoneHostTime
            ) {
                if !shouldTranscribeChunk(microphoneChunk) {
                    logger.debug("Skipping low-signal microphone chunk")
                } else if shouldSuppressMicrophoneChunkTranscription() {
                    logger.debug("Suppressing microphone chunk due to dominant recent system audio")
                } else {
                    enqueueTranscription(for: microphoneChunk, source: .microphone, session: session)
                }
            }
        }

        if pair.hasSystemSignal {
            if let systemChunk = offsetChunk(
                await systemChunker.addSamples(pair.systemSamples),
                source: .system,
                hostTime: pair.systemHostTime
            ) {
                if shouldTranscribeChunk(systemChunk) {
                    enqueueTranscription(for: systemChunk, source: .system, session: session)
                } else {
                    logger.debug("Skipping low-signal system chunk")
                }
            }
        }
    }

    private func flushTranscriptChunkers(for session: Session) async {
        if let chunk = offsetChunk(await microphoneChunker.flush(), source: .microphone) {
            if !shouldTranscribeChunk(chunk) {
                logger.debug("Skipping low-signal flushed microphone chunk")
            } else if shouldSuppressMicrophoneChunkTranscription() {
                logger.debug("Suppressing flushed microphone chunk due to dominant recent system audio")
            } else {
                enqueueTranscription(for: chunk, source: .microphone, session: session)
            }
        }
        if let chunk = offsetChunk(await systemChunker.flush(), source: .system) {
            if shouldTranscribeChunk(chunk) {
                enqueueTranscription(for: chunk, source: .system, session: session)
            } else {
                logger.debug("Skipping low-signal flushed system chunk")
            }
        }
    }

    private func flushPendingJoinedFrames(for session: Session) async {
        for pair in pairJoiner.flushRemainingPairs() {
            await processJoinedPair(pair, session: session)
        }
    }

    private func offsetChunk(
        _ chunk: AudioChunker.AudioChunk?,
        source: AudioSource,
        hostTime: UInt64? = nil
    ) -> AudioChunker.AudioChunk? {
        guard let chunk else { return nil }
        let offsetMs = timelineOffsetMs(for: source, hostTime: hostTime)
        guard offsetMs != 0 else { return chunk }
        return AudioChunker.AudioChunk(
            samples: chunk.samples,
            startMs: chunk.startMs + offsetMs,
            endMs: chunk.endMs + offsetMs
        )
    }

    private func timelineOffsetMs(for source: AudioSource, hostTime: UInt64?) -> Int {
        if let existing = sourceTimelineOffsetsMs[source] {
            return existing
        }
        guard let hostTime else {
            return 0
        }

        let offsetMs = Int((AVAudioTime.seconds(forHostTime: hostTime) * 1000).rounded())
        sourceTimelineOffsetsMs[source] = offsetMs
        return offsetMs
    }

    private func enqueueTranscription(
        for chunk: AudioChunker.AudioChunk,
        source: AudioSource,
        session: Session
    ) {
        let sequence = nextChunkSequence[source] ?? 0
        nextChunkSequence[source] = sequence + 1

        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }

            do {
                let result = try await self.transcribeChunk(chunk, source: source, session: session)
                await self.handleChunkTranscriptionResult(
                    result,
                    chunk: chunk,
                    source: source,
                    sequence: sequence,
                    sessionID: session.id
                )
            } catch is CancellationError {
                // Cancellation is expected when stopRecording prioritizes finalize.
            } catch {
                await self.handleChunkTranscriptionFailure(
                    error,
                    source: source,
                    sequence: sequence,
                    sessionID: session.id
                )
            }

            await self.removePendingChunkTask(id: taskID)
        }

        pendingChunkTasks.append(PendingChunkTask(id: taskID, task: task))
    }

    private func transcribeChunk(
        _ chunk: AudioChunker.AudioChunk,
        source: AudioSource,
        session: Session
    ) async throws -> STTResult {
        let chunkURL = session.chunkFolderURL
            .appendingPathComponent("\(source.rawValue)-\(chunk.startMs)-\(chunk.endMs).wav")
        try writeChunkAudio(samples: chunk.samples, to: chunkURL)
        defer { try? fileManager.removeItem(at: chunkURL) }
        return try await sttTranscriber.transcribe(
            audioPath: chunkURL.path,
            job: .meetingLiveChunk,
            onProgress: nil
        )
    }

    private func writeChunkAudio(samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw MeetingAudioError.storageFailed("invalid chunk format")
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw MeetingAudioError.storageFailed("failed to allocate chunk buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { pointer in
                channelData[0].update(from: pointer.baseAddress!, count: samples.count)
            }
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func handleChunkTranscriptionResult(
        _ result: STTResult,
        chunk: AudioChunker.AudioChunk,
        source: AudioSource,
        sequence: Int,
        sessionID: UUID
    ) {
        guard currentSession?.id == sessionID else { return }
        logger.info("Chunk transcribed: source=\(source.rawValue, privacy: .public) seq=\(sequence) words=\(result.words.count) range=\(chunk.startMs)-\(chunk.endMs)ms")
        let readyResults = chunkResultBuffer.receiveSuccess(
            sequence: sequence,
            source: source,
            chunk: chunk,
            result: result
        )

        for ready in readyResults {
            let update = transcriptAssembler.apply(result: ready.result, chunk: ready.chunk, source: source)
            yieldTranscriptUpdate(update)
        }
    }

    private func handleChunkTranscriptionFailure(
        _ error: Error,
        source: AudioSource,
        sequence: Int,
        sessionID: UUID
    ) {
        guard currentSession?.id == sessionID else { return }
        logger.notice("Chunk failed: source=\(source.rawValue, privacy: .public) seq=\(sequence) error=\(error.localizedDescription, privacy: .public)")

        let droppedByBackpressure =
            if case STTSchedulerError.droppedDueToBackpressure(job: .meetingLiveChunk) = error {
                true
            } else {
                false
            }

        if droppedByBackpressure {
            logger.notice("Meeting live chunk dropped by scheduler backpressure")
            isTranscriptionLagging = true
        } else {
            logger.error("Meeting chunk transcription failed: \(error.localizedDescription, privacy: .public)")
            chunkTranscriptionFailed = true
        }
        let readyResults = chunkResultBuffer.receiveFailure(sequence: sequence, source: source)
        for ready in readyResults {
            let update = transcriptAssembler.apply(result: ready.result, chunk: ready.chunk, source: source)
            yieldTranscriptUpdate(update)
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
        let candidates = [session.systemAudioURL, session.microphoneAudioURL]
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

    private func cancelPendingChunkTasks(waitForCancellation: Bool) async {
        let tasks = pendingChunkTasks.map(\.task)
        pendingChunkTasks = []

        for task in tasks {
            task.cancel()
        }

        guard waitForCancellation else { return }
        for task in tasks {
            await task.value
        }
    }

    private func waitForPendingChunkTasksToDrain(timeout: Duration) async -> Bool {
        let startedAt = ContinuousClock.now
        while !pendingChunkTasks.isEmpty {
            if startedAt.duration(to: .now) > timeout {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func removePendingChunkTask(id: UUID) {
        pendingChunkTasks.removeAll { $0.id == id }
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

    private func observePairSyncLag(_ pair: MeetingAudioPair) {
        guard let micHostTime = pair.microphoneHostTime, let systemHostTime = pair.systemHostTime else { return }
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
        pendingChunkTasks = []
        nextChunkSequence = [:]
        sourceTimelineOffsetsMs = [:]
        pairJoiner.reset()
        latestLevels = MeetingAudioLevels()
        recentSystemRms = 0
        recentProcessedMicRms = 0
        latestSystemSignalAt = nil
        softwareAEC.reset()
        syncLagEmaMs = nil
        syncLagWarningActive = false
        lastLoggedSyncLagBucketMs = nil
        chunkResultBuffer.reset()
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
