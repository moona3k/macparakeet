import AVFoundation
import Foundation

/// Finalized source audio and durable session metadata. Playback is deliberately
/// absent from this contract: its duration is unknown until preparation finishes.
public struct MeetingRecordingCapture: Sendable, Equatable {
    public let lock: MeetingRecordingLockFile
    public let metadata: MeetingRecordingMetadata
    public let folderURL: URL
    public let microphoneAudioURL: URL
    public let systemAudioURL: URL
    private let cleanedMicrophonePreparation: (@Sendable (MeetingSourceAlignment) -> MeetingCleanedMicrophoneReadiness)?

    public var sessionID: UUID { lock.sessionId }
    public var displayName: String { lock.titleOverride ?? lock.displayName }
    public var mixedAudioURL: URL { folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.playback) }

    init(
        lock: MeetingRecordingLockFile,
        metadata: MeetingRecordingMetadata,
        folderURL: URL,
        microphoneAudioURL: URL,
        systemAudioURL: URL,
        cleanedMicrophonePreparation: (@Sendable (MeetingSourceAlignment) -> MeetingCleanedMicrophoneReadiness)? = nil
    ) {
        self.lock = lock
        self.metadata = metadata
        self.folderURL = folderURL
        self.microphoneAudioURL = microphoneAudioURL
        self.systemAudioURL = systemAudioURL
        self.cleanedMicrophonePreparation = cleanedMicrophonePreparation
    }

    /// Retry reconstructs work from durable facts, never from an old Task handle.
    public static func load(from folderURL: URL) throws -> Self {
        let configuration = MeetingEchoSuppressionConfiguration.fromEnvironment()
        return try load(from: folderURL) {
            MeetingEchoSuppressionFactory.makeConditioner(configuration: configuration)
        }
    }

    static func load(
        from folderURL: URL,
        cleanedMicConditionerFactory: @escaping @Sendable () -> any MicConditioning
    ) throws -> Self {
        guard let lock = try MeetingRecordingLockFileStore().read(folderURL: folderURL) else {
            throw MeetingFinalizationOwnershipError.missingLock
        }
        guard lock.state == .awaitingTranscription,
            !MeetingAudioWriterFinalizationRegistry.contains(folderURL: folderURL)
        else { throw MeetingRecordingRecoveryError.writerFinalizationInProgress }
        let microphoneURL = MeetingArtifactAudioFileNames.resolveRawMicrophoneURL(in: folderURL).url
        let systemURL = MeetingArtifactAudioFileNames.resolveRawSystemURL(in: folderURL).url
        return try Self(
            lock: lock,
            metadata: MeetingRecordingMetadataStore.load(from: folderURL),
            folderURL: folderURL,
            microphoneAudioURL: microphoneURL,
            systemAudioURL: systemURL,
            cleanedMicrophonePreparation: makeCleanedMicrophonePreparation(
                folderURL: folderURL, microphoneURL: microphoneURL, systemURL: systemURL,
                sessionID: lock.sessionId, conditionerFactory: cleanedMicConditionerFactory
            )
        )
    }

    /// Snapshot dependencies only. Derived writers start after playback and
    /// metadata preparation succeed while the queue owns the folder lease.
    static func makeCleanedMicrophonePreparation(
        folderURL: URL,
        microphoneURL: URL,
        systemURL: URL,
        sessionID: UUID,
        conditionerFactory: @escaping @Sendable () -> any MicConditioning,
        scheduler: @escaping MeetingCleanedMicrophoneReadinessScheduling = {
            MeetingCleanedMicrophoneRenderScheduler.schedule(
                outputURL: $0, microphoneURL: $1, systemURL: $2, sourceAlignment: $3,
                sessionID: $4, conditionerFactory: $5, fileManager: $6, eventName: $7
            )
        },
        fileManager: MeetingPlaybackArtifactBuilder.SendableFileManager = .init()
    ) -> @Sendable (MeetingSourceAlignment) -> MeetingCleanedMicrophoneReadiness {
        { sourceAlignment in
            let outputURL = folderURL.appendingPathComponent(MeetingCleanedMicRenderer.cleanedMicrophoneFileName)
            guard
                MeetingCleanedMicrophoneReadinessPolicy.production.shouldAttemptRender(
                    for: sourceAlignment.cleanedMicrophoneRenderDurationSeconds
                )
            else {
                return MeetingCleanedMicrophoneRenderScheduler.skipPredictedRenderTimeout(
                    outputURL: outputURL, sessionID: sessionID, fileManager: fileManager.value,
                    eventName: "meeting_cleaned_mic"
                )
            }
            return scheduler(
                outputURL, sourceAlignment.microphone != nil ? microphoneURL : nil,
                sourceAlignment.system != nil ? systemURL : nil, sourceAlignment,
                sessionID, conditionerFactory, fileManager.value, "meeting_cleaned_mic"
            )
        }
    }

    public func makeProcessingTranscription() -> Transcription {
        Transcription(
            fileName: displayName,
            filePath: mixedAudioURL.path,
            meetingArtifactFolderPath: folderURL.path,
            durationMs: nil,
            language: nil,
            status: .processing,
            sourceType: .meeting,
            meetingTypeId: metadata.meetingTypeId,
            userNotes: lock.notes,
            meetingStartContext: metadata.startContext,
            meetingCaptureReport: metadata.captureReport,
            engine: metadata.speechEngine.engine.rawValue,
            calendarEventSnapshot: metadata.calendarEventSnapshot
        )
    }

    /// Owns only this session's artifacts. It cannot reset the capture service or
    /// release a replacement recording's microphone / live speech lease.
    public func preparePlayback(
        using audioConverter: any AudioFileConverting = AudioFileConverter()
    ) async throws -> MeetingRecordingOutput {
        try await preparePlayback(using: audioConverter, fileManager: .init())
    }

    func preparePlayback(
        using audioConverter: any AudioFileConverting,
        fileManager: MeetingPlaybackArtifactBuilder.SendableFileManager
    ) async throws -> MeetingRecordingOutput {
        let startedAt = Date()
        let sourceAlignment = retainedSourceAlignment()
        let candidates = [(AudioSource.microphone, microphoneAudioURL), (.system, systemAudioURL)]
            .compactMap { source, url -> MeetingPlaybackArtifactBuilder.Candidate? in
                guard let track = sourceAlignment.track(for: source) else { return nil }
                return .init(source: source, url: url, track: track)
            }
        let playback = try await MeetingPlaybackArtifactBuilder(
            audioConverter: audioConverter, fileManager: fileManager
        ).build(
            candidates: candidates, outputURL: mixedAudioURL, sourceAlignment: sourceAlignment
        )
        let report = metadata.captureReport.map {
            MeetingCaptureReport(
                sourceMode: $0.sourceMode,
                sourceAlignment: sourceAlignment,
                elapsedDurationMs: $0.elapsedDurationMs,
                interruptedSources: Set($0.interruptedSources),
                silentSources: Set($0.sources.filter { $0.status == .silent }.map(\.source)),
                captureFailed: $0.captureFailed,
                playbackFallbackSource: playback.method == .bestSourceFallback ? playback.source : nil
            )
        }
        let finalMetadata = MeetingRecordingMetadata(
            sourceAlignment: sourceAlignment, captureReport: report,
            speechEngine: metadata.speechEngine, speechEngineWasCaptured: metadata.speechEngineWasCaptured,
            previewSpeechEngine: metadata.previewSpeechEngine, startContext: metadata.startContext,
            echoSuppression: metadata.echoSuppression, calendarEventSnapshot: metadata.calendarEventSnapshot,
            meetingTypeId: metadata.meetingTypeId
        )
        if finalMetadata != metadata {
            try MeetingRecordingMetadataStore.save(finalMetadata, folderURL: folderURL, fileManager: fileManager.value)
        }
        try Task.checkCancellation()
        let cleanedMicrophoneReadiness = cleanedMicrophonePreparation?(sourceAlignment)
        AudioCaptureDiagnostics.append(
            "meeting_playback_prepared session=\(sessionID.uuidString) duration_ms=\(Int(Date().timeIntervalSince(startedAt) * 1_000)) outcome=\(playback.method.rawValue)"
        )
        return MeetingRecordingOutput(
            sessionID: sessionID,
            displayName: displayName,
            folderURL: folderURL,
            mixedAudioURL: mixedAudioURL,
            microphoneAudioURL: microphoneAudioURL,
            systemAudioURL: systemAudioURL,
            cleanedMicrophoneAudioURL: cleanedMicrophoneReadiness?.outputURL
                ?? (sourceAlignment.microphone != nil && sourceAlignment.system != nil
                    ? retainedCleanedMicrophoneURL : nil),
            cleanedMicrophoneReadiness: cleanedMicrophoneReadiness,
            durationSeconds: playback.durationSeconds,
            sourceAlignment: sourceAlignment,
            captureReport: report,
            speechEngine: metadata.speechEngine,
            speechEngineWasCaptured: metadata.speechEngineWasCaptured,
            previewSpeechEngine: metadata.previewSpeechEngine,
            startContext: metadata.startContext,
            userNotes: lock.notes,
            calendarEventSnapshot: metadata.calendarEventSnapshot,
            meetingTypeId: metadata.meetingTypeId
        )
    }

    /// A queued/retried source can disappear or become truncated. Preserve the
    /// original timeline for intact media, but never send a vanished track to STT.
    private func retainedSourceAlignment() -> MeetingSourceAlignment {
        func retainedTrack(_ source: AudioSource, at url: URL) -> MeetingSourceAlignment.Track? {
            guard let track = metadata.sourceAlignment.track(for: source),
                let file = try? AVAudioFile(forReading: url), file.length > 0,
                file.processingFormat.sampleRate.isFinite, file.processingFormat.sampleRate > 0,
                track.sampleRate.isFinite, track.sampleRate > 0
            else { return nil }
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let savedFrames = max(0, track.timelineFrameCount ?? track.writtenFrameCount)
            // AAC packet rounding must not inflate or slightly shorten the
            // exact writer-derived timeline of an intact capture.
            if duration + 0.1 >= Double(savedFrames) / track.sampleRate { return track }
            let availableFrames = Int64((duration * track.sampleRate).rounded())
            return MeetingSourceAlignment.Track(
                firstHostTime: track.firstHostTime, lastHostTime: track.lastHostTime,
                startOffsetMs: track.startOffsetMs,
                writtenFrameCount: min(track.writtenFrameCount, availableFrames),
                timelineFrameCount: availableFrames, sampleRate: track.sampleRate
            )
        }
        return MeetingSourceAlignment(
            meetingOriginHostTime: metadata.sourceAlignment.meetingOriginHostTime,
            microphone: retainedTrack(.microphone, at: microphoneAudioURL),
            system: retainedTrack(.system, at: systemAudioURL)
        )
    }

    private var retainedCleanedMicrophoneURL: URL? {
        let url = folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.cleanedMicrophone)
        return MeetingRecordingOutput.isViablePlaybackFile(at: url) ? url : nil
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lock == rhs.lock && lhs.metadata == rhs.metadata && lhs.folderURL == rhs.folderURL
            && lhs.microphoneAudioURL == rhs.microphoneAudioURL && lhs.systemAudioURL == rhs.systemAudioURL
    }
}

/// A queue item either needs playback preparation or already has playable media.
/// Existing archived/imported callers keep the ready-output contract.
public enum MeetingFinalizationInput: Sendable, Equatable {
    case capture(MeetingRecordingCapture)
    case prepared(MeetingRecordingOutput)

    public var recording: MeetingRecordingOutput? {
        if case .prepared(let output) = self { return output }
        return nil
    }

    public var sessionID: UUID {
        switch self {
        case .capture(let capture): return capture.sessionID
        case .prepared(let output): return output.sessionID
        }
    }

    public var folderURL: URL {
        switch self {
        case .capture(let capture): return capture.folderURL
        case .prepared(let output): return output.folderURL
        }
    }
}
