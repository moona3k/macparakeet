import AVFoundation
import Darwin
import XCTest
@testable import MacParakeetCore

final class MeetingRecordingCrashRecoveryTests: XCTestCase {
    private static let helperFolderEnv = "MACPARAKEET_CRASH_RECOVERY_HELPER_FOLDER"

    func testKillNineMidRecordingProducesPlayableFiles() async throws {
        // Heavy end-to-end check: spawns a child xctest process, lets it write
        // real AVFoundation audio, SIGKILLs it, then asserts the fragmented MP4
        // is still playable. Inherently slow (~5-13s) and environment-sensitive,
        // so it is opt-in. The recovery *logic* (including "use remaining
        // playable audio after a corrupt/truncated source") is covered by the
        // fast, deterministic MeetingRecordingRecoveryServiceTests. Run with:
        //   MACPARAKEET_CRASH_RECOVERY_TESTS=1 swift test
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPARAKEET_CRASH_RECOVERY_TESTS"] == "1",
            "Set MACPARAKEET_CRASH_RECOVERY_TESTS=1 to run the kill-9 crash-recovery integration test."
        )

        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecordingCrashRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "MacParakeetTests.MeetingRecordingCrashRecoveryTests/testCrashHelperWritesMeetingAudioUntilKilled",
            Bundle(for: Self.self).bundleURL.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            Self.helperFolderEnv: folderURL.path
        ]) { _, new in new }

        try process.run()
        try await waitForFileToGrow(folderURL.appendingPathComponent("microphone-raw.m4a"))
        try await Task.sleep(for: .seconds(5))
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()

        let duration = try await audioDuration(folderURL.appendingPathComponent("microphone-raw.m4a"))
        XCTAssertGreaterThanOrEqual(duration, 4.0)
    }

    func testCrashHelperWritesMeetingAudioUntilKilled() async throws {
        guard let folderPath = ProcessInfo.processInfo.environment[Self.helperFolderEnv] else {
            return
        }

        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        let writer = try MeetingAudioStorageWriter(folderURL: folderURL)
        for second in 0..<15 {
            let buffer = try makeSineBuffer(frameCount: 48_000, frequency: 220 + Double(second * 10))
            try writer.write(buffer, source: .microphone)
            try await Task.sleep(for: .seconds(1))
        }
        await finalize(writer)
    }

    private static let journeyRootEnv = "MACPARAKEET_RECOVERY_JOURNEY_ROOT"
    private static let journeyStageEnv = "MACPARAKEET_RECOVERY_JOURNEY_STAGE"
    private static let recoveredText = "The interrupted meeting retained its decision."
    private static let recoveredNotes = "Decision: preserve the local recording."

    func testKilledRecordingRecoversInFreshProcessAndRemainsIdempotent() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACPARAKEET_CRASH_RECOVERY_TESTS"] == "1",
            "Set MACPARAKEET_CRASH_RECOVERY_TESTS=1 to exercise real writer/process recovery."
        )
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("MeetingRecoveryJourney-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try launchJourneyChild(stage: "write", root: root)
        defer { stopJourneyChild(writer) }
        let ready = root.appendingPathComponent("writer-ready")
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !FileManager.default.fileExists(atPath: ready.path) {
            guard writer.isRunning, ContinuousClock.now < deadline else {
                XCTFail("Writer did not become ready: \(try childLog(stage: "write", root: root))")
                throw TestError.childFailed
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let sessionID = try XCTUnwrap(UUID(uuidString: String(contentsOf: ready, encoding: .utf8)))
        let folder = root.appendingPathComponent("state/meeting-recordings/\(sessionID.uuidString)")
        let lockStore = MeetingRecordingLockFileStore()
        let lock = try XCTUnwrap(try lockStore.read(folderURL: folder))
        XCTAssertEqual(lock.pid, writer.processIdentifier)
        XCTAssertEqual(lock.sessionId, sessionID)
        XCTAssertEqual(lock.state, .recording)
        XCTAssertEqual(lock.notes, Self.recoveredNotes)
        // A real live writer must not be offered for recovery before it is killed.
        XCTAssertTrue(try lockStore.discoverOrphans(meetingsRoot: folder.deletingLastPathComponent()).isEmpty)
        let originalLock = try Data(contentsOf: folder.appendingPathComponent(MeetingRecordingLockFile.fileName))
        try originalLock.write(to: root.appendingPathComponent("original-lock.json"))
        XCTAssertEqual(kill(writer.processIdentifier, SIGKILL), 0)
        writer.waitUntilExit()
        XCTAssertEqual(writer.terminationReason, .uncaughtSignal)
        XCTAssertEqual(writer.terminationStatus, SIGKILL)
        let retainedDuration = try await audioDuration(folder.appendingPathComponent("microphone-raw.m4a"))
        XCTAssertGreaterThanOrEqual(retainedDuration, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))

        // Recovery and the repeat attempt each start with empty process-local state.
        for stage in ["recover", "repeat"] {
            let child = try launchJourneyChild(stage: stage, root: root)
            defer { stopJourneyChild(child) }
            let recoveryDeadline = ContinuousClock.now.advanced(by: .seconds(60))
            while child.isRunning && ContinuousClock.now < recoveryDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !child.isRunning else {
                XCTFail("\(stage) timed out: \(try childLog(stage: stage, root: root))")
                throw TestError.childFailed
            }
            XCTAssertEqual(child.terminationReason, .exit)
            let diagnostics = try childLog(stage: stage, root: root)
            XCTAssertEqual(child.terminationStatus, 0, diagnostics)
            let receipt = try JSONDecoder().decode(
                RecoveryJourneyReceipt.self, from: Data(contentsOf: root.appendingPathComponent("\(stage).json")))
            XCTAssertEqual(receipt.sttCalls, stage == "recover" ? 1 : 0)
            let db = try DatabaseManager(path: root.appendingPathComponent("test.sqlite").path)
            let rows = try TranscriptionRepository(dbQueue: db.dbQueue).fetchAll()
            XCTAssertEqual(rows.count, 1)
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row.id, receipt.transcriptionID)
            XCTAssertEqual(row.status, .completed)
            XCTAssertEqual(row.sourceType, .meeting)
            XCTAssertTrue(row.recoveredFromCrash)
            XCTAssertEqual(row.rawTranscript, Self.recoveredText)
            XCTAssertEqual(row.userNotes, Self.recoveredNotes)
            XCTAssertTrue(MeetingArtifactPathAliases.matches(try XCTUnwrap(row.meetingArtifactFolderPath), for: folder))
            XCTAssertTrue(
                MeetingArtifactPathAliases.matches(
                    try XCTUnwrap(row.filePath), for: folder.appendingPathComponent("meeting-playback.m4a")))
            XCTAssertNil(try lockStore.read(folderURL: folder))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.lock").path))
            try await verifyRecoveredArtifacts(folder: folder, transcriptionID: row.id)
        }
        let first = try JSONDecoder().decode(
            RecoveryJourneyReceipt.self, from: Data(contentsOf: root.appendingPathComponent("recover.json")))
        let repeated = try JSONDecoder().decode(
            RecoveryJourneyReceipt.self, from: Data(contentsOf: root.appendingPathComponent("repeat.json")))
        XCTAssertEqual(first.transcriptionID, repeated.transcriptionID)
    }

    /// Selected only in owned subprocesses; no fixture commands enter the public CLI.
    func testRecoveryJourneyChild() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment[Self.journeyRootEnv],
            let stage = ProcessInfo.processInfo.environment[Self.journeyStageEnv]
        else { return }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        XCTAssertEqual(AppPaths.appSupportDir, root.appendingPathComponent("state").path)
        Telemetry.configure(NoOpTelemetryService())
        let db = try DatabaseManager(path: root.appendingPathComponent("test.sqlite").path)
        let repository = TranscriptionRepository(dbQueue: db.dbQueue)
        let stt = RecoveryJourneySTT(text: Self.recoveredText)
        if stage == "write" {
            let capture = RecoveryJourneyCapture()
            let service = MeetingRecordingService(
                audioCaptureService: capture,
                sttTranscriber: stt,
                finalSpeechEngineSelection: { SpeechEngineSelection(engine: .parakeet) },
                isLiveTranscriptionEnabled: { false },
                micConditionerFactory: { PassthroughMicConditioner() }
            )
            try await service.startRecording(title: "Interrupted process meeting", sourceMode: .microphoneOnly)
            await service.updateNotes(Self.recoveredNotes)
            let activeID = await service.activeSessionID
            let sessionID = try XCTUnwrap(activeID)
            let origin = AVAudioTime.hostTime(forSeconds: ProcessInfo.processInfo.systemUptime)
            for index in 0..<600 {
                let buffer = try makeSineBuffer(frameCount: 4_800, frequency: 220)
                await capture.yield(
                    .microphoneBuffer(
                        buffer, AVAudioTime(hostTime: origin + AVAudioTime.hostTime(forSeconds: Double(index) / 10))))
                try await Task.sleep(for: .milliseconds(100))
                if index == 59 {
                    try sessionID.uuidString.write(
                        to: root.appendingPathComponent("writer-ready"), atomically: true, encoding: .utf8)
                }
            }
            XCTFail("Parent must SIGKILL the active writer without calling Stop/finalize")
            await service.cancelRecording()
            return
        }
        XCTAssertTrue(["recover", "repeat"].contains(stage))
        let service = TranscriptionService(
            audioProcessor: AudioProcessor(),
            sttTranscriber: stt,
            transcriptionRepo: repository,
            promptResultRepo: PromptResultRepository(dbQueue: db.dbQueue),
            shouldAutoGenerateMeetingTitles: { false },
            shouldDiarize: { false },
            shouldDiarizeMeetings: { false },
            meetingAutomationHookRunner: nil
        )
        let recovery = MeetingRecordingRecoveryService(
            meetingsRoot: root.appendingPathComponent("state/meeting-recordings"),
            transcriptionService: service,
            transcriptionRepo: repository,
            meetingArtifactStore: MeetingArtifactStore(),
            promptResultRepo: PromptResultRepository(dbQueue: db.dbQueue),
            micConditionerFactory: { PassthroughMicConditioner() }
        )
        let pending = try await recovery.discoverPendingRecoveries()
        let lock: MeetingRecordingLockFile
        if stage == "recover" {
            XCTAssertEqual(pending.count, 1)
            lock = try XCTUnwrap(pending.first)
            XCTAssertEqual(try repository.fetchAll().count, 0)
        } else {
            XCTAssertTrue(pending.isEmpty)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let original = try decoder.decode(
                MeetingRecordingLockFile.self, from: Data(contentsOf: root.appendingPathComponent("original-lock.json"))
            )
            lock = original.withFolderURL(
                root.appendingPathComponent("state/meeting-recordings/\(original.sessionId.uuidString)"))
        }
        let recovered: Transcription
        if stage == "repeat" {
            do {
                _ = try await recovery.recover(lock)
                XCTFail("A settled session no longer has a lock to claim")
            } catch MeetingFinalizationOwnershipError.missingLock {
                // Replaying a settled descriptor is safely refused before any STT or writes.
            }
            recovered = try XCTUnwrap(repository.fetchAll().first)
        } else {
            recovered = try await recovery.recover(lock)
        }
        let remaining = try await recovery.discoverPendingRecoveries()
        XCTAssertTrue(remaining.isEmpty)
        let calls = await stt.callCount
        let receipt = RecoveryJourneyReceipt(transcriptionID: recovered.id, sttCalls: calls)
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("\(stage).json"), options: .atomic)
    }

    private func verifyRecoveredArtifacts(folder: URL, transcriptionID: UUID) async throws {
        let sourceDuration = try await audioDuration(folder.appendingPathComponent("microphone-raw.m4a"))
        XCTAssertGreaterThanOrEqual(sourceDuration, 4)
        let playback = folder.appendingPathComponent("meeting-playback.m4a")
        let playbackDuration = try await audioDuration(playback)
        XCTAssertGreaterThanOrEqual(playbackDuration, 4)
        // Decode samples as well as probing the container duration.
        let file = try AVAudioFile(forReading: playback)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_024))
        try file.read(into: buffer)
        XCTAssertGreaterThan(buffer.frameLength, 0)
        let metadata = try MeetingRecordingMetadataStore.load(from: folder)
        XCTAssertGreaterThan(try XCTUnwrap(metadata.sourceAlignment.microphone?.writtenFrameCount), 0)
        XCTAssertNil(metadata.sourceAlignment.system)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["schema"] as? String, "com.macparakeet.meeting-session")
        XCTAssertEqual((manifest["meeting"] as? [String: Any])?["id"] as? String, transcriptionID.uuidString)
        XCTAssertEqual((manifest["meeting"] as? [String: Any])?["recoveredFromCrash"] as? Bool, true)
        let files = try XCTUnwrap(manifest["files"] as? [String: Any])
        for (key, name) in [
            ("manifestPath", "manifest.json"), ("markdownPath", "meeting.md"),
            ("notesPath", "notes.md"), ("transcriptPath", "transcript.json"),
            ("playbackAudioPath", "meeting-playback.m4a"), ("rawMicrophoneAudioPath", "microphone-raw.m4a"),
        ] {
            XCTAssertTrue(
                MeetingArtifactPathAliases.matches(
                    try XCTUnwrap(files[key] as? String), for: folder.appendingPathComponent(name)), key)
        }
        let markdown = try String(contentsOf: folder.appendingPathComponent("meeting.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains(Self.recoveredText))
        XCTAssertTrue(markdown.contains(Self.recoveredNotes))
        let notes = try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8)
        XCTAssertTrue(notes.contains(Self.recoveredNotes))
        let transcript = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: folder.appendingPathComponent("transcript.json"))) as? [String: Any])
        XCTAssertEqual(transcript["id"] as? String, transcriptionID.uuidString)
        XCTAssertEqual(transcript["transcript"] as? String, Self.recoveredText)
        XCTAssertEqual(transcript["recoveredFromCrash"] as? Bool, true)
    }

    private func launchJourneyChild(stage: String, root: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest",
            "MacParakeetTests.MeetingRecordingCrashRecoveryTests/testRecoveryJourneyChild",
            Bundle(for: Self.self).bundleURL.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            Self.journeyRootEnv: root.path, Self.journeyStageEnv: stage,
            "MACPARAKEET_TELEMETRY": "0", "MACPARAKEET_DEBUG_SQL": "0",
            "MACPARAKEET_DEBUG_APP_STATE_DIR": root.appendingPathComponent("state").path,
        ]) { _, new in new }
        let logURL = root.appendingPathComponent("\(stage).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
        return process
    }

    private func stopJourneyChild(_ process: Process) {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    private func childLog(stage: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent("\(stage).log"), encoding: .utf8)
    }

    private func finalize(_ writer: MeetingAudioStorageWriter) async {
        await withCheckedContinuation { continuation in
            writer.finalize { _ in
                continuation.resume()
            }
        }
    }

    private func waitForFileToGrow(_ url: URL) async throws {
        let startedAt = ContinuousClock.now
        while true {
            if let size = try? fileSize(url), size > 1024 {
                return
            }
            if startedAt.duration(to: .now) > .seconds(8) {
                XCTFail("Timed out waiting for crash helper to write audio")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func audioDuration(_ url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw TestError.missingAudioTrack }
        let duration = try await asset.load(.duration)
        return duration.seconds
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func makeSineBuffer(frameCount: Int, frequency: Double) throws -> AVAudioPCMBuffer {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        else {
            throw TestError.failedToCreateBuffer
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = buffer.floatChannelData![0]
        for index in 0..<frameCount {
            let phase = 2 * Double.pi * frequency * Double(index) / 48_000.0
            samples[index] = Float(sin(phase) * 0.2)
        }
        return buffer
    }

    private enum TestError: Error {
        case childFailed
        case failedToCreateBuffer
        case missingAudioTrack
    }
}

private struct RecoveryJourneyReceipt: Codable {
    let transcriptionID: UUID
    let sttCalls: Int
}

private actor RecoveryJourneyCapture: MeetingAudioCapturing {
    private let stream = AsyncStream<MeetingAudioCaptureEvent>.makeStream()
    var events: AsyncStream<MeetingAudioCaptureEvent> { stream.stream }
    func start(sourceMode: MeetingAudioSourceMode?) async throws -> MeetingAudioCaptureStartReport {
        .init(sourceMode: .microphoneOnly, microphoneState: .ready, systemState: .notSelected)
    }
    func stop() async { stream.continuation.finish() }
    func yield(_ event: MeetingAudioCaptureEvent) { stream.continuation.yield(event) }
}

private actor RecoveryJourneySTT: SpeechEngineRoutedTranscribing, SpeechEngineSessionManaging {
    private let text: String
    private(set) var callCount = 0
    init(text: String) { self.text = text }
    func beginSpeechEngineSession() async -> SpeechEngineLease {
        SpeechEngineLease(
            selection: SpeechEngineSelection(engine: .parakeet),
            capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet))
    }
    func endSpeechEngineSession(_ lease: SpeechEngineLease) async {}
    func transcribe(
        audioPath: String, job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        // The boundary receives actual converted, decodable audio, not an invented path.
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        XCTAssertGreaterThan(audio.length, 0)
        XCTAssertEqual(job, .meetingFinalize)
        callCount += 1
        return STTResult(text: text)
    }
    func transcribe(
        audioPath: String, job: STTJobKind, speechEngine: SpeechEngineSelection,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        try await transcribe(audioPath: audioPath, job: job, onProgress: onProgress)
    }
}
