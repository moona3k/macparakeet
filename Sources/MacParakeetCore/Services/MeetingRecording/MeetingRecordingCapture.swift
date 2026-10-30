import Foundation

/// Finalized source audio and durable session metadata. Playback is deliberately
/// absent from this contract: its duration is unknown until preparation finishes.
public struct MeetingRecordingCapture: Sendable, Equatable {
    public let lock: MeetingRecordingLockFile
    public let metadata: MeetingRecordingMetadata
    public let folderURL: URL
    public let microphoneAudioURL: URL
    public let systemAudioURL: URL
    let cleanedMicrophoneReadiness: MeetingCleanedMicrophoneReadiness?

    public var sessionID: UUID { lock.sessionId }
    public var displayName: String { lock.titleOverride ?? lock.displayName }
    public var mixedAudioURL: URL { folderURL.appendingPathComponent(MeetingArtifactAudioFileNames.playback) }

    init(
        lock: MeetingRecordingLockFile,
        metadata: MeetingRecordingMetadata,
        folderURL: URL,
        microphoneAudioURL: URL,
        systemAudioURL: URL,
        cleanedMicrophoneReadiness: MeetingCleanedMicrophoneReadiness? = nil
    ) {
        self.lock = lock
        self.metadata = metadata
        self.folderURL = folderURL
        self.microphoneAudioURL = microphoneAudioURL
        self.systemAudioURL = systemAudioURL
        self.cleanedMicrophoneReadiness = cleanedMicrophoneReadiness
    }

    /// Retry reconstructs work from durable facts, never from an old Task handle.
    public static func load(from folderURL: URL) throws -> Self {
        guard let lock = try MeetingRecordingLockFileStore().read(folderURL: folderURL) else {
            throw MeetingFinalizationOwnershipError.missingLock
        }
        guard lock.state == .awaitingTranscription,
            !MeetingAudioWriterFinalizationRegistry.contains(folderURL: folderURL)
        else { throw MeetingRecordingRecoveryError.writerFinalizationInProgress }
        return try Self(
            lock: lock,
            metadata: MeetingRecordingMetadataStore.load(from: folderURL),
            folderURL: folderURL,
            microphoneAudioURL: MeetingArtifactAudioFileNames.resolveRawMicrophoneURL(in: folderURL).url,
            systemAudioURL: MeetingArtifactAudioFileNames.resolveRawSystemURL(in: folderURL).url
        )
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
        let candidates = [(AudioSource.microphone, microphoneAudioURL), (.system, systemAudioURL)]
            .compactMap { source, url -> MeetingPlaybackArtifactBuilder.Candidate? in
                guard let track = metadata.sourceAlignment.track(for: source) else { return nil }
                return .init(source: source, url: url, track: track)
            }
        let playback = try await MeetingPlaybackArtifactBuilder(
            audioConverter: audioConverter, fileManager: fileManager
        ).build(
            candidates: candidates, outputURL: mixedAudioURL, sourceAlignment: metadata.sourceAlignment
        )
        let report = metadata.captureReport.map {
            MeetingCaptureReport(
                sourceMode: $0.sourceMode,
                sourceAlignment: metadata.sourceAlignment,
                elapsedDurationMs: $0.elapsedDurationMs,
                interruptedSources: Set($0.interruptedSources),
                silentSources: Set($0.sources.filter { $0.status == .silent }.map(\.source)),
                captureFailed: $0.captureFailed,
                playbackFallbackSource: playback.method == .bestSourceFallback ? playback.source : nil
            )
        }
        if report != metadata.captureReport {
            try MeetingRecordingMetadataStore.save(
                metadata.withCaptureReport(report), folderURL: folderURL, fileManager: fileManager.value)
        }
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
                ?? retainedCleanedMicrophoneURL,
            cleanedMicrophoneReadiness: cleanedMicrophoneReadiness,
            durationSeconds: playback.durationSeconds,
            sourceAlignment: metadata.sourceAlignment,
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
