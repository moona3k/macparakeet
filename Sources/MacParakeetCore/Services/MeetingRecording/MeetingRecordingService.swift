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

public struct MeetingCaptureFailureSignal: Sendable, Equatable {
    public let sessionID: UUID

    public init(sessionID: UUID) {
        self.sessionID = sessionID
    }
}

public protocol MeetingRecordingServiceProtocol: Sendable {
    /// `title` lets callers (e.g., the calendar auto-start path) pre-name
    /// the recording. `nil` or whitespace-only falls back to the default
    /// "Meeting <date>" label.
    func startRecording(
        title: String?,
        sourceMode: MeetingAudioSourceMode?,
        startContext: MeetingStartContext?,
        calendarEventSnapshot: MeetingCalendarSnapshot?
    ) async throws
    func stopRecording() async throws -> MeetingRecordingOutput
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
    /// serialized through this actor — no other component writes the file
    /// (completion-path deletion is owned by `MeetingRecordingSettlement`) —
    /// so notes-saves cannot race with state-transition writes.
    func updateNotes(_ notes: String) async
    var isRecording: Bool { get async }
    var activeSessionID: UUID? { get async }
    /// Speech engine pinned to the active recording session. Consumers should
    /// use this instead of re-reading a mutable preference after recording
    /// starts. This is the live-speech lease selection, not necessarily the
    /// engine captured for final transcription.
    var activeSpeechEngineSelection: SpeechEngineSelection? { get async }
    /// Immutable preview/final routing captured when the meeting starts.
    var activeMeetingSpeechPlan: MeetingSpeechPlan? { get async }
    var isPaused: Bool { get async }
    var micLevel: Float { get async }
    var systemLevel: Float { get async }
    var elapsedSeconds: Int { get async }
    var captureMode: CaptureMode { get async }
    var isMicrophoneMuted: Bool { get async }
    var canMuteMicrophone: Bool { get async }
    var microphoneMuteState: MeetingMicrophoneMuteState { get async }
    var captureHealth: MeetingCaptureHealthSummary { get async }
    var transcriptUpdates: AsyncStream<MeetingTranscriptUpdate> { get async }
    /// One terminal capture-failure signal for the currently active session.
    /// If that session has already failed, the returned stream yields once and
    /// finishes; if no session is active, it finishes without yielding.
    func captureFailureSignalForCurrentSession() async -> AsyncStream<MeetingCaptureFailureSignal>
}

public extension MeetingRecordingServiceProtocol {
    /// Existing manual / hotkey callers use the no-arg form — the calendar
    /// path is the only caller that has a meaningful title to pass.
    func startRecording(title: String?) async throws {
        try await startRecording(title: title, sourceMode: nil, startContext: nil, calendarEventSnapshot: nil)
    }

    func startRecording(title: String?, sourceMode: MeetingAudioSourceMode?) async throws {
        try await startRecording(
            title: title,
            sourceMode: sourceMode,
            startContext: nil,
            calendarEventSnapshot: nil
        )
    }

    func startRecording() async throws {
        try await startRecording(title: nil, sourceMode: nil, startContext: nil, calendarEventSnapshot: nil)
    }

    var captureHealth: MeetingCaptureHealthSummary {
        get async { .notRecording }
    }

    var activeSessionID: UUID? {
        get async { nil }
    }

    var activeSpeechEngineSelection: SpeechEngineSelection? {
        get async { nil }
    }

