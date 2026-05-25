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
    /// Recording is active but capture is intentionally paused. Buffers
    /// from the OS streams are discarded by the service; the storage
    /// writer's PTS counter is preserved so resumed audio appends gap-free
    /// in playback.
    case paused
    case stopped
}

public struct MeetingMicrophoneMuteState: Sendable, Equatable {
    public let isMuted: Bool
    public let canMute: Bool

    public init(isMuted: Bool, canMute: Bool) {
        self.isMuted = isMuted
        self.canMute = canMute
    }
}

public protocol MeetingRecordingServiceProtocol: Sendable {
    /// `title` lets callers (e.g., the calendar auto-start path) pre-name
    /// the recording. `nil` or whitespace-only falls back to the default
    /// "Meeting <date>" label.
    func startRecording(title: String?, sourceMode: MeetingAudioSourceMode?) async throws
    func stopRecording() async throws -> MeetingRecordingOutput
    func completeTranscription(for recording: MeetingRecordingOutput) async
    /// Release any retained speech-engine lease for a stopped recording after
    /// the final transcription attempt has ended. Use `completeTranscription`
    /// on success so the recovery lock is deleted; call this directly on failure
    /// to leave the lock available for retry.
    func finishTranscriptionAttempt(for recording: MeetingRecordingOutput) async
    func cancelRecording() async
    /// Pause an active recording. No-op when no session is active or when
    /// already paused. The OS-level capture stays running (mic + ScreenCaptureKit
    /// keep delivering buffers); the service simply discards incoming buffers
    /// until `resumeRecording` is called. The audio file's PTS counter is
    /// preserved so resumed audio appends gap-free in playback.
    func pauseRecording() async
    /// Resume a paused recording. No-op when no session is active or when
    /// not currently paused.
    func resumeRecording() async
    /// Mute or unmute the meeting microphone source without pausing system
    /// audio capture. No-op for system-only recordings.
    @discardableResult
    func setMicrophoneMuted(_ muted: Bool) async -> MeetingMicrophoneMuteState
    /// Persist the user's in-flight notepad text to the recording's lock file
    /// without changing the recording state. Called by the notes view model on
    /// every idle-debounce fire (ADR-020 §8). All `recording.lock` writes are
    /// serialized through this actor — no other component touches the file —
    /// so notes-saves cannot race with state-transition writes.
    func updateNotes(_ notes: String) async
    var isRecording: Bool { get async }
    var isPaused: Bool { get async }
    var micLevel: Float { get async }
    var systemLevel: Float { get async }
    var elapsedSeconds: Int { get async }
    var captureMode: CaptureMode { get async }
    var isMicrophoneMuted: Bool { get async }
    var canMuteMicrophone: Bool { get async }
    var microphoneMuteState: MeetingMicrophoneMuteState { get async }
    var transcriptUpdates: AsyncStream<MeetingTranscriptUpdate> { get async }
}

public extension MeetingRecordingServiceProtocol {
    /// Existing manual / hotkey callers use the no-arg form — the calendar
    /// path is the only caller that has a meaningful title to pass.
    func startRecording(title: String?) async throws {
        try await startRecording(title: title, sourceMode: nil)
    }

    func startRecording() async throws {
        try await startRecording(title: nil, sourceMode: nil)
    }
}

