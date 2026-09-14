import AVFoundation
import os
import XCTest
@testable import MacParakeetCore

final class MeetingImportServiceTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var repo: TranscriptionRepository!
    private var transcriber: ImportTranscriber!
    private var converter: ImportConverter!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = TranscriptionRepository(dbQueue: try DatabaseManager().dbQueue)
        transcriber = ImportTranscriber(repo: repo)
        converter = ImportConverter()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func service(
        audioConverter: (any AudioFileConverting)? = nil,
        completion: ImportCompletion = ImportCompletion(),
        fileManager: FileManager = .default,
        lockStore: (any MeetingRecordingLockFileStoring & MeetingFinalizationOwnershipClaiming)? = nil,
        retentionConfig: @escaping @Sendable () -> MeetingAudioRetention = { .keepForever }
    ) -> MeetingImportService {
        let destination = root!
        let clock = now
        return MeetingImportService(
            converter: audioConverter ?? converter, transcriptionService: transcriber, transcriptionRepo: repo,
            completionService: completion, recordingsRoot: { destination },
            lockFileStore: lockStore ?? MeetingRecordingLockFileStore(), retentionConfig: retentionConfig,
            fileManager: fileManager, now: { clock })
    }

    private func source(_ name: String = "Planning session.wav") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("External original bytes".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: url.path)
        return url
    }

    private func folders() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    func testAudioAndVideoPublishIndependentSystemOnlyArchivesAndPreserveSource() async throws {
        for name in ["Planning session.wav", "Planning session.mov"] {
            let sourceURL = try source(name)
            let before = try Data(contentsOf: sourceURL)
            let modified = try sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let result = try await service().importMeeting(.init(sourceURL: sourceURL))
            XCTAssertEqual(result.completion, .completed)
            XCTAssertEqual(result.transcription.sourceType, .meeting)
            XCTAssertEqual(
                result.transcription.createdAt, try sourceURL.resourceValues(forKeys: [.creationDateKey]).creationDate)
            XCTAssertEqual(result.transcription.audioRetentionStartedAt, now)
            XCTAssertNil(result.transcription.titleOverride)
            let output = try XCTUnwrap(transcriber.recordings.last)
            XCTAssertNil(output.sourceAlignment.microphone)
            XCTAssertEqual(output.sourceAlignment.system?.startOffsetMs, 0)
            XCTAssertGreaterThan(output.sourceAlignment.system?.writtenFrameCount ?? 0, 0)
            XCTAssertFalse(output.speechEngineWasCaptured)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.microphoneAudioURL.path))
            XCTAssertEqual(try Data(contentsOf: output.systemAudioURL), try Data(contentsOf: output.mixedAudioURL))
            XCTAssertEqual(try Data(contentsOf: sourceURL), before)
            XCTAssertEqual(
                try sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
            let originalInode =
                try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.systemFileNumber] as? NSNumber
            let managedInode =
                try FileManager.default.attributesOfItem(atPath: output.systemAudioURL.path)[.systemFileNumber]
                as? NSNumber
            XCTAssertNotEqual(originalInode, managedInode)
            XCTAssertNil(try MeetingRecordingLockFileStore().read(folderURL: output.folderURL))
        }
        XCTAssertEqual(try repo.count(), 2)
    }

    func testRealFFmpegImportsAudioAndVideoAndRejectsVideoWithoutAudio() async throws {
        guard let ffmpeg = BinaryBootstrap.findSystemFFmpeg() else { throw XCTSkip("System FFmpeg is unavailable") }
        for ext in ["wav", "mov"] {
            let input = directory.appendingPathComponent("real.\(ext)")
            var args = ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.3"]
            if ext == "mov" {
                args += [
                    "-f", "lavfi", "-i", "color=c=black:s=32x32:d=0.3", "-c:v", "mpeg4", "-c:a", "aac", "-shortest",
                ]
            }
            try runFFmpeg(ffmpeg, args + ["-y", input.path])
            let before = try Data(contentsOf: input)
            let modified = try input.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let result = try await service(audioConverter: AudioFileConverter()).importMeeting(.init(sourceURL: input))
            XCTAssertEqual(result.completion, .completed)
            XCTAssertEqual(try Data(contentsOf: input), before)
            XCTAssertEqual(
                try input.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
            let output = try XCTUnwrap(transcriber.recordings.last)
            let videoTracks = try await AVURLAsset(url: output.systemAudioURL).loadTracks(withMediaType: .video)
            XCTAssertTrue(videoTracks.isEmpty)
            XCTAssertGreaterThan(output.durationSeconds, 0)
        }
        let silentVideo = directory.appendingPathComponent("no-audio.mov")
        try runFFmpeg(
            ffmpeg,
            [
                "-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=c=black:s=32x32:d=0.3",
                "-c:v", "mpeg4", "-y", silentVideo.path,
            ])
        for input in [silentVideo, try source("corrupt.wav")] {
            do {
                _ = try await service(audioConverter: AudioFileConverter()).importMeeting(.init(sourceURL: input))
                XCTFail("Expected no usable audio")
            } catch {}
        }
        XCTAssertEqual(try repo.count(), 2)
        XCTAssertEqual(try folders().count, 2)
    }

    func testRealTranscriptionServiceIndexesAndMaterializesImportedMeeting() async throws {
        let database = try DatabaseManager()
        let repository = TranscriptionRepository(dbQueue: database.dbQueue)
        let segments = SegmentRepository(dbQueue: database.dbQueue)
        let audio = MockAudioProcessor()
        let speech = MockSTTClient()
        let converted = directory.appendingPathComponent("stt-input.m4a")
        try await converter.mixToM4A(inputURLs: [], outputURL: converted, sourceAlignment: nil)
        await audio.configure(convertResult: converted)
        await speech.configure(
            result: STTResult(
                text: "Imported meeting speech",
                words: [
                    TimestampedWord(word: "Imported", startMs: 0, endMs: 200, confidence: 0.99),
                    TimestampedWord(word: "meeting", startMs: 200, endMs: 400, confidence: 0.99),
                    TimestampedWord(word: "speech", startMs: 400, endMs: 800, confidence: 0.99),
                ]))
        let selectedEngine = SpeechEngineSelection(engine: .whisper)
        let realTranscriber = TranscriptionService(
            audioProcessor: audio, sttTranscriber: speech, transcriptionRepo: repository,
            segmentRepo: segments, knowledgeLayerMutator: KnowledgeLayerMutationService(dbQueue: database.dbQueue),
            shouldAutoGenerateMeetingTitles: { false }, shouldDiarizeMeetings: { false },
            fileSpeechEngineSelection: { selectedEngine }, meetingArtifactStore: MeetingArtifactStore(),
            meetingAutomationHookRunner: nil)
        let destination = root!
        let clock = now
        let importer = MeetingImportService(
            converter: converter, transcriptionService: realTranscriber, transcriptionRepo: repository,
            completionService: ImportCompletion(), recordingsRoot: { destination }, now: { clock })
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let result = try await importer.importMeeting(
            .init(sourceURL: source(), titleOverride: "Explicit historical meeting")
        ) { progress in
            switch progress {
            case .preparingMedia: events.withLock { $0.append("preparing") }
            case .published: events.withLock { $0.append("published") }
            case .transcription: events.withLock { $0.append("transcription") }
            case .automation: events.withLock { $0.append("automation") }
            }
        }
        XCTAssertEqual(result.completion, .completed)
        XCTAssertEqual(result.transcription.titleOverride, "Explicit historical meeting")
        XCTAssertEqual(result.transcription.audioRetentionStartedAt, now)
        XCTAssertNil(result.transcription.sourceURL)
        XCTAssertEqual(try repository.count(), 1)
        XCTAssertFalse(try segments.fetch(transcriptionId: result.transcription.id).isEmpty)
        let folder = URL(fileURLWithPath: try XCTUnwrap(result.transcription.meetingArtifactFolderPath))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(MeetingArtifactStore.transcriptFileName).path))
        XCTAssertNil(try MeetingRecordingLockFileStore().read(folderURL: folder))
        let routes = await speech.speechEngineSelections
        XCTAssertEqual(routes, [selectedEngine])
        let observed = events.withLock { $0 }
        XCTAssertEqual(Array(observed.prefix(2)), ["preparing", "published"])
        XCTAssertTrue(observed.contains("transcription"))
    }

    private func runFFmpeg(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testExplicitTitleAndHistoricalDateArePreservedInRetryLock() async throws {
        transcriber.failure = TestFailure.failed
        let result = try await service().importMeeting(
            .init(
                sourceURL: source(), titleOverride: "  Customer workshop \n",
                startedAt: Date(timeIntervalSince1970: 1234)))
        XCTAssertEqual(result.transcription.titleOverride, "Customer workshop")
        XCTAssertEqual(result.transcription.createdAt, Date(timeIntervalSince1970: 1234))
        let lock = try XCTUnwrap(MeetingRecordingLockFileStore().read(folderURL: transcriber.recordings[0].folderURL))
        XCTAssertEqual(lock.titleOverride, "Customer workshop")
        XCTAssertEqual(lock.startedAt, result.transcription.createdAt)
        XCTAssertEqual(lock.audioRetentionStartedAt, now)
        XCTAssertEqual(lock.state, .awaitingTranscription)
        XCTAssertNil(lock.finalizationLeaseId)
    }

    func testInvalidSourcesAndBlankExplicitTitlePublishNothing() async throws {
        let unsupported = try source("notes.txt")
        let valid = try source()
        let missing = directory.appendingPathComponent("missing.wav")
        XCTAssertThrowsError(try MeetingImportRequest(sourceURL: missing).resolveDefaults()) { error in
            guard case MeetingImportError.invalidSource = error else {
                return XCTFail("Expected invalidSource, got \(error)")
            }
        }
        for request in [
            MeetingImportRequest(sourceURL: missing),
            MeetingImportRequest(sourceURL: root),
            MeetingImportRequest(sourceURL: unsupported),
            MeetingImportRequest(sourceURL: valid, titleOverride: " \n "),
            MeetingImportRequest(sourceURL: URL(string: "https://example.com/recording.wav")!),
        ] {
            do { _ = try await service().importMeeting(request); XCTFail("Expected validation failure") } catch {}
        }
        XCTAssertEqual(try repo.count(), 0)
        XCTAssertTrue(try folders().isEmpty)
        XCTAssertEqual(converter.calls, 0)
    }

    func testCorruptAndAudioLessConversionPublishNothing() async throws {
        for failure in [false, true] {
            converter.invalidOutput = !failure
            converter.failure = failure ? TestFailure.failed : nil
            do {
                _ = try await service().importMeeting(.init(sourceURL: source())); XCTFail("Expected media failure")
            } catch {}
            XCTAssertTrue(try folders().isEmpty)
            XCTAssertEqual(try repo.count(), 0)
        }
    }

    func testMediaLeaseContentionWritesNothing() async throws {
        let sourceURL = try source()
        let lease = try MeetingMediaMutationLease.acquire(roots: [root])
        defer { lease.release() }
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        do { _ = try await service().importMeeting(.init(sourceURL: sourceURL)); XCTFail("Expected busy lease") } catch
        { XCTAssertTrue(error is MeetingMediaMutationLease.AcquisitionError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), before)
        XCTAssertEqual(converter.calls, 0)
        XCTAssertEqual(try repo.count(), 0)
    }

    func testStaleCleanupOnlyRemovesExactStagingDirectoriesAndPreservesSelectedSource() async throws {
        let stale = root.appendingPathComponent(".meeting-import-\(UUID().uuidString)")
        let unrelated = root.appendingPathComponent(".meeting-import-not-a-uuid")
        let sourceFolder = root.appendingPathComponent(".meeting-import-\(UUID().uuidString)")
        let link = root.appendingPathComponent(".meeting-import-\(UUID().uuidString)")
        for folder in [stale, unrelated, sourceFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        let selected = sourceFolder.appendingPathComponent("source.wav")
        try Data("external".utf8).write(to: selected)
        _ = try await service().importMeeting(.init(sourceURL: selected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        for preserved in [unrelated, sourceFolder, link, selected] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        }
    }

    func testHardLinkFailureFallsBackToCopyAndDuplicatesUseSeparateIDs() async throws {
        let sourceURL = try source()
        let importer = service(fileManager: LinkFailingFileManager())
        let first = try await importer.importMeeting(.init(sourceURL: sourceURL))
        let second = try await importer.importMeeting(.init(sourceURL: sourceURL))
        XCTAssertNotEqual(first.transcription.id, second.transcription.id)
        XCTAssertNotEqual(first.transcription.filePath, second.transcription.filePath)
        for output in transcriber.recordings {
            XCTAssertEqual(try Data(contentsOf: output.mixedAudioURL), try Data(contentsOf: output.systemAudioURL))
        }
    }

    func testPrePublicationCancellationCleansStagingAndPostPublicationFailurePreservesRecoveryArchive() async throws {
        converter.failure = CancellationError()
        do {
            _ = try await service().importMeeting(.init(sourceURL: source())); XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertTrue(try folders().isEmpty)
        converter.failure = nil
        transcriber.prepareFailure = CancellationError()
        do {
            _ = try await service().importMeeting(.init(sourceURL: source())); XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let publishedFolders = try folders()
        XCTAssertEqual(publishedFolders.count, 1)
        let folder = try XCTUnwrap(publishedFolders.first)
        let lock = try XCTUnwrap(MeetingRecordingLockFileStore().read(folderURL: folder))
        XCTAssertEqual(lock.state, .awaitingTranscription)
        XCTAssertNil(lock.finalizationLeaseId)
        XCTAssertEqual(try repo.count(), 0)
    }

    func testTaskCancellationAfterNormalizationCleansBeforeRowPublication() async throws {
        converter.cancelAfterWrite = true
        let importer = service()
        let input = try source()
        let task = Task { try await importer.importMeeting(.init(sourceURL: input)) }
        do { _ = try await task.value; XCTFail("Expected cooperative cancellation") } catch is CancellationError {}
        XCTAssertTrue(try folders().isEmpty)
        XCTAssertEqual(try repo.count(), 0)
    }

    func testTaskCancellationAtPublishedProgressRetainsRetryableRow() async throws {
        let importer = service()
        let input = try source()
        let task = Task {
            try await importer.importMeeting(.init(sourceURL: input)) { progress in
                if case .published = progress { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = try await task.value
        XCTAssertEqual(result.completion, .needsRetry)
        XCTAssertEqual(result.transcription.status, .cancelled)
        XCTAssertEqual(try repo.count(), 1)
        XCTAssertTrue(transcriber.recordings.isEmpty, "Cancellation stops before STT starts")
        let folder = URL(fileURLWithPath: try XCTUnwrap(result.transcription.meetingArtifactFolderPath))
        XCTAssertNotNil(try MeetingRecordingLockFileStore().read(folderURL: folder))
    }

    func testPreparationOwnsFinalizationAndRootBeforePublishingRow() async throws {
        transcriber.onPrepare = { recording in
            let lock = try XCTUnwrap(MeetingRecordingLockFileStore().read(folderURL: recording.folderURL))
            XCTAssertEqual(lock.state, .awaitingTranscription)
            XCTAssertNotNil(lock.finalizationLeaseId)
            XCTAssertTrue(FileManager.default.fileExists(atPath: recording.mixedAudioURL.path))
            XCTAssertThrowsError(
                try MeetingMediaMutationLease.acquire(roots: [recording.folderURL.deletingLastPathComponent()]))
        }
        _ = try await service().importMeeting(.init(sourceURL: source()))
    }

    func testSTTPreflightErrorAndCancellationLeaveOneRetryableRowAndLock() async throws {
        for failure: Error in [TestFailure.failed, CancellationError()] {
            transcriber.failure = failure
            let result = try await service().importMeeting(.init(sourceURL: source()))
            XCTAssertEqual(result.completion, .needsRetry)
            XCTAssertEqual(result.transcription.status, failure is CancellationError ? .cancelled : .error)
            XCTAssertFalse(result.warnings.isEmpty)
            let folder = try XCTUnwrap(transcriber.recordings.last?.folderURL)
            XCTAssertNotNil(try MeetingRecordingLockFileStore().read(folderURL: folder))
            XCTAssertEqual(try repo.fetch(id: result.transcription.id)?.status, result.transcription.status)
        }
        XCTAssertEqual(try repo.count(), 2)
    }

    func testErrorAfterSavingCompletedRowNeverDowngradesTranscript() async throws {
        transcriber.failure = TestFailure.failed
        transcriber.completeBeforeFailure = true
        let result = try await service().importMeeting(.init(sourceURL: source()))
        XCTAssertEqual(result.transcription.status, .completed)
        XCTAssertEqual(result.completion, .partial)
        XCTAssertNil(try MeetingRecordingLockFileStore().read(folderURL: transcriber.recordings[0].folderURL))
    }

    func testAutomationFailureCancellationAndWarningsPreserveCompletedTranscript() async throws {
        for completion in [
            ImportCompletion(failure: TestFailure.failed),
            ImportCompletion(failure: CancellationError()),
            ImportCompletion(
                result: .init(outcomes: [
                    .init(promptId: nil, promptName: "Summary", status: .failed(message: "provider"))
                ])),
            ImportCompletion(
                result: .init(warnings: [
                    .knowledgeCardFailed(message: "card"), .artifactRefreshFailed(message: "artifact"),
                ])),
        ] {
            let result = try await service(completion: completion).importMeeting(.init(sourceURL: source()))
            XCTAssertEqual(result.transcription.status, .completed)
            XCTAssertEqual(result.completion, .partial)
            XCTAssertFalse(result.warnings.isEmpty)
        }
    }

    func testSettlementFailureReturnsPartialAndRetainsLock() async throws {
        let result = try await service(lockStore: DeleteFailingLockStore()).importMeeting(.init(sourceURL: source()))
        XCTAssertEqual(result.completion, .partial)
        XCTAssertEqual(result.transcription.status, .completed)
        XCTAssertNotNil(try MeetingRecordingLockFileStore().read(folderURL: transcriber.recordings[0].folderURL))
    }

    func testDeleteImmediatelyRetentionDetachesManagedAudioAfterCompletion() async throws {
        let result = try await service(retentionConfig: { .deleteImmediately })
            .importMeeting(.init(sourceURL: source()))

        XCTAssertEqual(result.completion, .completed)
        XCTAssertNil(result.transcription.filePath)
        let folder = URL(fileURLWithPath: try XCTUnwrap(result.transcription.meetingArtifactFolderPath))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(MeetingArtifactAudioFileNames.playback).path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(MeetingArtifactAudioFileNames.rawSystem).path))
    }

    func testDeleteImmediatelyRetentionFailureReturnsDurablePartialResult() async throws {
        let result = try await service(
            fileManager: RemovalFailingFileManager(), retentionConfig: { .deleteImmediately }
        ).importMeeting(.init(sourceURL: source()))

        XCTAssertEqual(result.completion, .partial)
        XCTAssertEqual(result.transcription.status, .completed)
        XCTAssertTrue(
            result.warnings.contains { warning in
                if case .audioRetentionFailed = warning { return true }
                return false
            }
        )
        XCTAssertEqual(try repo.fetch(id: result.transcription.id)?.status, .completed)
    }
}

private enum TestFailure: Error { case failed }

private final class ImportConverter: AudioFileConverting, @unchecked Sendable {
    var calls = 0
    var failure: Error?
    var invalidOutput = false
    var cancelAfterWrite = false
    func convert(fileURL: URL) async throws -> URL { fileURL }
    func mixToM4A(inputURLs: [URL], outputURL: URL, sourceAlignment: MeetingSourceAlignment?) async throws {
        calls += 1
        if let failure { throw failure }
        if invalidOutput { try Data("corrupt".utf8).write(to: outputURL); return }
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        for index in 0..<16000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.1) * 0.2) }
        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        if cancelAfterWrite { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

private final class ImportTranscriber: MeetingImportAudioTranscribing, @unchecked Sendable {
    let repo: TranscriptionRepositoryProtocol
    var recordings: [MeetingRecordingOutput] = []
    var prepareFailure: Error?
    var onPrepare: (@Sendable (MeetingRecordingOutput) throws -> Void)?
    var failure: Error?
    var completeBeforeFailure = false
    init(repo: TranscriptionRepositoryProtocol) { self.repo = repo }
    func prepareMeetingTranscription(recording: MeetingRecordingOutput) async throws -> Transcription {
        if let prepareFailure { throw prepareFailure }
        try onPrepare?(recording)
        let row = Transcription(
            id: recording.sessionID, createdAt: recording.startedAt!, fileName: recording.displayName,
            filePath: recording.mixedAudioURL.path, meetingArtifactFolderPath: recording.folderURL.path,
            status: .processing, sourceType: .meeting,
            titleOverride: recording.titleOverride, audioRetentionStartedAt: recording.audioRetentionStartedAt)
        try repo.save(row)
        return row
    }
    func finalizeMeetingTranscription(
        recording: MeetingRecordingOutput, updating transcriptionID: UUID,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        recordings.append(recording)
        if !completeBeforeFailure, let failure { throw failure }
        var row = try XCTUnwrap(repo.fetch(id: transcriptionID))
        row.status = .completed
        row.cleanTranscript = "Imported transcript"
        try repo.save(row)
        if let failure { throw failure }
        return row
    }
}

private struct ImportCompletion: SavedAudioAutoPromptCompletionServicing {
    var failure: Error?
    var result = SavedAudioAutoPromptCompletionResult()
    func completeAutoPrompts(
        for transcription: Transcription,
        onProgress: (@Sendable (SavedAudioAutoPromptCompletionProgress) -> Void)?
    ) async throws -> SavedAudioAutoPromptCompletionResult {
        if let failure { throw failure }
        return result
    }
}

private final class LinkFailingFileManager: FileManager {
    override func linkItem(at srcURL: URL, to dstURL: URL) throws { throw TestFailure.failed }
}

private final class RemovalFailingFileManager: FileManager {
    override func removeItem(at URL: URL) throws { throw TestFailure.failed }
}

private struct DeleteFailingLockStore: MeetingRecordingLockFileStoring, MeetingFinalizationOwnershipClaiming {
    let base = MeetingRecordingLockFileStore()
    func write(_ file: MeetingRecordingLockFile, folderURL: URL) throws { try base.write(file, folderURL: folderURL) }
    func read(folderURL: URL) throws -> MeetingRecordingLockFile? { try base.read(folderURL: folderURL) }
    func delete(folderURL: URL) throws { throw TestFailure.failed }
    func discoverOrphans(meetingsRoot: URL) throws -> [MeetingRecordingLockFile] {
        try base.discoverOrphans(meetingsRoot: meetingsRoot)
    }
    func claimFinalizationOwnership(folderURL: URL) throws -> MeetingFinalizationOwnershipLease {
        try base.claimFinalizationOwnership(folderURL: folderURL)
    }
    func releaseFinalizationOwnership(_ lease: MeetingFinalizationOwnershipLease) throws {
        try base.releaseFinalizationOwnership(lease)
    }
}
