import AVFoundation
import Foundation

public protocol MeetingImportAudioTranscribing: Sendable {
    func prepareMeetingTranscription(recording: MeetingRecordingOutput) async throws -> Transcription
    func finalizeMeetingTranscription(
        recording: MeetingRecordingOutput,
        updating transcriptionID: UUID,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription
}

extension TranscriptionService: MeetingImportAudioTranscribing {}

/// Imports one independent archive. Before row publication only the invocation's
/// exact folder is disposable; afterward ordinary meeting retry owns its audio.
public actor MeetingImportService {
    private static let stagingPrefix = ".meeting-import-"
    private let converter: any AudioFileConverting
    private let transcriptionService: any MeetingImportAudioTranscribing
    private let transcriptionRepo: any TranscriptionRepositoryProtocol
    private let completionService: any SavedAudioAutoPromptCompletionServicing
    private let recordingsRoot: @Sendable () throws -> URL
    private let lockFileStore: any MeetingRecordingLockFileStoring & MeetingFinalizationOwnershipClaiming
    private let retentionConfig: @Sendable () -> MeetingAudioRetention
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        converter: any AudioFileConverting = AudioFileConverter(),
        transcriptionService: any MeetingImportAudioTranscribing,
        transcriptionRepo: any TranscriptionRepositoryProtocol,
        completionService: any SavedAudioAutoPromptCompletionServicing,
        recordingsRoot: @escaping @Sendable () throws -> URL,
        lockFileStore: any MeetingRecordingLockFileStoring & MeetingFinalizationOwnershipClaiming =
            MeetingRecordingLockFileStore(),
        retentionConfig: @escaping @Sendable () -> MeetingAudioRetention = { .keepForever },
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.converter = converter
        self.transcriptionService = transcriptionService
        self.transcriptionRepo = transcriptionRepo
        self.completionService = completionService
        self.recordingsRoot = recordingsRoot
        self.lockFileStore = lockFileStore
        self.retentionConfig = retentionConfig
        self.fileManager = fileManager
        self.now = now
    }

    public func importMeeting(
        _ request: MeetingImportRequest,
        onProgress: (@Sendable (MeetingImportProgress) -> Void)? = nil
    ) async throws -> MeetingImportResult {
        let (recording, prepared, ownership) = try await publish(request, onProgress: onProgress)
        var row = prepared
        var warnings: [MeetingImportWarning] = []
        onProgress?(.published(row))

        do {
            try Task.checkCancellation()
            row = try await transcriptionService.finalizeMeetingTranscription(
                recording: recording, updating: row.id,
                onProgress: { onProgress?(.transcription($0)) })
        } catch {
            warnings.append(
                error is CancellationError
                    ? .transcriptionCancelled : .transcriptionFailed(message: error.localizedDescription))
            // Preflight can fail before TranscriptionService sets a terminal
            // status. Retain its durable row and never downgrade saved text.
            do {
                if let current = try transcriptionRepo.fetch(id: row.id) {
                    row = current
                    if current.status == .processing {
                        try transcriptionRepo.updateStatus(
                            id: current.id, status: error is CancellationError ? .cancelled : .error,
                            errorMessage: error.localizedDescription)
                        row = try transcriptionRepo.fetch(id: current.id) ?? current
                    }
                }
            } catch {
                warnings.append(.persistenceFailed(message: error.localizedDescription))
            }
        }

        if row.status == .completed {
            do {
                try await MeetingRecordingSettlement(lockFileStore: lockFileStore, transcriptionRepo: transcriptionRepo)
                    .settleCompletedTranscription(
                        folderURL: recording.folderURL, transcriptionID: row.id, sessionID: recording.sessionID)
            } catch {
                warnings.append(.settlementFailed(message: error.localizedDescription))
            }
        }
        // Release media ownership before automation; provider work cannot turn
        // a completed transcript into a failed transcription or retain its lock.
        do { try lockFileStore.releaseFinalizationOwnership(ownership) } catch {
            warnings.append(.ownershipReleaseFailed(message: error.localizedDescription))
        }

        if row.status == .completed {
            do {
                try Task.checkCancellation()
                let automation = try await completionService.completeAutoPrompts(
                    for: row, onProgress: { onProgress?(.automation($0)) })
                for outcome in automation.outcomes {
                    if case .failed(let message) = outcome.status {
                        warnings.append(
                            .promptFailed(promptID: outcome.promptId, promptName: outcome.promptName, message: message))
                    }
                }
                for warning in automation.warnings {
                    switch warning {
                    case .knowledgeCardFailed(let message): warnings.append(.knowledgeCardFailed(message: message))
                    case .artifactRefreshFailed(let message): warnings.append(.artifactRefreshFailed(message: message))
                    }
                }
                try Task.checkCancellation()
            } catch {
                warnings.append(
                    error is CancellationError
                        ? .automationCancelled : .automationFailed(message: error.localizedDescription))
            }
        }
        if row.status == .completed, retentionConfig().mode == .deleteImmediately {
            do {
                let detached = try TranscriptionAssetCleanup.detachOwnedMeetingAudio(
                    for: row, repository: transcriptionRepo, fileManager: fileManager)
                if !detached.detached {
                    warnings.append(
                        .audioRetentionFailed(message: TranscriptionAssetCleanup.unmanagedMeetingAudioMessage))
                }
            } catch {
                warnings.append(.audioRetentionFailed(message: error.localizedDescription))
            }
        }
        do { row = try transcriptionRepo.fetch(id: row.id) ?? row } catch {
            warnings.append(.persistenceFailed(message: error.localizedDescription))
        }
        return MeetingImportResult(transcription: row, warnings: warnings)
    }