public actor MeetingRecordingService: MeetingRecordingServiceProtocol {
    private struct SourceCaptureMetrics: Sendable {
        var firstHostTime: UInt64?
        var lastHostTime: UInt64?
    }

    private struct CaptureHealthMetrics: Sendable {
        var sourceMode: MeetingAudioSourceMode?
        var requestedMicMode: MeetingMicProcessingMode?
        var effectiveMicMode: MeetingMicProcessingEffectiveMode?
        var microphoneStarted = false
        var microphoneFirstBufferSeen = false
        var systemFirstBufferSeen = false
        var microphoneChunksEnqueued = 0
        var systemChunksEnqueued = 0
        var microphoneLowSignalDrops = 0
        var systemLowSignalDrops = 0
        var microphoneSystemDominantDrops = 0
        var backpressureDrops = 0
        var transcriptionFailures = 0
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
        let speechEngine: SpeechEngineSelection
    }

    private struct HostTimeRange: Sendable {
        let start: UInt64
        let end: UInt64

        func contains(_ hostTime: UInt64) -> Bool {
            start <= hostTime && hostTime < end
        }
    }

    private enum CaptureBufferHandling {
        case recordAndProcess
        case preserveAudioOnly
        case drop
    }

    private final class ProcessingDrainFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func markDrained() {
            lock.withLock {
                value = true
            }
        }

        var drained: Bool {
            lock.withLock { value }
        }
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingRecordingService")
    private let clock = ContinuousClock()
    private let audioCaptureService: any MeetingAudioCapturing
    private let audioConverter: any AudioFileConverting
    private let fileManager: FileManager
    private let requestedMicProcessingMode: MeetingMicProcessingMode
    private let liveChunkTranscriber: LiveChunkTranscriber
    private let lockFileStore: MeetingRecordingLockFileStoring
    private let speechEngineSessionManager: (any SpeechEngineSessionManaging)?
    private let micConditionerFactory: @Sendable () -> any MicConditioning

    private var currentSession: Session?
    /// Buffer-discard flag for pause/resume. Reset in `cleanupState`.
    private var paused = false
    private var pausedAt: Date?
    private var pausedHostTime: UInt64?
    private var completedPauseHostTimeRanges: [HostTimeRange] = []
    private var accumulatedPausedDuration: TimeInterval = 0
    /// Meeting-local microphone mute. We keep the OS mic stream alive and
    /// write silence into the mic source file while muted so the mic and
    /// system tracks stay time-aligned for the final mix.
    private var microphoneMuted = false
    private var microphoneMutedHostTime: UInt64?
    private var completedMicrophoneMuteHostTimeRanges: [HostTimeRange] = []
    private var reusableMicrophoneSilentBuffer: AVAudioPCMBuffer?
    /// In-flight notes text for the current session. Mutated by `updateNotes`
    /// on each VM debounce; read at finalize time and surfaced via
    /// `MeetingRecordingOutput.userNotes`. `nil` when no notes have been
    /// typed (which we preserve as `nil` rather than empty so downstream
    /// `Transcription.userNotes` is `nil` for non-notepad recordings).
    private var currentNotes: String?
    /// In-memory mirror of the session's `recording.lock` content. Held so
    /// `updateNotes` can persist notes by mutating + atomic-writing in one
    /// step instead of read-modify-write on every keystroke debounce. The
    /// actor isolation already serializes lock-file writes with state
    /// transitions; the disk read was redundant. Initialized in
    /// `startRecording`, mutated by state transitions, cleared in
    /// `cleanupState` / `cancelRecording`.
    private var currentLockFile: MeetingRecordingLockFile?
    private var currentSpeechEngineLease: SpeechEngineLease?
    private var stoppedSpeechEngineLeases: [UUID: SpeechEngineLease] = [:]
    /// Keeps replacement starts out while `audioCaptureService.start()` is still
    /// unwinding after cancellation. `currentSession` may already be nil then.
    private var startingSessionID: UUID?
    private var writer: MeetingAudioStorageWriter?
    private var processingTask: Task<Void, Never>?
    private var captureOrchestrator = CaptureOrchestrator()
    private var micConditioner: any MicConditioning = PassthroughMicConditioner()
    private var transcriptAssembler = MeetingTranscriptAssembler()
    private var isTranscriptionLagging = false
    private var captureFailed = false
    private var interruptedSources: Set<AudioSource> = []
    private var sourceCaptureMetrics: [AudioSource: SourceCaptureMetrics] = [:]
    private var captureHealthMetrics = CaptureHealthMetrics()
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
    private static let completedHostTimeRangeLimit = 512

    private static func currentAudioHostTime() -> UInt64 {
        AVAudioTime.hostTime(forSeconds: ProcessInfo.processInfo.systemUptime)
    }

    public init(
        micProcessingMode: MeetingMicProcessingMode = .raw,
        audioCaptureService: any MeetingAudioCapturing,
        audioConverter: any AudioFileConverting = AudioFileConverter(),
        sttTranscriber: STTTranscribing,
        lockFileStore: MeetingRecordingLockFileStoring = MeetingRecordingLockFileStore(),
        fileManager: FileManager = .default,
        echoSuppressionConfiguration: MeetingEchoSuppressionConfiguration = .fromEnvironment()
    ) {
        self.init(
            micProcessingMode: micProcessingMode,
            audioCaptureService: audioCaptureService,
            audioConverter: audioConverter,
            sttTranscriber: sttTranscriber,
            lockFileStore: lockFileStore,
            fileManager: fileManager,
            micConditionerFactory: {
                MeetingEchoSuppressionFactory.makeConditioner(
                    configuration: echoSuppressionConfiguration
                )
            }
        )
    }

    init(
        micProcessingMode: MeetingMicProcessingMode = .raw,
        audioCaptureService: any MeetingAudioCapturing,
        audioConverter: any AudioFileConverting = AudioFileConverter(),
        sttTranscriber: STTTranscribing,
        lockFileStore: MeetingRecordingLockFileStoring = MeetingRecordingLockFileStore(),
        fileManager: FileManager = .default,
        micConditionerFactory: @escaping @Sendable () -> any MicConditioning
    ) {
        self.requestedMicProcessingMode = micProcessingMode
        self.audioCaptureService = audioCaptureService
        self.audioConverter = audioConverter
        self.lockFileStore = lockFileStore
        self.fileManager = fileManager
        self.micConditionerFactory = micConditionerFactory
        self.liveChunkTranscriber = LiveChunkTranscriber(sttTranscriber: sttTranscriber)
        self.speechEngineSessionManager = sttTranscriber as? any SpeechEngineSessionManaging
    }

    public var isRecording: Bool {
        currentSession != nil
    }

    public var isPaused: Bool {
        paused
    }

    public var micLevel: Float {
        latestLevels.microphone
    }

    public var systemLevel: Float {
        latestLevels.system
    }

    public var elapsedSeconds: Int {
        guard let startedAt = currentSession?.startedAt else { return 0 }
        return max(0, Int(activeRecordingSeconds(startedAt: startedAt, asOf: Date())))
    }

    public var captureMode: CaptureMode {
        if currentSession == nil || captureFailed {
            return .stopped
        }
        return paused ? .paused : .full
    }

    public var isMicrophoneMuted: Bool {
        microphoneMuted
    }

    public var canMuteMicrophone: Bool {
        currentSession != nil
            && !captureFailed
            && captureHealthMetrics.sourceMode?.capturesMicrophone == true
    }

    public var microphoneMuteState: MeetingMicrophoneMuteState {
        let canMute = canMuteMicrophone
        return MeetingMicrophoneMuteState(isMuted: canMute && microphoneMuted, canMute: canMute)
    }

    /// Wallclock-since-start minus all pause time (completed + ongoing).
    /// Used for both the live elapsed timer and the persisted
    /// `MeetingRecordingOutput.durationSeconds`.
    private func activeRecordingSeconds(startedAt: Date, asOf now: Date) -> TimeInterval {
        let rawElapsed = now.timeIntervalSince(startedAt)
        let ongoingPause = pausedAt.map { now.timeIntervalSince($0) } ?? 0
        return max(0, rawElapsed - accumulatedPausedDuration - ongoingPause)
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

    public func startRecording(
        title: String? = nil,
        sourceMode: MeetingAudioSourceMode? = nil
    ) async throws {
        guard currentSession == nil, startingSessionID == nil else {
            throw MeetingAudioError.alreadyRunning
        }

        let sessionID = UUID()
        startingSessionID = sessionID
        defer {
            if startingSessionID == sessionID {
                startingSessionID = nil
            }
        }

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
        let speechEngineLease = await speechEngineSessionManager?.beginSpeechEngineSession()
        currentSpeechEngineLease = speechEngineLease
        let speechEngine = speechEngineLease?.selection ?? SpeechEngineSelection(engine: .parakeet)
        let session = Session(
            id: sessionID,
            displayName: Self.resolveDisplayName(title: title, fallbackDate: now),
            startedAt: now,
            folderURL: folderURL,
            chunkFolderURL: chunkFolderURL,
            microphoneAudioURL: writer.microphoneAudioURL,
            systemAudioURL: writer.systemAudioURL,
            mixedAudioURL: writer.mixedAudioURL,
            speechEngine: speechEngine
        )
        self.writer = writer
        self.currentSession = session

        do {
            let initialLock = MeetingRecordingLockFile(
                sessionId: session.id,
                startedAt: session.startedAt,
                pid: ProcessInfo.processInfo.processIdentifier,
                displayName: session.displayName,
                speechEngine: session.speechEngine,
                folderURL: session.folderURL
            )
            try lockFileStore.write(initialLock, folderURL: session.folderURL)
            currentLockFile = initialLock

            let events = await audioCaptureService.events
            try await validateStartStillCurrent(session)
            self.latestLevels = MeetingAudioLevels()
            await captureOrchestrator.reset()
            try await validateStartStillCurrent(session)
            micConditioner = micConditionerFactory()
            micConditioner.reset()
            transcriptAssembler.reset()
            isTranscriptionLagging = false
            captureFailed = false
            interruptedSources = []
            sourceCaptureMetrics = [:]
            captureHealthMetrics = CaptureHealthMetrics()
            recentSystemRms = 0
            recentProcessedMicRms = 0
            latestSystemSignalAt = nil
            syncLagEmaMs = nil
            syncLagWarningActive = false
            lastLoggedSyncLagBucketMs = nil

            await liveChunkTranscriber.startSession(
                .init(
                    id: session.id,
                    chunkFolderURL: session.chunkFolderURL,
                    speechEngine: session.speechEngine
                ),
                onEvent: { [weak self] event in
                    await self?.handleLiveChunkTranscriberEvent(event, sessionID: session.id)
                }
            )
            try await validateStartStillCurrent(session)

            let captureStartReport = try await audioCaptureService.start(sourceMode: sourceMode)
            try await validateStartStillCurrent(session)
            captureHealthMetrics.sourceMode = captureStartReport.sourceMode
            captureHealthMetrics.requestedMicMode = captureStartReport.microphone.requestedMode
            captureHealthMetrics.effectiveMicMode = captureStartReport.microphone.effectiveMode
            captureHealthMetrics.microphoneStarted = captureStartReport.microphoneStarted
            configureMicConditioner(from: captureStartReport)
            processingTask = Task { [weak self] in
                guard let self else { return }
                for await event in events {
                    await self.handleCaptureEvent(event)
                }
            }
            logger.info("Meeting recording started: \(sessionID.uuidString, privacy: .public)")
            AudioCaptureDiagnostics.append(
                "meeting_recording_started session=\(sessionID.uuidString) source_mode=\(String(describing: sourceMode)) requested_mic_mode=\(String(describing: captureStartReport.microphone.requestedMode)) effective_mic_mode=\(captureStartReport.microphone.effectiveMode.rawValue)"
            )
        } catch {
            AudioCaptureDiagnostics.append(
                "meeting_recording_start_failed session=\(sessionID.uuidString) \(AudioCaptureDiagnostics.errorFields(error))"
            )
            await cleanupFailedStart(folderURL: folderURL)
            throw error
        }
    }

    private func cleanupFailedStart(folderURL: URL) async {
        processingTask?.cancel()
        processingTask = nil
        await liveChunkTranscriber.finishSession()
        let writer = self.writer
        self.writer = nil
        await finalizeWriter(writer)
        await releaseSpeechEngineLease()
        cleanupState()

        do {
            try lockFileStore.delete(folderURL: folderURL)
        } catch {
            logFailedStartCleanupError(operation: "delete lock", error: error)
        }

        do {
            try fileManager.removeItem(at: folderURL)
        } catch {
            if !isMissingFileError(error) {
                logFailedStartCleanupError(operation: "remove folder", error: error)
            }
        }
    }

    private func logFailedStartCleanupError(operation: String, error: Error) {
        let nsError = error as NSError
        logger.warning(
            "Meeting failed-start cleanup \(operation, privacy: .public) failed: \(nsError.domain, privacy: .public)#\(nsError.code, privacy: .public)"
        )
    }

    private func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError
    }

    private func validateStartStillCurrent(_ session: Session) async throws {
        guard currentSession?.id == session.id else {
            await audioCaptureService.stop()
            throw CancellationError()
        }

        do {
            try Task.checkCancellation()
        } catch {
            await audioCaptureService.stop()
            throw error
        }
    }

    public func stopRecording() async throws -> MeetingRecordingOutput {
        guard let session = currentSession else {
            throw MeetingAudioError.notRunning
        }

        AudioCaptureDiagnostics.append(
            "meeting_recording_stopping session=\(session.id.uuidString)"
        )
        await audioCaptureService.stop()
        await drainProcessingTaskAfterCaptureStop()
        let finalizedWriter = writer
        writer = nil
        await finalizeWriter(finalizedWriter)
        let writerMetrics = [
            AudioSource.microphone: finalizedWriter?.metrics(for: .microphone),
            AudioSource.system: finalizedWriter?.metrics(for: .system),
        ]
        await liveChunkTranscriber.cancelPendingTasks(waitForCancellation: false)

        let inputURLs = try existingSourceURLs(for: session)
        guard !inputURLs.isEmpty else {
            AudioCaptureDiagnostics.append(
                captureHealthSummaryLine(
                    session: session,
                    durationSeconds: activeRecordingSeconds(startedAt: session.startedAt, asOf: Date()),
                    writerMetrics: writerMetrics,
                    captureFailed: captureFailed
                )
            )
            await liveChunkTranscriber.finishSession()
            try? lockFileStore.delete(folderURL: session.folderURL)
            await releaseSpeechEngineLease()
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
                MeetingRecordingMetadata(
                    sourceAlignment: sourceAlignment,
                    speechEngine: session.speechEngine
                ),
                folderURL: session.folderURL
            )
        } catch {
            await liveChunkTranscriber.finishSession()
            await releaseSpeechEngineLease()
            cleanupState()
            throw MeetingAudioError.storageFailed(error.localizedDescription)
        }

        do {
            try await audioConverter.mixToM4A(
                inputURLs: inputURLs,
                outputURL: session.mixedAudioURL,
                sourceAlignment: sourceAlignment
            )
        } catch {
            logger.error(
                "meeting_mix_failed_nonfatal session=\(session.id.uuidString, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
            preservePlayableMeetingAudioFallback(inputURLs: inputURLs, outputURL: session.mixedAudioURL)
        }

        let finalNotes = currentNotes
        let notesFileManager = MeetingNotesFile.SendableFileManager(fileManager)
        do {
            try await MeetingNotesFile.write(
                notes: finalNotes,
                displayName: session.displayName,
                to: session.folderURL,
                fileManager: notesFileManager
            )
        } catch {
            logger.warning(
                "meeting_notes_file_write_failed session=\(session.id.uuidString, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
        }

        let awaitingLock = (currentLockFile ?? MeetingRecordingLockFile(
            sessionId: session.id,
            startedAt: session.startedAt,
            pid: ProcessInfo.processInfo.processIdentifier,
            displayName: session.displayName,
            speechEngine: session.speechEngine,
            folderURL: session.folderURL
        ))
            .withNotes(finalNotes)
            .withState(.awaitingTranscription)
        try? lockFileStore.write(awaitingLock, folderURL: session.folderURL)
        currentLockFile = awaitingLock

        // Stop while paused: settle the in-flight pause interval into the
        // accumulated total so the persisted duration only reflects time
        // actually recording.
        let now = Date()
        if let pausedAtSnapshot = pausedAt {
            accumulatedPausedDuration += now.timeIntervalSince(pausedAtSnapshot)
            pausedAt = nil
        }
        paused = false
        let durationSeconds = max(0, activeRecordingSeconds(startedAt: session.startedAt, asOf: now))
        let output = MeetingRecordingOutput(
            sessionID: session.id,
            displayName: session.displayName,
            folderURL: session.folderURL,
            mixedAudioURL: session.mixedAudioURL,
            microphoneAudioURL: session.microphoneAudioURL,
            systemAudioURL: session.systemAudioURL,
            durationSeconds: durationSeconds,
            sourceAlignment: sourceAlignment,
            speechEngine: session.speechEngine,
            userNotes: finalNotes
        )

        await liveChunkTranscriber.finishSession()
        retainSpeechEngineLeaseForTranscription(sessionID: session.id)
        logger.info("Meeting recording finalized: \(session.id.uuidString, privacy: .public)")
        AudioCaptureDiagnostics.append(
            "meeting_recording_stopped session=\(session.id.uuidString) duration_s=\(String(format: "%.3f", durationSeconds))"
        )
        AudioCaptureDiagnostics.append(
            captureHealthSummaryLine(
                session: session,
                durationSeconds: durationSeconds,
                writerMetrics: writerMetrics,
                captureFailed: captureFailed
            )
        )
        AudioCaptureDiagnostics.append(
            echoSuppressionSummaryLine(session: session)
        )
        cleanupState()
        return output
    }

    public func completeTranscription(for recording: MeetingRecordingOutput) async {
        do {
            try lockFileStore.delete(folderURL: recording.folderURL)
        } catch {
            logger.error("meeting_recording_lock_cleanup_failed session=\(recording.sessionID.uuidString, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
        }
        await finishTranscriptionAttempt(for: recording)
    }

    public func finishTranscriptionAttempt(for recording: MeetingRecordingOutput) async {
        await releaseStoppedSpeechEngineLease(sessionID: recording.sessionID)
    }

    public func updateNotes(_ notes: String) async {
        guard let session = currentSession else { return }

        // Normalize empty / whitespace-only input back to `nil` so the
        // persisted lock-file `notes` field is absent rather than empty,
        // and so downstream `Transcription.userNotes` is `nil` for
        // recordings where the user typed nothing meaningful.
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String? = trimmed.isEmpty ? nil : notes
        currentNotes = normalized

        // Mutate the in-memory mirror and atomically rewrite. Actor
        // isolation already serializes us with state-transition writes
        // (`stopRecording` / `cancelRecording` / `startRecording`), so
        // reading the file back from disk on every keystroke debounce
        // would just be redundant I/O. `currentLockFile` is normally set
        // by `startRecording`; the fallback handles the vanishingly rare
        // case where a debounce somehow fires before initialization.
        let base = currentLockFile ?? MeetingRecordingLockFile(
            sessionId: session.id,
            startedAt: session.startedAt,
            pid: ProcessInfo.processInfo.processIdentifier,
            displayName: session.displayName,
            speechEngine: session.speechEngine,
            folderURL: session.folderURL
        )
        let updated = base.withNotes(normalized)
        do {
            try lockFileStore.write(updated, folderURL: session.folderURL)
            currentLockFile = updated
        } catch {
            // Notes persistence is best-effort — losing one debounce write to
            // an I/O error is preferable to surfacing a UI error mid-meeting.
            logger.error("meeting_recording_notes_persist_failed session=\(session.id.uuidString, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
        }
    }

    public func pauseRecording() async {
        guard currentSession != nil, !paused, !captureFailed else { return }
        paused = true
        pausedAt = Date()
        pausedHostTime = Self.currentAudioHostTime()
        // Zero levels so live UI reads "no signal" the moment the user
        // pauses, instead of decaying from the EMA over the next few
        // hundred ms. Same reasoning as the `failCapture` path.
        latestLevels = MeetingAudioLevels()
        recentSystemRms = 0
        recentProcessedMicRms = 0
        latestSystemSignalAt = nil
        // NOTE: Do NOT reset `captureOrchestrator` here. AudioChunker uses a
        // monotonic `totalSamplesProcessed` counter to derive chunk
        // timestamps, and `MeetingTranscriptAssembler.apply` dedupes new
        // words against `lastCommittedEndMs[source]`. Resetting the chunker
        // would zero its counter; post-resume chunks would emit at startMs
        // near 0; the assembler would silently drop every post-resume word
        // because `endMs <= cutoff`. The audio file is independent of the
        // chunker (the storage writer's PTS counter is preserved either
        // way), so a gap-free playback timeline is guaranteed without the
        // reset. The cost of leaving the chunker alone is that the first
        // chunk straddling the pause boundary may concatenate pre-pause
        // and post-resume samples (an at-most-5s artifact in the LIVE
        // transcript only — the post-stop final transcription re-runs the
        // audio file end-to-end and is unaffected).
        AudioCaptureDiagnostics.append(
            "meeting_recording_paused session=\(currentSession?.id.uuidString ?? "nil")"
        )
    }

    public func resumeRecording() async {
        guard currentSession != nil, paused, !captureFailed else { return }
        if let pausedAt {
            accumulatedPausedDuration += Date().timeIntervalSince(pausedAt)
        }
        if let pausedHostTime {
            appendCompletedPauseHostTimeRange(start: pausedHostTime, end: Self.currentAudioHostTime())
        }
        self.pausedHostTime = nil
        pausedAt = nil
        paused = false
        AudioCaptureDiagnostics.append(
            "meeting_recording_resumed session=\(currentSession?.id.uuidString ?? "nil") accumulated_paused_s=\(String(format: "%.3f", accumulatedPausedDuration))"
        )
    }

    @discardableResult
    public func setMicrophoneMuted(_ muted: Bool) async -> MeetingMicrophoneMuteState {
        guard canMuteMicrophone, microphoneMuted != muted else { return microphoneMuteState }

        microphoneMuted = muted
        if muted {
            microphoneMutedHostTime = Self.currentAudioHostTime()
            latestLevels.microphone = 0
            recentProcessedMicRms = 0
        } else {
            if let microphoneMutedHostTime {
                appendCompletedMicrophoneMuteHostTimeRange(
                    start: microphoneMutedHostTime,
                    end: Self.currentAudioHostTime()
                )
            }
            microphoneMutedHostTime = nil
        }

        AudioCaptureDiagnostics.append(
            "meeting_microphone_\(muted ? "muted" : "unmuted") session=\(currentSession?.id.uuidString ?? "nil")"
        )
        return microphoneMuteState
    }

    public func cancelRecording() async {
        guard let session = currentSession else { return }

        await audioCaptureService.stop()
        await drainProcessingTaskAfterCaptureStop()
        await liveChunkTranscriber.cancelPendingTasks(waitForCancellation: true)
        await liveChunkTranscriber.finishSession()
        let finalizedWriter = writer
        writer = nil
        await finalizeWriter(finalizedWriter)
        try? lockFileStore.delete(folderURL: session.folderURL)
        await releaseSpeechEngineLease()
        cleanupState()
        try? fileManager.removeItem(at: session.folderURL)
        logger.info("Meeting recording cancelled: \(session.id.uuidString, privacy: .public)")
        AudioCaptureDiagnostics.append(
            "meeting_recording_cancelled session=\(session.id.uuidString)"
        )
    }

    private func releaseSpeechEngineLease() async {
        guard let lease = currentSpeechEngineLease else { return }
        currentSpeechEngineLease = nil
        await speechEngineSessionManager?.endSpeechEngineSession(lease)
    }

    private func retainSpeechEngineLeaseForTranscription(sessionID: UUID) {
        guard let lease = currentSpeechEngineLease else { return }
        currentSpeechEngineLease = nil
        stoppedSpeechEngineLeases[sessionID] = lease
    }

    private func releaseStoppedSpeechEngineLease(sessionID: UUID) async {
        guard let lease = stoppedSpeechEngineLeases.removeValue(forKey: sessionID) else { return }
        await speechEngineSessionManager?.endSpeechEngineSession(lease)
    }

    private func finalizeWriter(_ writer: MeetingAudioStorageWriter?) async {
        guard let writer else { return }
        await withCheckedContinuation { continuation in
            writer.finalize {
                continuation.resume()
            }
        }
    }

    private func drainProcessingTaskAfterCaptureStop(timeout: Duration = .seconds(2)) async {
        guard let task = processingTask else { return }
        let drainFlag = ProcessingDrainFlag()
        let waiter = Task {
            await task.value
            drainFlag.markDrained()
        }

        let startedAt = clock.now
        while !drainFlag.drained && startedAt.duration(to: clock.now) < timeout {
            try? await Task.sleep(for: .milliseconds(10))
        }

        if !drainFlag.drained {
            logger.error("meeting_capture_processing_drain_timed_out")
            task.cancel()
            await task.value
        }
        await waiter.value
        processingTask = nil
    }

    private func handleCaptureEvent(_ event: MeetingAudioCaptureEvent) async {
        switch event {
        case .microphoneBuffer(let buffer, let time):
            guard !captureFailed else { return }
            let handling = captureBufferHandling(time: time)
            guard handling != .drop else { return }
            do {
                let muted = isMicrophoneMuted(at: time)
                let recordingBuffer: AVAudioPCMBuffer
                if muted {
                    guard let silentBuffer = silentMicrophoneBufferLike(buffer) else {
                        await failCapture(MeetingAudioError.captureRuntimeFailure("Failed to create muted microphone buffer"))
                        return
                    }
                    recordingBuffer = silentBuffer
                } else {
                    recordingBuffer = buffer
                }
                recordCaptureMetrics(for: .microphone, time: time)
                try writer?.write(recordingBuffer, source: .microphone)
                if handling == .recordAndProcess {
                    latestLevels.microphone = muted ? 0 : recordingBuffer.rmsLevel
                    if let samples = AudioChunker.extractAndResample(from: recordingBuffer) {
                        await ingestResampledSamples(
                            samples,
                            source: .microphone,
                            hostTime: time.isHostTimeValid ? time.hostTime : nil
                        )
                    }
                }
            } catch {
                await failCapture(error)
            }
        case .systemBuffer(let buffer, let time):
            guard !captureFailed, !interruptedSources.contains(.system) else { return }
            let handling = captureBufferHandling(time: time)
            guard handling != .drop else { return }
            do {
                recordCaptureMetrics(for: .system, time: time)
                try writer?.write(buffer, source: .system)
                if handling == .recordAndProcess {
                    latestLevels.system = buffer.rmsLevel
                    updateSystemRms(with: latestLevels.system)
                    if let samples = AudioChunker.extractAndResample(from: buffer) {
                        await ingestResampledSamples(
                            samples,
                            source: .system,
                            hostTime: time.isHostTimeValid ? time.hostTime : nil
                        )
                    }
                }
            } catch {
                await failCapture(error)
            }
        case .sourceInterrupted(let source, let error):
            guard !captureFailed else { return }
            await handleSourceInterruption(source: source, error: error)
        case .error(let error):
            guard !captureFailed else { return }
            await failCapture(error)
        }
    }

    private func handleSourceInterruption(source: AudioSource, error: Error) async {
        guard !interruptedSources.contains(source) else { return }
        interruptedSources.insert(source)
        logger.warning("meeting_capture_source_interrupted source=\(source.rawValue, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
        AudioCaptureDiagnostics.append(
            "meeting_capture_source_interrupted source=\(source.rawValue) \(AudioCaptureDiagnostics.errorFields(error))"
        )

        switch source {
        case .microphone:
            await failCapture(error)
        case .system:
            latestLevels.system = 0
            recentSystemRms = 0
            latestSystemSignalAt = nil
        }
    }

    private func failCapture(_ error: Error) async {
        captureFailed = true
        latestLevels = MeetingAudioLevels()
        microphoneMuted = false
        microphoneMutedHostTime = nil
        completedMicrophoneMuteHostTimeRanges = []
        logger.error("meeting_capture_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
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
                    captureHealthMetrics.microphoneLowSignalDrops += 1
                    logger.notice(
                        "mic_chunk_dropped reason=low_signal flushed=\(flushed, privacy: .public) rms=\(micRms, privacy: .public) floor=\(Self.chunkSignalFloor, privacy: .public)"
                    )
                } else if shouldSuppressMicrophoneChunkTranscription() {
                    captureHealthMetrics.microphoneSystemDominantDrops += 1
                    let ratio = recentSystemRms / max(recentProcessedMicRms, Self.rmsEpsilon)
                    logger.notice(
                        "mic_chunk_dropped reason=system_dominant flushed=\(flushed, privacy: .public) sys_rms=\(self.recentSystemRms, privacy: .public) proc_mic_rms=\(self.recentProcessedMicRms, privacy: .public) ratio=\(ratio, privacy: .public) threshold=\(Self.systemDominanceRatio, privacy: .public)"
                    )
                } else {
                    captureHealthMetrics.microphoneChunksEnqueued += 1
                    await liveChunkTranscriber.enqueue(chunk: chunk.chunk, source: .microphone)
                }
            case .system:
                if shouldTranscribeChunk(chunk.chunk) {
                    captureHealthMetrics.systemChunksEnqueued += 1
                    await liveChunkTranscriber.enqueue(chunk: chunk.chunk, source: .system)
                } else {
                    captureHealthMetrics.systemLowSignalDrops += 1
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
            captureHealthMetrics.backpressureDrops += 1
            isTranscriptionLagging = true
            logger.notice("Meeting live chunk dropped by scheduler backpressure")
        case .transcriptionFailed(let message):
            captureHealthMetrics.transcriptionFailures += 1
            logger.error("Meeting chunk transcription failed: \(message, privacy: .public)")
        }
    }

    private func configureMicConditioner(from report: MeetingAudioCaptureStartReport) {
        guard report.microphoneStarted else {
            logger.info(
                "meeting_mic_conditioner_skipped source_mode=\(report.sourceMode.rawValue, privacy: .public)"
            )
            return
        }

        let microphone = report.microphone
        if microphone.fellBackToRaw {
            logger.warning(
                "meeting_mic_vpio_unavailable requested=\(String(describing: microphone.requestedMode), privacy: .public) effective=raw requested_policy=\(String(describing: self.requestedMicProcessingMode), privacy: .public) echo_processor=\(self.micConditioner.diagnostics.processorName, privacy: .public)"
            )
        } else {
            logger.info(
                "meeting_mic_processing requested=\(String(describing: microphone.requestedMode), privacy: .public) effective=\(microphone.effectiveMode.rawValue, privacy: .public) echo_processor=\(self.micConditioner.diagnostics.processorName, privacy: .public)"
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
            switch source {
            case .microphone:
                captureHealthMetrics.microphoneFirstBufferSeen = true
            case .system:
                captureHealthMetrics.systemFirstBufferSeen = true
            }
        }
        metrics.lastHostTime = time.hostTime
        sourceCaptureMetrics[source] = metrics
    }

    private func captureBufferHandling(time: AVAudioTime) -> CaptureBufferHandling {
        guard time.isHostTimeValid else {
            return paused ? .drop : .recordAndProcess
        }

        let hostTime = time.hostTime
        if completedPauseHostTimeRanges.contains(where: { $0.contains(hostTime) }) {
            return .drop
        }

        if let pausedHostTime {
            return hostTime < pausedHostTime ? .preserveAudioOnly : .drop
        }

        return .recordAndProcess
    }

    private func appendCompletedPauseHostTimeRange(start: UInt64, end: UInt64) {
        guard end > start else { return }
        appendBoundedCompletedHostTimeRange(
            start: start,
            end: end,
            to: &completedPauseHostTimeRanges
        )
    }

    private func appendCompletedMicrophoneMuteHostTimeRange(start: UInt64, end: UInt64) {
        guard end > start else { return }
        appendBoundedCompletedHostTimeRange(
            start: start,
            end: end,
            to: &completedMicrophoneMuteHostTimeRanges
        )
    }

    private func appendBoundedCompletedHostTimeRange(
        start: UInt64,
        end: UInt64,
        to ranges: inout [HostTimeRange]
    ) {
        ranges.append(HostTimeRange(start: start, end: end))
        let overflowCount = ranges.count - Self.completedHostTimeRangeLimit
        if overflowCount > 0 {
            ranges.removeFirst(overflowCount)
        }
    }

    private func isMicrophoneMuted(at time: AVAudioTime) -> Bool {
        guard time.isHostTimeValid else { return microphoneMuted }

        let hostTime = time.hostTime
        if completedMicrophoneMuteHostTimeRanges.contains(where: { $0.contains(hostTime) }) {
            return true
        }

        if let microphoneMutedHostTime {
            return hostTime >= microphoneMutedHostTime
        }

        return false
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
            logger.error("meeting_recorded_source_audio_inspect_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func preservePlayableMeetingAudioFallback(inputURLs: [URL], outputURL: URL) {
        guard !fileManager.fileExists(atPath: outputURL.path), let fallbackURL = inputURLs.first else {
            return
        }

        do {
            try fileManager.copyItem(at: fallbackURL, to: outputURL)
            logger.info("meeting_mix_fallback_copied source=\(fallbackURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.error(
                "meeting_mix_fallback_copy_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
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

    private func captureHealthSummaryLine(
        session: Session,
        durationSeconds: TimeInterval,
        writerMetrics: [AudioSource: MeetingAudioStorageWriter.SourceWriteMetrics?],
        captureFailed: Bool
    ) -> String {
        let interruptedSourceLabel = interruptedSources
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let microphoneMetrics = writerMetrics[.microphone] ?? nil
        let systemMetrics = writerMetrics[.system] ?? nil
        return [
            "meeting_recording_health",
            "session=\(session.id.uuidString)",
            "duration_s=\(String(format: "%.3f", durationSeconds))",
            "source_mode=\(captureHealthMetrics.sourceMode?.rawValue ?? "unknown")",
            "mic_started=\(captureHealthMetrics.microphoneStarted)",
            "requested_mic_mode=\(micModeLabel(captureHealthMetrics.requestedMicMode))",
            "effective_mic_mode=\(captureHealthMetrics.effectiveMicMode?.rawValue ?? "unknown")",
            "mic_first_buffer=\(captureHealthMetrics.microphoneFirstBufferSeen)",
            "system_first_buffer=\(captureHealthMetrics.systemFirstBufferSeen)",
            "mic_bytes=\(fileSize(at: session.microphoneAudioURL))",
            "system_bytes=\(fileSize(at: session.systemAudioURL))",
            "mixed_bytes=\(fileSize(at: session.mixedAudioURL))",
            "mic_frames=\(microphoneMetrics?.writtenFrameCount ?? 0)",
            "system_frames=\(systemMetrics?.writtenFrameCount ?? 0)",
            "mic_chunks_enqueued=\(captureHealthMetrics.microphoneChunksEnqueued)",
            "system_chunks_enqueued=\(captureHealthMetrics.systemChunksEnqueued)",
            "mic_chunks_low_signal_dropped=\(captureHealthMetrics.microphoneLowSignalDrops)",
            "system_chunks_low_signal_dropped=\(captureHealthMetrics.systemLowSignalDrops)",
            "mic_chunks_system_dominant_dropped=\(captureHealthMetrics.microphoneSystemDominantDrops)",
            "backpressure_drops=\(captureHealthMetrics.backpressureDrops)",
            "transcription_failures=\(captureHealthMetrics.transcriptionFailures)",
            "interrupted_sources=\(interruptedSourceLabel.isEmpty ? "none" : interruptedSourceLabel)",
            "capture_failed=\(captureFailed)",
        ].joined(separator: " ")
    }

    private func echoSuppressionSummaryLine(session: Session) -> String {
        let diagnostics = micConditioner.diagnostics
        return [
            "meeting_echo_suppression_summary",
            "session=\(session.id.uuidString)",
            "processor=\(diagnostics.processorName)",
            "loaded=\(diagnostics.loaded)",
            "mic_frames=\(diagnostics.micFrames)",
            "processed_frames=\(diagnostics.processedFrames)",
            "raw_fallback_frames=\(diagnostics.rawFallbackFrames)",
            "full_reference_frames=\(diagnostics.fullReferenceFrames)",
            "partial_reference_frames=\(diagnostics.partialReferenceFrames)",
            "missing_reference_frames=\(diagnostics.missingReferenceFrames)",
            "processing_failures=\(diagnostics.processingFailures)",
        ].joined(separator: " ")
    }

    private func micModeLabel(_ mode: MeetingMicProcessingMode?) -> String {
        switch mode {
        case .vpioPreferred:
            return "vpio_preferred"
        case .vpioRequired:
            return "vpio_required"
        case .raw:
            return "raw"
        case nil:
            return "unknown"
        }
    }

    private func fileSize(at url: URL) -> UInt64 {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
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
        currentNotes = nil
        currentLockFile = nil
        paused = false
        pausedAt = nil
        pausedHostTime = nil
        completedPauseHostTimeRanges = []
        accumulatedPausedDuration = 0
        microphoneMuted = false
        microphoneMutedHostTime = nil
        completedMicrophoneMuteHostTimeRanges = []
        reusableMicrophoneSilentBuffer = nil
        micConditioner = PassthroughMicConditioner()
        latestLevels = MeetingAudioLevels()
        sourceCaptureMetrics = [:]
        captureHealthMetrics = CaptureHealthMetrics()
        interruptedSources = []
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

    private func silentMicrophoneBufferLike(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if let cached = reusableMicrophoneSilentBuffer,
           cached.format.isEqual(buffer.format),
           cached.frameCapacity >= buffer.frameLength {
            cached.frameLength = buffer.frameLength
            Self.zeroPCMBuffer(cached)
            return cached
        }

        guard let silent = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return nil
        }
        silent.frameLength = buffer.frameLength
        Self.zeroPCMBuffer(silent)
        reusableMicrophoneSilentBuffer = silent
        return silent
    }

    private static func zeroPCMBuffer(_ buffer: AVAudioPCMBuffer) {
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
    }
}