    func captureFailureSignalForCurrentSession() async -> AsyncStream<MeetingCaptureFailureSignal> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

typealias MeetingCleanedMicrophoneReadinessScheduling =
    @Sendable (
        _ outputURL: URL,
        _ microphoneURL: URL?,
        _ systemURL: URL?,
        _ sourceAlignment: MeetingSourceAlignment,
        _ sessionID: UUID,
        _ conditionerFactory: @escaping @Sendable () -> any MicConditioning,
        _ fileManager: FileManager,
        _ eventName: String
    ) -> MeetingCleanedMicrophoneReadiness

public actor MeetingRecordingService: MeetingRecordingServiceProtocol {
    private struct SourceCaptureMetrics: Sendable {
        var firstHostTime: UInt64?
        var lastHostTime: UInt64?
    }

    private struct CaptureHealthMetrics: Sendable {
        var sourceMode: MeetingAudioSourceMode?
        var requestedMicMode: MeetingMicProcessingMode?
        var effectiveMicMode: MeetingMicProcessingEffectiveMode?
        var captureStartedAt: Date?
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
        let liveSpeechEngine: SpeechEngineSelection
        let speechPlan: MeetingSpeechPlan
        let startContext: MeetingStartContext?
        let calendarEventSnapshot: MeetingCalendarSnapshot?

        var supportsLiveChunkTranscription: Bool {
            speechPlan.preview != nil
        }
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
    private let wallClockNow: @Sendable () -> Date
    private let audioHostTimeNow: @Sendable () -> UInt64
    private let audioCaptureService: any MeetingAudioCapturing
    private let audioConverter: any AudioFileConverting
    private let fileManager: FileManager
    /// Whether VAD-guided live chunking is enabled, injected (rather than read
    /// from `AppFeatures` directly) so the decision is testable and overridable
    /// per-construction. Production (`AppEnvironment`) wires the real
    /// `AppFeatures.meetingVadLiveChunkingEnabled`; the conservative `{ false }`
    /// default gives tests deterministic fixed chunking. See
    /// `plans/completed/2026-05-meeting-vad-guided-live-chunking.md`.
    private let isVadLiveChunkingEnabled: @Sendable () -> Bool
    private let requestedMicProcessingMode: MeetingMicProcessingMode
    private let liveChunkTranscriber: LiveChunkTranscriber
    private let lockFileStore: MeetingRecordingLockFileStoring
    private let speechEngineSessionManager: (any SpeechEngineSessionManaging)?
    private let finalSpeechEngineSelection: @Sendable () -> SpeechEngineSelection?
    private let micConditionerFactory: @Sendable () -> any MicConditioning
    private let cleanedMicConditionerFactory: @Sendable () -> any MicConditioning
    private let cleanedMicrophoneReadinessScheduler: MeetingCleanedMicrophoneReadinessScheduling
    /// Internal fault-injection seam for exercising the durable settlement
    /// boundary without relying on nondeterministic disk or encoder failures.
    private let writerFinalizationReportTransform:
        @Sendable (MeetingAudioStorageWriter.FinalizationReport) -> MeetingAudioStorageWriter.FinalizationReport

    private var currentSession: Session?
    /// Buffer-discard flag for pause/resume. Reset in `cleanupState`.
    private var paused = false
    private var pausedAt: Date?
    private var pausedHostTime: UInt64?
    private var completedPauseHostTimeRanges: [HostTimeRange] = []
    /// Total duration of completed pauses evicted from the bounded range list.
    /// The retained ranges classify late buffers; this cumulative value keeps
    /// the active host timeline correct for current buffers after long-running
    /// sessions exceed that history bound.
    private var evictedPauseHostTimeDuration: TimeInterval = 0
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
    /// Keeps replacement starts out while `audioCaptureService.start()` is still
    /// unwinding after cancellation. `currentSession` may already be nil then.
    private var startingSessionID: UUID?
    /// Once set, the durable Stop path owns this session's settlement. A stale
    /// start task may still resume from `audioCaptureService.start()`, but its
    /// catch must not run failed-start deletion over finalized/recoverable data.
    private var durableStopSessionID: UUID?
    private var writer: MeetingAudioStorageWriter?
    private var processingTask: Task<Void, Never>?
    private var captureOrchestrator = CaptureOrchestrator()
    private var micConditioner: any MicConditioning = PassthroughMicConditioner()
    /// Reused across meetings so the Silero VAD model (CoreML) is loaded at most
    /// once per app session instead of at every meeting start. Only set when the
    /// model is cached; stays nil (and is re-checked cheaply each meeting) until
    /// then. See `configureLiveChunkers`.
    private var sharedVADService: MeetingVADService?
    private var transcriptAssembler = MeetingTranscriptAssembler()
    private var isTranscriptionLagging = false
    private var captureFailed = false
    private var interruptedSources: Set<AudioSource> = []
    private var recoveringSources: Set<AudioSource> = []
    private var sourceCaptureMetrics: [AudioSource: SourceCaptureMetrics] = [:]
    private var captureHealthMetrics = CaptureHealthMetrics()
    private var latestLevels = MeetingAudioLevels()
    private var sourceHealthLastBufferAt: [AudioSource: Date] = [:]
    private var sourceHealthLastBufferActiveSeconds: [AudioSource: TimeInterval] = [:]
    private var activeMicrophoneStall: MeetingMicHealthMonitor.StallSignature?
    private var recentMicrophoneRms: Float = 0
    private var recentSystemRms: Float = 0
    private var recentProcessedMicRms: Float = 0
    private var latestSystemSignalAt: ContinuousClock.Instant?
    private var syncLagEmaMs: Double?
    private var syncLagWarningActive = false
    private var lastLoggedSyncLagBucketMs: Int?

    private var transcriptContinuation: AsyncStream<MeetingTranscriptUpdate>.Continuation?
    private var cachedTranscriptUpdates: AsyncStream<MeetingTranscriptUpdate>?
    private var captureFailureObserverContinuations:
        [UUID: [UUID: AsyncStream<MeetingCaptureFailureSignal>.Continuation]] = [:]
    private var captureFailureSignaledSessionIDs: Set<UUID> = []

    private static let rmsEmaAlpha: Float = 0.3
    private static let processedRmsHealthLevelScale: Float = 10
    private static let systemDominanceRatio: Float = 10.0
    private static let systemActiveFloor: Float = 0.02
    private static let systemSignalFreshnessWindow: Duration = .milliseconds(750)
    private static let sourceFirstBufferStallGraceSeconds: TimeInterval = 12
    private static let sourceBufferGapStallSeconds: TimeInterval = 5
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
        finalSpeechEngineSelection: @escaping @Sendable () -> SpeechEngineSelection? = { nil },
        isVadLiveChunkingEnabled: @escaping @Sendable () -> Bool = { false },
        echoSuppressionConfiguration: MeetingEchoSuppressionConfiguration = .fromEnvironment()
    ) {
        self.init(
            micProcessingMode: micProcessingMode,
            audioCaptureService: audioCaptureService,
            audioConverter: audioConverter,
            sttTranscriber: sttTranscriber,
            lockFileStore: lockFileStore,
            fileManager: fileManager,
            finalSpeechEngineSelection: finalSpeechEngineSelection,
            isVadLiveChunkingEnabled: isVadLiveChunkingEnabled,
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
        finalSpeechEngineSelection: @escaping @Sendable () -> SpeechEngineSelection? = { nil },
        isVadLiveChunkingEnabled: @escaping @Sendable () -> Bool = { false },
        micConditionerFactory: @escaping @Sendable () -> any MicConditioning,
        cleanedMicConditionerFactory: (@Sendable () -> any MicConditioning)? = nil,
        wallClockNow: @escaping @Sendable () -> Date = { Date() },
        audioHostTimeNow: @escaping @Sendable () -> UInt64 = {
            MeetingRecordingService.currentAudioHostTime()
        },
        cleanedMicrophoneReadinessScheduler: @escaping MeetingCleanedMicrophoneReadinessScheduling = {
            outputURL, microphoneURL, systemURL, sourceAlignment, sessionID, conditionerFactory, fileManager, eventName
            in
            MeetingCleanedMicrophoneRenderScheduler.schedule(
                outputURL: outputURL,
                microphoneURL: microphoneURL,
                systemURL: systemURL,
                sourceAlignment: sourceAlignment,
                sessionID: sessionID,
                conditionerFactory: conditionerFactory,
                fileManager: fileManager,
                eventName: eventName
            )
        },
        writerFinalizationReportTransform: @escaping @Sendable (
            MeetingAudioStorageWriter.FinalizationReport
        ) -> MeetingAudioStorageWriter.FinalizationReport = { $0 }
    ) {
        self.requestedMicProcessingMode = micProcessingMode
        self.audioCaptureService = audioCaptureService
        self.audioConverter = audioConverter
        self.lockFileStore = lockFileStore
        self.fileManager = fileManager
        self.finalSpeechEngineSelection = finalSpeechEngineSelection
        self.isVadLiveChunkingEnabled = isVadLiveChunkingEnabled
        self.micConditionerFactory = micConditionerFactory
        self.cleanedMicConditionerFactory = cleanedMicConditionerFactory ?? micConditionerFactory
        self.wallClockNow = wallClockNow
        self.audioHostTimeNow = audioHostTimeNow
        self.cleanedMicrophoneReadinessScheduler = cleanedMicrophoneReadinessScheduler
        self.writerFinalizationReportTransform = writerFinalizationReportTransform
        self.liveChunkTranscriber = LiveChunkTranscriber(sttTranscriber: sttTranscriber)
        self.speechEngineSessionManager = sttTranscriber as? any SpeechEngineSessionManaging
    }

    public var isRecording: Bool {
        currentSession != nil
    }

    public var activeSessionID: UUID? {
        currentSession?.id
    }

    public var activeSpeechEngineSelection: SpeechEngineSelection? {
        currentSession?.liveSpeechEngine
    }

    public var activeMeetingSpeechPlan: MeetingSpeechPlan? {
        currentSession?.speechPlan
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
        return max(0, Int(activeRecordingSeconds(startedAt: startedAt, asOf: wallClockNow())))
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
            && !interruptedSources.contains(.microphone)
            && captureHealthMetrics.sourceMode?.capturesMicrophone == true
    }

    public var microphoneMuteState: MeetingMicrophoneMuteState {
        let canMute = canMuteMicrophone
        return MeetingMicrophoneMuteState(isMuted: canMute && microphoneMuted, canMute: canMute)
    }

    public var captureHealth: MeetingCaptureHealthSummary {
        guard currentSession != nil else {
            return .notRecording
        }
        guard let sourceMode = captureHealthMetrics.sourceMode else {
            return .starting(sourceMode: .microphoneAndSystem)
        }
        return MeetingCaptureHealthSummary.reduce(
            sourceMode: sourceMode,
            microphoneLevel: microphoneCaptureHealthLevel,
            systemLevel: systemCaptureHealthLevel,
            lastBufferAt: sourceHealthLastBufferAt,
            isMicrophoneMuted: microphoneMuteState.isMuted,
            microphoneStarted: captureHealthMetrics.microphoneStarted,
            interruptedSources: interruptedSources,
            recoveringSources: recoveringSources,
            activeMicrophoneStall: activeMicrophoneStall,
            microphoneBufferDeliveryTimedOut: microphoneBufferDeliveryTimedOut,
            systemBufferDeliveryTimedOut: systemBufferDeliveryTimedOut,
            captureFailed: captureFailed
        )
    }

    private var microphoneBufferDeliveryTimedOut: Bool {
        guard captureHealthMetrics.microphoneStarted else {
            return false
        }
        return sourceBufferDeliveryTimedOut(.microphone)
    }

    private var systemBufferDeliveryTimedOut: Bool {
        sourceBufferDeliveryTimedOut(.system)
    }

    private func sourceBufferDeliveryTimedOut(_ source: AudioSource) -> Bool {
        let sourceSelected: Bool
        switch source {
        case .microphone:
            sourceSelected = captureHealthMetrics.sourceMode?.capturesMicrophone == true
        case .system:
            sourceSelected = captureHealthMetrics.sourceMode?.capturesSystemAudio == true
        }

        guard !paused,
            !captureFailed,
            sourceSelected,
            !interruptedSources.contains(source),
            !recoveringSources.contains(source),
            let captureStartedAt = captureHealthMetrics.captureStartedAt
        else {
            return false
        }

        let currentActiveSeconds = activeRecordingSeconds(
            startedAt: captureStartedAt,
            asOf: wallClockNow()
        )
        guard let lastBufferActiveSeconds = sourceHealthLastBufferActiveSeconds[source] else {
            return currentActiveSeconds >= Self.sourceFirstBufferStallGraceSeconds
        }
        return currentActiveSeconds - lastBufferActiveSeconds >= Self.sourceBufferGapStallSeconds
    }

    /// Wallclock-since-start minus all pause time (completed + ongoing).
    /// Used for the live elapsed timer, source-health timing, and finalized
    /// elapsed capture report. Persisted playback duration is media-probed.
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

    public func captureFailureSignalForCurrentSession() async -> AsyncStream<MeetingCaptureFailureSignal> {
        guard let sessionID = currentSession?.id else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        var continuation: AsyncStream<MeetingCaptureFailureSignal>.Continuation?
        let stream = AsyncStream<MeetingCaptureFailureSignal>(bufferingPolicy: .bufferingOldest(1)) {
            continuation = $0
        }
        guard let continuation else { return stream }

        if captureFailureSignaledSessionIDs.contains(sessionID) || captureFailed {
            continuation.yield(MeetingCaptureFailureSignal(sessionID: sessionID))
            continuation.finish()
            return stream
        }

        let observerID = UUID()
        captureFailureObserverContinuations[sessionID, default: [:]][observerID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeCaptureFailureObserver(sessionID: sessionID, observerID: observerID)
            }
        }
        return stream
    }

    public func startRecording(
        title: String? = nil,
        sourceMode: MeetingAudioSourceMode? = nil,
        startContext: MeetingStartContext? = nil,
        calendarEventSnapshot: MeetingCalendarSnapshot? = nil
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
        // startedAt — back-to-back wall clock reads would only diverge if
        // the clock ticked over a minute boundary between them, which is
        // vanishingly rare but trivially avoidable.
        let now = wallClockNow()
        // Reserve the live engine before reading the final preference. The
        // scheduler lease closes the switch/variant TOCTOU window and remains
        // held even when the live engine cannot render meeting preview.
        let speechEngineLease = await speechEngineSessionManager?.beginSpeechEngineSession()
        currentSpeechEngineLease = speechEngineLease
        let liveSpeechEngine: SpeechEngineSelection
        let liveSpeechEngineCapabilities: SpeechEngineCapabilities?
        if let speechEngineLease {
            liveSpeechEngine = speechEngineLease.selection
            liveSpeechEngineCapabilities = speechEngineLease.capabilities
        } else {
            liveSpeechEngine = SpeechEngineSelection.liveSpeech()
            liveSpeechEngineCapabilities = SpeechEngineCapabilityRegistry.capabilities(
                for: liveSpeechEngine.engine
            )
        }
        let finalSpeechEngine = finalSpeechEngineSelection() ?? liveSpeechEngine
        let speechPlan = MeetingSpeechPlan.resolve(
            live: liveSpeechEngine,
            final: finalSpeechEngine,
            liveCapabilities: liveSpeechEngineCapabilities
        )
        let session = Session(
            id: sessionID,
            displayName: Self.resolveDisplayName(title: title, fallbackDate: now),
            startedAt: now,
            folderURL: folderURL,
            chunkFolderURL: chunkFolderURL,
            microphoneAudioURL: writer.microphoneAudioURL,
            systemAudioURL: writer.systemAudioURL,
            mixedAudioURL: writer.mixedAudioURL,
            liveSpeechEngine: liveSpeechEngine,
            speechPlan: speechPlan,
            startContext: startContext,
            calendarEventSnapshot: calendarEventSnapshot
        )
        self.writer = writer
        self.currentSession = session

        do {
            let initialLock = MeetingRecordingLockFile(
                sessionId: session.id,
                startedAt: session.startedAt,
                pid: ProcessInfo.processInfo.processIdentifier,
                displayName: session.displayName,
                speechEngine: session.speechPlan.final,
                startContext: session.startContext,
                calendarEventSnapshot: session.calendarEventSnapshot,
                folderURL: session.folderURL
            )
            try lockFileStore.write(initialLock, folderURL: session.folderURL)
            currentLockFile = initialLock

            let events = await audioCaptureService.events
            try await validateStartStillCurrent(session)
            self.latestLevels = MeetingAudioLevels()
            await configureLiveChunkers(for: session)
            await captureOrchestrator.reset()
            try await validateStartStillCurrent(session)
            micConditioner = micConditionerFactory()
            micConditioner.reset()
            transcriptAssembler.reset()
            isTranscriptionLagging = false
            captureFailed = false
            captureFailureSignaledSessionIDs.remove(session.id)
            interruptedSources = []
            recoveringSources = []
            sourceCaptureMetrics = [:]
            captureHealthMetrics = CaptureHealthMetrics()
            sourceHealthLastBufferAt = [:]
            sourceHealthLastBufferActiveSeconds = [:]
            activeMicrophoneStall = nil
            recentMicrophoneRms = 0
            recentSystemRms = 0
            recentProcessedMicRms = 0
            latestSystemSignalAt = nil
            syncLagEmaMs = nil
            syncLagWarningActive = false
            lastLoggedSyncLagBucketMs = nil

            if let previewSpeechEngine = session.speechPlan.preview {
                await liveChunkTranscriber.startSession(
                    .init(
                        id: session.id,
                        chunkFolderURL: session.chunkFolderURL,
                        speechEngine: previewSpeechEngine
                    ),
                    onEvent: { [weak self] event in
                        await self?.handleLiveChunkTranscriberEvent(event, sessionID: session.id)
                    }
                )
            }
            try await validateStartStillCurrent(session)

            let captureStartReport = try await audioCaptureService.start(sourceMode: sourceMode)
            try await validateStartStillCurrent(session)
            captureHealthMetrics.sourceMode = captureStartReport.sourceMode
            captureHealthMetrics.requestedMicMode = captureStartReport.microphone.requestedMode
            captureHealthMetrics.effectiveMicMode = captureStartReport.microphone.effectiveMode
            captureHealthMetrics.captureStartedAt = wallClockNow()
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
            if durableStopSessionID == sessionID || currentSession?.id != sessionID {
                AudioCaptureDiagnostics.append(
                    "meeting_recording_start_cleanup_skipped session=\(sessionID.uuidString) reason=settlement_owned"
                )
            } else {
                await cleanupFailedStart(folderURL: folderURL)
            }
            throw error
        }
    }

    private func cleanupFailedStart(folderURL: URL) async {
        processingTask?.cancel()
        processingTask = nil
        await liveChunkTranscriber.finishSession()
        let writer = self.writer
        self.writer = nil
        _ = await finalizeWriter(writer)
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
        durableStopSessionID = session.id

        // Freeze the user-visible capture interval before any asynchronous
        // shutdown, writer finalization, mixing, or artifact I/O. Those stages
        // must not inflate the meeting's elapsed duration.
        let captureEndedAt = wallClockNow()
        let captureStartedAt = captureHealthMetrics.captureStartedAt ?? session.startedAt
        let captureElapsedDurationSeconds = activeRecordingSeconds(
            startedAt: captureStartedAt,
            asOf: captureEndedAt
        )
        if let pausedAtSnapshot = pausedAt {
            accumulatedPausedDuration += captureEndedAt.timeIntervalSince(pausedAtSnapshot)
            pausedAt = nil
        }
        paused = false

        let serviceStopStartedAt = Date()
        var serviceStopOutcome = "success"
        func elapsedMilliseconds(since startedAt: Date) -> Int {
            max(0, Int((Date().timeIntervalSince(startedAt) * 1_000).rounded()))
        }
        func appendStopStage(
            _ stage: String,
            startedAt: Date,
            outcome: String = "success",
            detail: String? = nil
        ) {
            let suffix = detail.map { " \($0)" } ?? ""
            let fields = [
                "meeting_stop_stage",
                "session=\(session.id.uuidString)",
                "stage=\(stage)",
                "duration_ms=\(elapsedMilliseconds(since: startedAt))",
                "outcome=\(outcome)",
            ].joined(separator: " ")
            AudioCaptureDiagnostics.append(
                "\(fields)\(suffix)"
            )
        }
        defer {
            appendStopStage("service_total", startedAt: serviceStopStartedAt, outcome: serviceStopOutcome)
        }

        AudioCaptureDiagnostics.append(
            "meeting_recording_stopping session=\(session.id.uuidString)"
        )
        let captureStopStartedAt = Date()
        await audioCaptureService.stop()
        appendStopStage("capture_stop", startedAt: captureStopStartedAt)
        let drainStartedAt = Date()
        await drainProcessingTaskAfterCaptureStop()
        appendStopStage("processing_drain", startedAt: drainStartedAt)
        let writerFinalizeStartedAt = Date()
        let finalizedWriter = writer
        writer = nil
        let writerFinalization = writerFinalizationReportTransform(
            await finalizeWriter(finalizedWriter)
        )
        let writerMetrics = [
            AudioSource.microphone: finalizedWriter?.metrics(for: .microphone),
            AudioSource.system: finalizedWriter?.metrics(for: .system),
        ]
        await liveChunkTranscriber.cancelPendingTasks(waitForCancellation: false)
        do {
            try Self.requireSuccessfulWriterFinalization(writerFinalization)
        } catch {
            let failedSources = [AudioSource.microphone, .system]
                .filter(writerFinalization.failedSources.contains)
                .map(\.rawValue)
                .joined(separator: ",")
            serviceStopOutcome = "failure_writer_finalize"
            appendStopStage(
                "writer_finalize",
                startedAt: writerFinalizeStartedAt,
                outcome: "failure",
                detail: "sources=\(failedSources)"
            )
            AudioCaptureDiagnostics.append(
                captureHealthSummaryLine(
                    session: session,
                    durationSeconds: captureElapsedDurationSeconds,
                    writerMetrics: writerMetrics,
                    captureFailed: true,
                    captureReport: nil
                )
            )
            await liveChunkTranscriber.finishSession()
            await releaseSpeechEngineLease()
            cleanupState()
            throw error
        }
        appendStopStage("writer_finalize", startedAt: writerFinalizeStartedAt)

        let sourceURLsStartedAt = Date()
        let inputURLs: [URL]
        do {
            inputURLs = try existingSourceURLs(for: session)
            appendStopStage("source_urls", startedAt: sourceURLsStartedAt)
        } catch {
            serviceStopOutcome = "failure_source_urls"
            appendStopStage(
                "source_urls",
                startedAt: sourceURLsStartedAt,
                outcome: "failure",
                detail: "error_type=\(AudioCaptureDiagnostics.errorType(error))"
            )
            throw error
        }
        guard !inputURLs.isEmpty else {
            AudioCaptureDiagnostics.append(
                captureHealthSummaryLine(
                    session: session,
                    durationSeconds: captureElapsedDurationSeconds,
                    writerMetrics: writerMetrics,
                    captureFailed: captureFailed,
                    captureReport: nil
                )
            )
            await liveChunkTranscriber.finishSession()
            try? lockFileStore.delete(folderURL: session.folderURL)
            await releaseSpeechEngineLease()
            cleanupState()
            try? fileManager.removeItem(at: session.folderURL)
            serviceStopOutcome = "failure_no_audio"
            throw MeetingAudioError.noAudioCaptured
        }

        let availableSources = Set(inputURLs.map(source(for:)))
        let sourceAlignment = buildSourceAlignment(
            availableSources: availableSources,
            writerMetrics: writerMetrics
        )
        let captureSourceMode = captureHealthMetrics.sourceMode ?? .microphoneAndSystem
        let preliminaryCaptureReport = MeetingCaptureReport(
            sourceMode: captureSourceMode,
            sourceAlignment: sourceAlignment,
            elapsedDurationMs: Int((captureElapsedDurationSeconds * 1_000).rounded()),
            interruptedSources: interruptedSources,
            captureFailed: captureFailed
        )
        var recordingMetadata = MeetingRecordingMetadata(
            sourceAlignment: sourceAlignment,
            captureReport: preliminaryCaptureReport,
            speechEngine: session.speechPlan.final,
            previewSpeechEngine: session.speechPlan.preview,
            startContext: session.startContext,
            calendarEventSnapshot: session.calendarEventSnapshot
        )
        let metadataStartedAt = Date()
        do {
            try MeetingRecordingMetadataStore.save(
                recordingMetadata,
                folderURL: session.folderURL
            )
            appendStopStage("metadata_save", startedAt: metadataStartedAt)
        } catch {
            logger.error(
                "meeting_metadata_save_failed session=\(session.id.uuidString, privacy: .public) phase=preliminary error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
            await liveChunkTranscriber.finishSession()
            await releaseSpeechEngineLease()
            cleanupState()
            serviceStopOutcome = "failure_metadata"
            appendStopStage(
                "metadata_save",
                startedAt: metadataStartedAt,
                outcome: "failure",
                detail: "error_type=\(AudioCaptureDiagnostics.errorType(error))"
            )
            throw MeetingAudioError.storageFailed(error.localizedDescription)
        }

        let playbackCandidates = inputURLs.compactMap { url -> MeetingPlaybackArtifactBuilder.Candidate? in
            let source = source(for: url)
            guard let track = sourceAlignment.track(for: source) else { return nil }
            return MeetingPlaybackArtifactBuilder.Candidate(source: source, url: url, track: track)
        }
        let mixStartedAt = Date()
        let playbackArtifact: MeetingPlaybackArtifactBuilder.Result
        do {
            playbackArtifact = try await MeetingPlaybackArtifactBuilder(
                audioConverter: audioConverter,
                fileManager: fileManager
            ).build(
                candidates: playbackCandidates,
                outputURL: session.mixedAudioURL,
                sourceAlignment: sourceAlignment
            )
            let outcome = playbackArtifact.method == .mixed ? "success" : playbackArtifact.method.rawValue
            appendStopStage("mix", startedAt: mixStartedAt, outcome: outcome)
            if playbackArtifact.method == .bestSourceFallback {
                logger.warning(
                    "meeting_mix_fallback_created session=\(session.id.uuidString, privacy: .public) source=\(String(describing: playbackArtifact.source), privacy: .public)"
                )
            }
        } catch {
            await liveChunkTranscriber.finishSession()
            await releaseSpeechEngineLease()
            cleanupState()
            serviceStopOutcome = "failure_playback"
            appendStopStage(
                "mix",
                startedAt: mixStartedAt,
                outcome: "failure",
                detail: "error_type=\(AudioCaptureDiagnostics.errorType(error))"
            )
            throw MeetingAudioError.mixFailed(error.localizedDescription)
        }

        let captureReport = MeetingCaptureReport(
            sourceMode: captureSourceMode,
            sourceAlignment: sourceAlignment,
            elapsedDurationMs: preliminaryCaptureReport.elapsedDurationMs,
            interruptedSources: interruptedSources,
            captureFailed: captureFailed,
            playbackFallbackSource: playbackArtifact.method == .bestSourceFallback
                ? playbackArtifact.source
                : nil
        )
        if captureReport != preliminaryCaptureReport {
            let finalMetadataStartedAt = Date()
            recordingMetadata = recordingMetadata.withCaptureReport(captureReport)
            do {
                try MeetingRecordingMetadataStore.save(
                    recordingMetadata,
                    folderURL: session.folderURL
                )
                appendStopStage("metadata_finalize", startedAt: finalMetadataStartedAt)
            } catch {
                logger.error(
                    "meeting_metadata_save_failed session=\(session.id.uuidString, privacy: .public) phase=final error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
                )
                await liveChunkTranscriber.finishSession()
                await releaseSpeechEngineLease()
                cleanupState()
                serviceStopOutcome = "failure_metadata_finalize"
                appendStopStage(
                    "metadata_finalize",
                    startedAt: finalMetadataStartedAt,
                    outcome: "failure",
                    detail: "error_type=\(AudioCaptureDiagnostics.errorType(error))"
                )
                throw MeetingAudioError.storageFailed(error.localizedDescription)
            }
        }

        let finalNotes = currentNotes
        let notesFileManager = MeetingNotesFile.SendableFileManager(fileManager)
        let notesStartedAt = Date()
        do {
            try await MeetingNotesFile.write(
                notes: finalNotes,
                displayName: session.displayName,
                to: session.folderURL,
                fileManager: notesFileManager
            )
            appendStopStage("notes_write", startedAt: notesStartedAt)
        } catch {
            logger.warning(
                "meeting_notes_file_write_failed session=\(session.id.uuidString, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
            appendStopStage(
                "notes_write",
                startedAt: notesStartedAt,
                outcome: "failure_nonfatal",
                detail: "error_type=\(AudioCaptureDiagnostics.errorType(error))"
            )
        }

        let awaitingLock =
            (currentLockFile
            ?? MeetingRecordingLockFile(
                sessionId: session.id,
                startedAt: session.startedAt,
                pid: ProcessInfo.processInfo.processIdentifier,
                displayName: session.displayName,
                speechEngine: session.speechPlan.final,
                startContext: session.startContext,
                calendarEventSnapshot: session.calendarEventSnapshot,
                folderURL: session.folderURL
            ))
            .withNotes(finalNotes)
            .withState(.awaitingTranscription)
        let lockStartedAt = Date()
        do {
            try lockFileStore.write(awaitingLock, folderURL: session.folderURL)
            appendStopStage("lock_write", startedAt: lockStartedAt)
        } catch {
            await liveChunkTranscriber.finishSession()
            await releaseSpeechEngineLease()
            cleanupState()
            serviceStopOutcome = "failure_lock"
            appendStopStage(
                "lock_write",
                startedAt: lockStartedAt,
                outcome: "failure",
                detail: "error_type=\(AudioCaptureDiagnostics.errorType(error))"
            )
            throw MeetingAudioError.storageFailed(error.localizedDescription)
        }
        currentLockFile = awaitingLock

        let durationSeconds = playbackArtifact.durationSeconds
        // The render guard models audio work, so use captured media duration
        // rather than user-facing wall-clock meeting duration.
        let renderDurationSeconds = sourceAlignment.cleanedMicrophoneRenderDurationSeconds
        let cleanedMicScheduleStartedAt = Date()
        let cleanedMicrophoneReadiness = scheduleCleanedMicrophoneRender(
            session: session,
            availableSources: availableSources,
            sourceAlignment: sourceAlignment,
            renderDuration: renderDurationSeconds
        )
        appendStopStage("cleaned_mic_schedule", startedAt: cleanedMicScheduleStartedAt)
        let output = MeetingRecordingOutput(
            sessionID: session.id,
            displayName: session.displayName,
            folderURL: session.folderURL,
            mixedAudioURL: session.mixedAudioURL,
            microphoneAudioURL: session.microphoneAudioURL,
            systemAudioURL: session.systemAudioURL,
            cleanedMicrophoneAudioURL: cleanedMicrophoneReadiness.outputURL,
            cleanedMicrophoneReadiness: cleanedMicrophoneReadiness,
            durationSeconds: durationSeconds,
            sourceAlignment: sourceAlignment,
            captureReport: captureReport,
            speechEngine: session.speechPlan.final,
            previewSpeechEngine: session.speechPlan.preview,
            startContext: session.startContext,
            userNotes: finalNotes,
            calendarEventSnapshot: session.calendarEventSnapshot
        )

        let cleanupStartedAt = Date()
        await liveChunkTranscriber.finishSession()
        await releaseSpeechEngineLease()
        appendStopStage("cleanup", startedAt: cleanupStartedAt)
        logger.info("Meeting recording finalized: \(session.id.uuidString, privacy: .public)")
        AudioCaptureDiagnostics.append(
            "meeting_recording_stopped session=\(session.id.uuidString) duration_s=\(String(format: "%.3f", durationSeconds))"
        )
        AudioCaptureDiagnostics.append(
            captureHealthSummaryLine(
                session: session,
                durationSeconds: captureElapsedDurationSeconds,
                writerMetrics: writerMetrics,
                captureFailed: captureFailed,
                captureReport: captureReport
            )
        )
        AudioCaptureDiagnostics.append(
            echoSuppressionSummaryLine(session: session)
        )
        cleanupState()
        return output
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
        let base =
            currentLockFile
            ?? MeetingRecordingLockFile(
                sessionId: session.id,
                startedAt: session.startedAt,
                pid: ProcessInfo.processInfo.processIdentifier,
                displayName: session.displayName,
                speechEngine: session.speechPlan.final,
                startContext: session.startContext,
                calendarEventSnapshot: session.calendarEventSnapshot,
                folderURL: session.folderURL
            )
        let updated = base.withNotes(normalized)
        do {
            try lockFileStore.write(updated, folderURL: session.folderURL)
            currentLockFile = updated
        } catch {
            // Notes persistence is best-effort — losing one debounce write to
            // an I/O error is preferable to surfacing a UI error mid-meeting.
            logger.error(
                "meeting_recording_notes_persist_failed session=\(session.id.uuidString, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    public func pauseRecording() async {
        guard currentSession != nil, !paused, !captureFailed else { return }
        paused = true
        pausedAt = wallClockNow()
        pausedHostTime = audioHostTimeNow()
        // Zero levels so live UI reads "no signal" the moment the user
        // pauses, instead of decaying from the EMA over the next few
        // hundred ms. Same reasoning as the `failCapture` path.
        latestLevels = MeetingAudioLevels()
        recentMicrophoneRms = 0
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
            accumulatedPausedDuration += wallClockNow().timeIntervalSince(pausedAt)
        }
        if let pausedHostTime {
            appendCompletedPauseHostTimeRange(start: pausedHostTime, end: audioHostTimeNow())
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
            recentMicrophoneRms = 0
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
        _ = await finalizeWriter(finalizedWriter)
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

    private func finalizeWriter(
        _ writer: MeetingAudioStorageWriter?
    ) async -> MeetingAudioStorageWriter.FinalizationReport {
        guard let writer else {
            return MeetingAudioStorageWriter.FinalizationReport(failedSources: [])
        }
        return await withCheckedContinuation { continuation in
            writer.finalize { report in
                continuation.resume(returning: report)
            }
        }
    }

    static func requireSuccessfulWriterFinalization(
        _ report: MeetingAudioStorageWriter.FinalizationReport
    ) throws {
        let failedSources = [AudioSource.microphone, .system]
            .filter(report.failedSources.contains)
            .map(\.rawValue)
            .joined(separator: ",")
        guard !failedSources.isEmpty else { return }
        throw MeetingAudioError.storageFailed(
            "Failed to finalize \(failedSources) meeting audio. The source files were preserved for recovery."
        )
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
            guard !captureFailed, !interruptedSources.contains(.microphone) else { return }
            let handling = captureBufferHandling(time: time)
            guard handling != .drop else { return }
            do {
                let muted = isMicrophoneMuted(at: time)
                let recordingBuffer: AVAudioPCMBuffer
                if muted {
                    guard let silentBuffer = silentMicrophoneBufferLike(buffer) else {
                        await failCapture(
                            MeetingAudioError.captureRuntimeFailure("Failed to create muted microphone buffer"))
                        return
                    }
                    recordingBuffer = silentBuffer
                } else {
                    recordingBuffer = buffer
                }
                recordCaptureMetrics(for: .microphone, time: time)
                try writer?.write(
                    recordingBuffer,
                    source: .microphone,
                    timelineTimeSeconds: pauseAdjustedHostTimeSeconds(for: time)
                )
                if handling == .recordAndProcess {
                    latestLevels.microphone = muted ? 0 : recordingBuffer.rmsLevel
                    updateMicrophoneRms(with: latestLevels.microphone)
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
                try writer?.write(
                    buffer,
                    source: .system,
                    timelineTimeSeconds: pauseAdjustedHostTimeSeconds(for: time)
                )
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
        case .sourceRecoveryStarted(let source, let error):
            handleSourceRecoveryStarted(source: source, error: error)
        case .sourceRecovered(let source):
            handleSourceRecovered(source: source)
        case .microphoneHealth(let event):
            handleMicrophoneHealthEvent(event)
        case .error(let error):
            guard !captureFailed else { return }
            await failCapture(error)
        }
    }

    private func handleSourceRecoveryStarted(source: AudioSource, error: MeetingAudioError) {
        guard !captureFailed, !interruptedSources.contains(source) else { return }
        recoveringSources.insert(source)
        if source == .system {
            latestLevels.system = 0
            recentSystemRms = 0
            latestSystemSignalAt = nil
        }
        AudioCaptureDiagnostics.append(
            "meeting_capture_source_recovery_started source=\(source.rawValue) \(AudioCaptureDiagnostics.errorFields(error))"
        )
    }

    private func handleSourceRecovered(source: AudioSource) {
        guard recoveringSources.remove(source) != nil else { return }
        AudioCaptureDiagnostics.append(
            "meeting_capture_source_recovered source=\(source.rawValue)"
        )
    }

    private func handleMicrophoneHealthEvent(_ event: MeetingMicHealthMonitor.HealthEvent) {
        switch event {
        case .stallSuspected(let signature, _):
            activeMicrophoneStall = signature
        case .recovered:
            activeMicrophoneStall = nil
        }
    }

    private func handleSourceInterruption(source: AudioSource, error: Error) async {
        guard !interruptedSources.contains(source) else { return }
        recoveringSources.remove(source)
        interruptedSources.insert(source)
        logger.warning(
            "meeting_capture_source_interrupted source=\(source.rawValue, privacy: .public) error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
        )
        AudioCaptureDiagnostics.append(
            "meeting_capture_source_interrupted source=\(source.rawValue) \(AudioCaptureDiagnostics.errorFields(error))"
        )

        switch source {
        case .microphone:
            latestLevels.microphone = 0
            recentMicrophoneRms = 0
            recentProcessedMicRms = 0
            microphoneMuted = false
            activeMicrophoneStall = nil
        case .system:
            latestLevels.system = 0
            recentSystemRms = 0
            latestSystemSignalAt = nil
        }

        if allSelectedSourcesAreInterrupted {
            await failCapture(error)
        }
    }

    private var allSelectedSourcesAreInterrupted: Bool {
        guard let sourceMode = captureHealthMetrics.sourceMode else { return false }
        let microphoneInterrupted = !sourceMode.capturesMicrophone
            || interruptedSources.contains(.microphone)
        let systemInterrupted = !sourceMode.capturesSystemAudio
            || interruptedSources.contains(.system)
        return microphoneInterrupted && systemInterrupted
    }

    private func failCapture(_ error: Error) async {
        guard let sessionID = currentSession?.id,
            !captureFailureSignaledSessionIDs.contains(sessionID)
        else { return }

        captureFailureSignaledSessionIDs.insert(sessionID)
        captureFailed = true
        recoveringSources = []
        latestLevels = MeetingAudioLevels()
        recentMicrophoneRms = 0
        recentSystemRms = 0
        recentProcessedMicRms = 0
        microphoneMuted = false
        activeMicrophoneStall = nil
        microphoneMutedHostTime = nil
        completedMicrophoneMuteHostTimeRanges = []
        logger.error(
            "meeting_capture_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
        )
        emitCaptureFailureSignal(for: sessionID)
        await audioCaptureService.stop()
    }

    private func emitCaptureFailureSignal(for sessionID: UUID) {
        guard let continuations = captureFailureObserverContinuations.removeValue(forKey: sessionID) else {
            return
        }
        let signal = MeetingCaptureFailureSignal(sessionID: sessionID)
        for continuation in continuations.values {
            continuation.yield(signal)
            continuation.finish()
        }
    }

    private func finishCaptureFailureSignal(for sessionID: UUID) {
        if let continuations = captureFailureObserverContinuations.removeValue(forKey: sessionID) {
            for continuation in continuations.values {
                continuation.finish()
            }
        }
        captureFailureSignaledSessionIDs.remove(sessionID)
    }

    private func removeCaptureFailureObserver(sessionID: UUID, observerID: UUID) {
        captureFailureObserverContinuations[sessionID]?.removeValue(forKey: observerID)
        if captureFailureObserverContinuations[sessionID]?.isEmpty == true {
            captureFailureObserverContinuations.removeValue(forKey: sessionID)
        }
    }

    /// Pick the live-preview chunking strategy for this session and install it
    /// on the orchestrator. When the feature flag is off, the fixed 5s path is
    /// byte-identical to the prior `AudioChunker` behavior. When enabled and
    /// the Silero VAD model is cached, Parakeet sessions cut both sources at
    /// speech boundaries; WhisperKit sessions and uncached VAD stay on fixed.
    /// See `plans/completed/2026-05-meeting-vad-guided-live-chunking.md` §4.
    private func configureLiveChunkers(for session: Session) async {
        func useFixed(reason: String) async {
            await captureOrchestrator.configureChunkers(
                microphone: FixedMeetingLiveAudioChunker(),
                system: FixedMeetingLiveAudioChunker()
            )
            AudioCaptureDiagnostics.append(
                "meeting_live_chunking_mode session=\(session.id.uuidString) mode=fixed reason=\(reason)"
            )
        }

        guard isVadLiveChunkingEnabled() else {
            await useFixed(reason: "feature_disabled")
            return
        }
        guard session.speechPlan.preview?.engine == .parakeet else {
            await useFixed(reason: "non_parakeet_engine")
            return
        }
        guard let vad = await liveVADService() else {
            await useFixed(reason: "vad_unavailable")
            return
        }

        await captureOrchestrator.configureChunkers(
            microphone: SpeechBoundaryMeetingLiveAudioChunker(vad: vad),
            system: SpeechBoundaryMeetingLiveAudioChunker(vad: vad)
        )
        AudioCaptureDiagnostics.append(
            "meeting_live_chunking_mode session=\(session.id.uuidString) mode=vad reason=started")
    }

    /// The shared VAD service, loaded lazily once per app session. Returns nil
    /// when the model is not cached — cheap to re-check (a file-existence test),
    /// so a later session can still pick it up after launch-time prep fetches it.
    private func liveVADService() async -> MeetingVADService? {
        if let sharedVADService { return sharedVADService }
        guard let service = await MeetingVADService.makeIfModelCached() else { return nil }
        sharedVADService = service
        return service
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

        guard let session = currentSession, session.supportsLiveChunkTranscription else { return }

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
        let now = wallClockNow()
        sourceHealthLastBufferAt[source] = now
        if let captureStartedAt = captureHealthMetrics.captureStartedAt {
            sourceHealthLastBufferActiveSeconds[source] = activeRecordingSeconds(
                startedAt: captureStartedAt,
                asOf: now
            )
        }
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

    /// Converts the global audio host clock into the meeting's active timeline.
    /// Each source normalizes its first value to file time zero in the writer;
    /// removing completed pause ranges here prevents intentional pauses from
    /// looking like capture outages while retaining genuine route-change gaps.
    private func pauseAdjustedHostTimeSeconds(for time: AVAudioTime) -> TimeInterval? {
        guard time.isHostTimeValid else { return nil }
        let hostTime = time.hostTime
        let pausedSeconds = completedPauseHostTimeRanges.reduce(evictedPauseHostTimeDuration) { total, range in
            guard hostTime > range.start else { return total }
            let overlapEnd = min(hostTime, range.end)
            guard overlapEnd > range.start else { return total }
            return total
                + AVAudioTime.seconds(forHostTime: overlapEnd)
                - AVAudioTime.seconds(forHostTime: range.start)
        }
        return AVAudioTime.seconds(forHostTime: hostTime) - pausedSeconds
    }

    private func appendCompletedPauseHostTimeRange(start: UInt64, end: UInt64) {
        guard end > start else { return }
        evictedPauseHostTimeDuration += appendBoundedCompletedHostTimeRange(
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

    @discardableResult
    private func appendBoundedCompletedHostTimeRange(
        start: UInt64,
        end: UInt64,
        to ranges: inout [HostTimeRange]
    ) -> TimeInterval {
        ranges.append(HostTimeRange(start: start, end: end))
        let overflowCount = ranges.count - Self.completedHostTimeRangeLimit
        guard overflowCount > 0 else { return 0 }

        let evictedDuration = ranges.prefix(overflowCount).reduce(0.0) { total, range in
            total
                + AVAudioTime.seconds(forHostTime: range.end)
                - AVAudioTime.seconds(forHostTime: range.start)
        }
        ranges.removeFirst(overflowCount)
        return evictedDuration
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
            logger.error(
                "meeting_recorded_source_audio_inspect_failed error_type=\(AudioCaptureDiagnostics.errorType(error), privacy: .public) error_detail=\(error.localizedDescription, privacy: .private)"
            )
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

    /// Schedule `microphone-cleaned.m4a` derivation from the raw mic + system
    /// sources. The returned readiness handle is the final-STT gate; stop must
    /// not wait for model-backed render work.
    private func scheduleCleanedMicrophoneRender(
        session: Session,
        availableSources: Set<AudioSource>,
        sourceAlignment: MeetingSourceAlignment,
        renderDuration: TimeInterval
    ) -> MeetingCleanedMicrophoneReadiness {
        let outputURL = session.folderURL.appendingPathComponent(
            MeetingCleanedMicRenderer.cleanedMicrophoneFileName)
        guard
            MeetingCleanedMicrophoneReadinessPolicy.production.shouldAttemptRender(
                for: renderDuration
            )
        else {
            return MeetingCleanedMicrophoneRenderScheduler.skipPredictedRenderTimeout(
                outputURL: outputURL,
                sessionID: session.id,
                fileManager: fileManager,
                eventName: "meeting_cleaned_mic"
            )
        }
        return cleanedMicrophoneReadinessScheduler(
            outputURL,
            availableSources.contains(.microphone) ? session.microphoneAudioURL : nil,
            availableSources.contains(.system) ? session.systemAudioURL : nil,
            sourceAlignment,
            session.id,
            cleanedMicConditionerFactory,
            fileManager,
            "meeting_cleaned_mic"
        )
    }

    private func buildSourceAlignment(
        availableSources: Set<AudioSource>,
        writerMetrics: [AudioSource: MeetingAudioStorageWriter.SourceWriteMetrics?]
    ) -> MeetingSourceAlignment {
        let candidateOrigins = availableSources.compactMap { sourceCaptureMetrics[$0]?.firstHostTime }
        let meetingOriginHostTime = candidateOrigins.min()
        let meetingOriginTimelineSeconds = availableSources.compactMap { source in
            (writerMetrics[source] ?? nil)?.timelineOriginSeconds
        }.min()

        let microphone =
            availableSources.contains(.microphone)
            ? makeAlignedTrack(
                source: .microphone,
                meetingOriginHostTime: meetingOriginHostTime,
                meetingOriginTimelineSeconds: meetingOriginTimelineSeconds,
                writerMetrics: writerMetrics[.microphone] ?? nil
            )
            : nil
        let system =
            availableSources.contains(.system)
            ? makeAlignedTrack(
                source: .system,
                meetingOriginHostTime: meetingOriginHostTime,
                meetingOriginTimelineSeconds: meetingOriginTimelineSeconds,
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
        meetingOriginTimelineSeconds: TimeInterval?,
        writerMetrics: MeetingAudioStorageWriter.SourceWriteMetrics?
    ) -> MeetingSourceAlignment.Track {
        let captureMetrics = sourceCaptureMetrics[source]
        return MeetingSourceAlignment.Track(
            firstHostTime: captureMetrics?.firstHostTime,
            lastHostTime: captureMetrics?.lastHostTime,
            startOffsetMs: startOffsetMs(
                captureMetrics: captureMetrics,
                sourceTimelineOriginSeconds: writerMetrics?.timelineOriginSeconds,
                meetingOriginHostTime: meetingOriginHostTime,
                meetingOriginTimelineSeconds: meetingOriginTimelineSeconds
            ),
            writtenFrameCount: writerMetrics?.writtenFrameCount ?? 0,
            timelineFrameCount: writerMetrics?.timelineFrameCount,
            sampleRate: writerMetrics?.sampleRate ?? 48_000
        )
    }

    private func startOffsetMs(
        captureMetrics: SourceCaptureMetrics?,
        sourceTimelineOriginSeconds: TimeInterval?,
        meetingOriginHostTime: UInt64?,
        meetingOriginTimelineSeconds: TimeInterval?
    ) -> Int {
        if let sourceTimelineOriginSeconds,
            let meetingOriginTimelineSeconds
        {
            return max(
                0,
                Int(((sourceTimelineOriginSeconds - meetingOriginTimelineSeconds) * 1_000).rounded())
            )
        }
        return MeetingSourceAlignment.startOffsetMs(
            hostTime: captureMetrics?.firstHostTime,
            originHostTime: meetingOriginHostTime
        )
    }

    private func captureHealthSummaryLine(
        session: Session,
        durationSeconds: TimeInterval,
        writerMetrics: [AudioSource: MeetingAudioStorageWriter.SourceWriteMetrics?],
        captureFailed: Bool,
        captureReport: MeetingCaptureReport?
    ) -> String {
        let interruptedSourceLabel =
            interruptedSources
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let microphoneMetrics = writerMetrics[.microphone] ?? nil
        let systemMetrics = writerMetrics[.system] ?? nil
        func coverageLabel(for source: AudioSource) -> String {
            guard let sourceReport = captureReport?.source(for: source) else {
                return "unknown"
            }
            return String(format: "%.3f", sourceReport.coverageRatio)
        }
        func statusLabel(for source: AudioSource) -> String {
            captureReport?.source(for: source)?.status.rawValue ?? "unknown"
        }
        return [
            "meeting_recording_health",
            "session=\(session.id.uuidString)",
            "duration_s=\(String(format: "%.3f", durationSeconds))",
            "captured_duration_s=\(String(format: "%.3f", Double(captureReport?.capturedDurationMs ?? 0) / 1_000))",
            "capture_quality=\(captureReport?.quality.rawValue ?? "unknown")",
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
            "mic_coverage=\(coverageLabel(for: .microphone))",
            "system_coverage=\(coverageLabel(for: .system))",
            "mic_capture_status=\(statusLabel(for: .microphone))",
            "system_capture_status=\(statusLabel(for: .system))",
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
            "current_delay_samples=\(diagnostics.currentDelaySamples)",
            "delay_confidence=\(String(format: "%.3f", diagnostics.delayConfidence))",
            "delay_estimate_count=\(diagnostics.delayEstimateCount)",
            "rejected_delay_estimates=\(diagnostics.rejectedDelayEstimates)",
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

    private var microphoneCaptureHealthLevel: Float {
        max(latestLevels.microphone, recentMicrophoneRms, processedMicrophoneCaptureHealthLevel)
    }

    private var systemCaptureHealthLevel: Float {
        max(latestLevels.system, recentSystemRms)
    }

    private var processedMicrophoneCaptureHealthLevel: Float {
        guard recentProcessedMicRms > 0 else { return 0 }
        return Self.captureHealthLevel(fromRawRms: recentProcessedMicRms)
    }

    private static func captureHealthLevel(fromRawRms rms: Float) -> Float {
        min(1, max(0, rms * processedRmsHealthLevelScale))
    }

    private func updateMicrophoneRms(with bufferRms: Float) {
        recentMicrophoneRms = exponentialMovingAverage(previous: recentMicrophoneRms, sample: bufferRms)
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
        let finishedSessionID = currentSession?.id
        currentSession = nil
        if durableStopSessionID == finishedSessionID {
            durableStopSessionID = nil
        }
        currentNotes = nil
        currentLockFile = nil
        paused = false
        pausedAt = nil
        pausedHostTime = nil
        completedPauseHostTimeRanges = []
        evictedPauseHostTimeDuration = 0
        accumulatedPausedDuration = 0
        microphoneMuted = false
        microphoneMutedHostTime = nil
        completedMicrophoneMuteHostTimeRanges = []
        reusableMicrophoneSilentBuffer = nil
        micConditioner = PassthroughMicConditioner()
        latestLevels = MeetingAudioLevels()
        sourceCaptureMetrics = [:]
        captureHealthMetrics = CaptureHealthMetrics()
        sourceHealthLastBufferAt = [:]
        sourceHealthLastBufferActiveSeconds = [:]
        activeMicrophoneStall = nil
        interruptedSources = []
        recoveringSources = []
        recentMicrophoneRms = 0
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
        if let finishedSessionID {
            finishCaptureFailureSignal(for: finishedSessionID)
        }
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
            cached.frameCapacity >= buffer.frameLength
        {
            cached.frameLength = buffer.frameLength
            Self.zeroPCMBuffer(cached)
            return cached
        }

        guard
            let silent = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: buffer.frameLength
            )
        else {
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