    private func publish(
        _ request: MeetingImportRequest,
        onProgress: (@Sendable (MeetingImportProgress) -> Void)?
    ) async throws -> (MeetingRecordingOutput, Transcription, MeetingFinalizationOwnershipLease) {
        try Task.checkCancellation()
        let defaults = try request.resolveDefaults(now: now())
        let root = try recordingsRoot().resolvingSymlinksInPath().standardizedFileURL
        let lease = try MeetingMediaMutationLease.acquire(roots: [root])
        defer { lease.release() }
        try cleanStaleStaging(in: root, preserving: request.sourceURL)
        try Task.checkCancellation()
        let sessionID = UUID()
        let staging = root.appendingPathComponent(Self.stagingPrefix + sessionID.uuidString, isDirectory: true)
        let final = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var finalFolderPublished = false
        var ownership: MeetingFinalizationOwnershipLease?
        var prepared: Transcription?
        defer {
            if prepared == nil {
                if let ownership { try? lockFileStore.releaseFinalizationOwnership(ownership) }
                if !finalFolderPublished { try? fileManager.removeItem(at: staging) }
            }
        }
        onProgress?(.preparingMedia)
        let system = staging.appendingPathComponent(MeetingArtifactAudioFileNames.rawSystem)
        try await converter.mixToM4A(inputURLs: [request.sourceURL], outputURL: system, sourceAlignment: nil)
        try Task.checkCancellation()
        let audio = try AVAudioFile(forReading: system)
        let rate = audio.processingFormat.sampleRate
        let duration = Double(audio.length) / rate
        guard audio.length > 0, rate.isFinite, rate > 0, duration.isFinite, duration > 0 else {
            throw MeetingImportError.invalidAudio
        }
        let alignment = MeetingSourceAlignment(
            meetingOriginHostTime: nil, microphone: nil,
            system: .init(
                firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0,
                writtenFrameCount: audio.length, sampleRate: rate))
        let playback = staging.appendingPathComponent(MeetingArtifactAudioFileNames.playback)
        do { try fileManager.linkItem(at: system, to: playback) } catch {
            try fileManager.copyItem(at: system, to: playback)
        }
        try MeetingRecordingMetadataStore.save(
            .init(sourceAlignment: alignment, speechEngineWasCaptured: false), folderURL: staging,
            fileManager: fileManager)
        let retentionStartedAt = now()
        try lockFileStore.write(
            .init(
                sessionId: sessionID, startedAt: defaults.startedAt, displayName: defaults.title,
                state: .awaitingTranscription, speechEngineWasCaptured: false,
                audioRetentionStartedAt: retentionStartedAt, titleOverride: defaults.titleOverride), folderURL: staging)
        try Task.checkCancellation()
        try fileManager.moveItem(at: staging, to: final)
        finalFolderPublished = true
        let claimed = try lockFileStore.claimFinalizationOwnership(folderURL: final)
        ownership = claimed
        let recording = MeetingRecordingOutput(
            sessionID: sessionID, displayName: defaults.title, folderURL: final,
            mixedAudioURL: final.appendingPathComponent(MeetingArtifactAudioFileNames.playback),
            microphoneAudioURL: final.appendingPathComponent(MeetingArtifactAudioFileNames.rawMicrophone),
            systemAudioURL: final.appendingPathComponent(MeetingArtifactAudioFileNames.rawSystem),
            durationSeconds: duration, sourceAlignment: alignment, speechEngineWasCaptured: false,
            startedAt: defaults.startedAt, audioRetentionStartedAt: retentionStartedAt,
            titleOverride: defaults.titleOverride)
        try Task.checkCancellation()
        let row = try await transcriptionService.prepareMeetingTranscription(recording: recording)
        prepared = row
        return (recording, row, claimed)
    }

    private func cleanStaleStaging(in root: URL, preserving source: URL) throws {
        let sourcePaths = [source.standardizedFileURL.path, source.resolvingSymlinksInPath().standardizedFileURL.path]
        for candidate in try fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        {
            let name = candidate.lastPathComponent
            guard name.hasPrefix(Self.stagingPrefix),
                let id = UUID(uuidString: String(name.dropFirst(Self.stagingPrefix.count))),
                name == Self.stagingPrefix + id.uuidString
            else { continue }
            let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let path = candidate.standardizedFileURL.path
            guard !sourcePaths.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) else { continue }
            try fileManager.removeItem(at: candidate)
        }
    }
}
