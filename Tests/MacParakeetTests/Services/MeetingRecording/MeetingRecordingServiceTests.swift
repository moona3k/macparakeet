import AVFAudio
import Foundation
import XCTest
@testable import MacParakeetCore

final class MeetingRecordingServiceTests: XCTestCase {
    func testStartRecordingWritesLockFileBeforeCaptureStarts() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let lockStore = RecordingLockFileStore()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: lockStore
        )

        try await service.startRecording()

        XCTAssertEqual(lockStore.writes.count, 1)
        let startCallCount = await captureService.startCallCount
        XCTAssertEqual(startCallCount, 1)
        XCTAssertEqual(lockStore.writes.first?.file.displayName.isEmpty, false)

        await service.cancelRecording()
    }

    func testStartRecordingCleansUpWhenLockWriteFails() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let lockStore = RecordingLockFileStore()
        lockStore.errorToThrow = TestError.lockWriteFailed
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: lockStore
        )

        do {
            try await service.startRecording()
            XCTFail("Expected lock write failure")
        } catch {
            let startCallCount = await captureService.startCallCount
            XCTAssertEqual(startCallCount, 0)
            let folderURL = try XCTUnwrap(lockStore.writeAttempts.first?.folderURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
        }

        lockStore.errorToThrow = nil
        try await service.startRecording()
        await service.cancelRecording()
    }

    func testCancelDuringAsyncStartMakesInFlightStartThrow() async throws {
        let captureService = BlockingStartMeetingAudioCaptureService()
        let lockStore = RecordingLockFileStore()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: lockStore
        )

        let startTask = Task {
            try await service.startRecording()
        }
        await captureService.waitForStartCall()

        await service.cancelRecording()
        let isRecordingAfterCancel = await service.isRecording
        XCTAssertFalse(isRecordingAfterCancel)

        await captureService.releaseStart()
        do {
            try await startTask.value
            XCTFail("startRecording() must not report success after its session was cancelled")
        } catch is CancellationError {
            // Expected.
        }

        let isRecordingAfterStartReturned = await service.isRecording
        let stopCallCount = await captureService.stopCallCount
        XCTAssertFalse(isRecordingAfterStartReturned)
        XCTAssertEqual(stopCallCount, 2)
        XCTAssertGreaterThanOrEqual(lockStore.deletes.count, 1)
    }

    func testStartWhileCanceledAsyncStartIsUnwindingThrowsAlreadyRunning() async throws {
        let captureService = BlockingStartMeetingAudioCaptureService()
        let lockStore = RecordingLockFileStore()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: lockStore
        )

        let firstStartTask = Task {
            try await service.startRecording()
        }
        await captureService.waitForStartCall()

        await service.cancelRecording()

        do {
            try await service.startRecording()
            XCTFail("Expected replacement start to be rejected while stale async start is unwinding")
        } catch let error as MeetingAudioError {
            guard case .alreadyRunning = error else {
                return XCTFail("Expected alreadyRunning, got \(error)")
            }
        }

        let startCallCountBeforeRelease = await captureService.startCallCount
        XCTAssertEqual(startCallCountBeforeRelease, 1)

        await captureService.releaseStart()
        do {
            try await firstStartTask.value
            XCTFail("startRecording() must not report success after cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let secondStartTask = Task {
            try await service.startRecording()
        }
        await captureService.waitForStartCall(count: 2)
        await captureService.releaseStart()
        try await secondStartTask.value

        let startCallCountAfterRetry = await captureService.startCallCount
        XCTAssertEqual(startCallCountAfterRetry, 2)
        await service.cancelRecording()
    }

    func testCancelDuringAsyncEventsSetupPreventsCaptureStart() async throws {
        let captureService = BlockingEventsMeetingAudioCaptureService()
        let lockStore = RecordingLockFileStore()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: lockStore
        )

        let startTask = Task {
            try await service.startRecording()
        }
        await captureService.waitForEventsCall()

        await service.cancelRecording()
        let isRecordingAfterCancel = await service.isRecording
        XCTAssertFalse(isRecordingAfterCancel)

        await captureService.releaseEvents()
        do {
            try await startTask.value
            XCTFail("startRecording() must not continue into capture start after cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let startCallCount = await captureService.startCallCount
        let stopCallCount = await captureService.stopCallCount
        XCTAssertEqual(startCallCount, 0)
        XCTAssertGreaterThanOrEqual(stopCallCount, 1)
        XCTAssertGreaterThanOrEqual(lockStore.deletes.count, 1)
    }

    func testTaskCancellationDuringAsyncEventsSetupReleasesLeaseAndState() async throws {
        let captureService = BlockingEventsMeetingAudioCaptureService()
        let lockStore = RecordingLockFileStore()
        let sttClient = LeasingMeetingSTTClient(
            selection: SpeechEngineSelection(engine: .whisper, language: "KO")
        )
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: sttClient,
            lockFileStore: lockStore
        )

        let startTask = Task {
            try await service.startRecording()
        }
        await captureService.waitForEventsCall()

        startTask.cancel()
        await captureService.releaseEvents()

        do {
            try await startTask.value
            XCTFail("startRecording() must not report success after task cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let isRecordingAfterCancellation = await service.isRecording
        let activeLeaseCount = await sttClient.activeLeaseCount
        let startCallCount = await captureService.startCallCount
        XCTAssertFalse(isRecordingAfterCancellation)
        XCTAssertEqual(activeLeaseCount, 0)
        XCTAssertEqual(startCallCount, 0)
        XCTAssertGreaterThanOrEqual(lockStore.deletes.count, 1)
    }

    func testStopRecordingKeepsLockUntilTranscriptionCompletes() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let lockStore = RecordingLockFileStore()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: lockStore
        )

        try await service.startRecording()
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        XCTAssertTrue(lockStore.deletes.isEmpty)
        XCTAssertEqual(lockStore.writes.last?.file.state, .awaitingTranscription)

        await service.completeTranscription(for: output)
        XCTAssertEqual(lockStore.deletes, [output.folderURL])
    }

    func testRecordingCapturesSpeechEngineSelectionAtStart() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let lockStore = RecordingLockFileStore()
        let speechEngine = SpeechEngineSelection(engine: .whisper, language: "KO")
        let sttClient = LeasingMeetingSTTClient(selection: speechEngine)
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: sttClient,
            lockFileStore: lockStore
        )

        try await service.startRecording()
        let activeLeaseCountAfterStart = await sttClient.activeLeaseCount
        XCTAssertEqual(activeLeaseCountAfterStart, 1)
        XCTAssertEqual(lockStore.writes.first?.file.speechEngine, SpeechEngineSelection(engine: .whisper, language: "ko"))

        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        let metadata = try MeetingRecordingMetadataStore.load(from: output.folderURL)
        XCTAssertEqual(output.speechEngine, SpeechEngineSelection(engine: .whisper, language: "ko"))
        XCTAssertEqual(metadata.speechEngine, SpeechEngineSelection(engine: .whisper, language: "ko"))
        XCTAssertEqual(lockStore.writes.last?.file.speechEngine, SpeechEngineSelection(engine: .whisper, language: "ko"))
        let activeLeaseCountAfterStop = await sttClient.activeLeaseCount
        XCTAssertEqual(activeLeaseCountAfterStop, 1)

        await service.completeTranscription(for: output)
        let activeLeaseCountAfterCompletion = await sttClient.activeLeaseCount
        XCTAssertEqual(activeLeaseCountAfterCompletion, 0)
    }

    func testFailedTranscriptionAttemptReleasesRetainedSpeechEngineLeaseWithoutDeletingLock() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let lockStore = RecordingLockFileStore()
        let speechEngine = SpeechEngineSelection(engine: .whisper, language: "KO")
        let sttClient = LeasingMeetingSTTClient(selection: speechEngine)
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: sttClient,
            lockFileStore: lockStore
        )

        try await service.startRecording()
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        let activeLeaseCountAfterStop = await sttClient.activeLeaseCount
        XCTAssertEqual(activeLeaseCountAfterStop, 1)

        await service.finishTranscriptionAttempt(for: output)
        let activeLeaseCountAfterFailure = await sttClient.activeLeaseCount
        XCTAssertEqual(activeLeaseCountAfterFailure, 0)
        XCTAssertTrue(lockStore.deletes.isEmpty)
    }

    func testLivePreviewUsesCapturedSpeechEngineSelection() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let speechEngine = SpeechEngineSelection(engine: .whisper, language: "KO")
        let sttClient = LeasingMeetingSTTClient(selection: speechEngine)
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        try await waitForRoutedLiveChunkSelection(sttClient)

        let routedSelections = await sttClient.routedSelections
        XCTAssertEqual(routedSelections, [SpeechEngineSelection(engine: .whisper, language: "ko")])

        let output = try await service.stopRecording()
        try? FileManager.default.removeItem(at: output.folderURL)
    }

    /// PR #395's mechanism: the injected `isVadLiveChunkingEnabled` closure is
    /// consulted in `configureLiveChunkers`. The sibling tests all exercise the
    /// default `{ false }` path (→ `feature_disabled` → fixed chunker); this is
    /// the one test that proves `{ true }` flips the first guard. It asserts
    /// only the durable invariant — the decision is NOT `feature_disabled` —
    /// because the downstream reason (`non_parakeet_engine` / `vad_unavailable`
    /// / `mode=vad reason=started`) depends on the session engine and whether
    /// the Silero model happens to be cached on the machine. The full
    /// VAD-chunker install path is covered by
    /// `SpeechBoundaryMeetingLiveAudioChunkerTests`.
    func testRecordingWithVadEnabledConsultsInjectedFlag() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            isVadLiveChunkingEnabled: { true }
        )

        try await service.startRecording()
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 16_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        let log = try String(contentsOf: AudioCaptureDiagnostics.diagnosticLogURL(), encoding: .utf8)
        let modeLine = try XCTUnwrap(
            log.split(whereSeparator: \.isNewline)
                .last { $0.contains("meeting_live_chunking_mode session=\(output.sessionID.uuidString)") },
            "expected a chunking-mode decision logged for this session"
        )
        XCTAssertFalse(
            modeLine.contains("reason=feature_disabled"),
            "flag-on recording must consult the injected closure, not short-circuit on feature_disabled"
        )
    }

    func testStopRecordingReturnsOutputAndKeepsLockWhenMixFails() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let lockStore = RecordingLockFileStore()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: ThrowingMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: lockStore
        )

        try await service.startRecording()
        let writtenFolder = try XCTUnwrap(lockStore.writes.first?.folderURL)
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: writtenFolder) }

        XCTAssertEqual(output.folderURL, writtenFolder)
        XCTAssertNotNil(output.sourceAlignment.microphone)
        XCTAssertNil(output.sourceAlignment.system)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.mixedAudioURL.path))
        XCTAssertTrue(lockStore.deletes.isEmpty)
        XCTAssertEqual(lockStore.writes.last?.file.state, .awaitingTranscription)
    }

    func testStopRecordingWritesPrivacySafeCaptureHealthSummary() async throws {
        let captureService = MockMeetingAudioCaptureService(
            startReport: MeetingAudioCaptureStartReport(
                sourceMode: .microphoneAndSystem,
                microphone: MeetingMicrophoneCaptureStartReport(
                    requestedMode: .raw,
                    effectiveMode: .raw
                )
            )
        )
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient()
        )

        try await service.startRecording()
        for offset in 0..<5 {
            let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 16_000, sampleValue: 0.25))
            let systemBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 16_000, sampleValue: 0.25))
            let time = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0 + Double(offset)))
            await captureService.yield(.microphoneBuffer(microphoneBuffer, time))
            await captureService.yield(.systemBuffer(systemBuffer, time))
        }

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        let log = try String(contentsOf: AudioCaptureDiagnostics.diagnosticLogURL(), encoding: .utf8)
        XCTAssertTrue(log.contains("meeting_recording_health session=\(output.sessionID.uuidString)"))
        XCTAssertTrue(log.contains("source_mode=microphone_and_system"))
        XCTAssertTrue(log.contains("mic_started=true"))
        XCTAssertTrue(log.contains("requested_mic_mode=raw"))
        XCTAssertTrue(log.contains("effective_mic_mode=raw"))
        XCTAssertTrue(log.contains("mic_first_buffer=true"))
        XCTAssertTrue(log.contains("system_first_buffer=true"))
        XCTAssertTrue(log.contains("mic_bytes="))
        XCTAssertTrue(log.contains("system_bytes="))
        XCTAssertTrue(log.contains("mixed_bytes="))
        XCTAssertTrue(log.contains("mic_frames="))
        XCTAssertTrue(log.contains("system_frames="))
        XCTAssertTrue(log.contains("mic_chunks_enqueued="))
        XCTAssertTrue(log.contains("system_chunks_enqueued="))
        XCTAssertTrue(log.contains("mic_chunks_low_signal_dropped=0"))
        XCTAssertTrue(log.contains("system_chunks_low_signal_dropped=0"))
        XCTAssertTrue(log.contains("interrupted_sources=none"))
        XCTAssertTrue(log.contains("capture_failed=false"))
        XCTAssertTrue(log.contains("meeting_echo_suppression_summary session=\(output.sessionID.uuidString)"))
        XCTAssertTrue(log.contains("processor=passthrough"))
        XCTAssertTrue(log.contains("loaded=true"))
    }

    func testCancelRecordingDeletesLockAndSessionFolder() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let lockStore = RecordingLockFileStore()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: lockStore
        )

        try await service.startRecording()
        let folderURL = try XCTUnwrap(lockStore.writes.first?.folderURL)

        await service.cancelRecording()

        XCTAssertEqual(lockStore.deletes, [folderURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
    }

    func testStopRecordingThrowsNoAudioCapturedWhenRecordedFilesHaveNoFrames() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = CountingMeetingSTTClient()
        let lockStore = RecordingLockFileStore()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient,
            lockFileStore: lockStore
        )

        try await service.startRecording()
        let folderURL = try XCTUnwrap(lockStore.writes.first?.folderURL)

        do {
            _ = try await service.stopRecording()
            XCTFail("Expected stopRecording to throw noAudioCaptured")
        } catch let error as MeetingAudioError {
            guard case .noAudioCaptured = error else {
                XCTFail("Expected noAudioCaptured, got \(error.localizedDescription)")
                return
            }
        }
        XCTAssertEqual(lockStore.deletes, [folderURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
    }

    func testRuntimeCaptureErrorTransitionsCaptureModeToStopped() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = CountingMeetingSTTClient()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()
        await captureService.yield(.error(.captureRuntimeFailure("simulated runtime failure")))
        try await Task.sleep(for: .milliseconds(50))

        let mode = await service.captureMode
        XCTAssertEqual(mode, .stopped)

        await service.cancelRecording()
    }

    func testSystemSourceInterruptionKeepsMicrophoneRecordingAlive() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = CountingMeetingSTTClient()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let firstSystemHostTime = AVAudioTime.hostTime(forSeconds: 100.0)
        let systemBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.5))
        await captureService.yield(.systemBuffer(
            systemBuffer,
            AVAudioTime(hostTime: firstSystemHostTime)
        ))
        try await waitForSystemLevel(service) { $0 > 0 }

        await captureService.yield(.sourceInterrupted(
            source: .system,
            error: .captureRuntimeFailure("system audio stream stopped: Failed to find any displays or windows to capture")
        ))
        try await waitForSystemLevel(service) { $0 == 0 }

        let modeAfterSystemInterruption = await service.captureMode
        let stopCallCountBeforeManualStop = await captureService.stopCallCount
        XCTAssertEqual(modeAfterSystemInterruption, .full)
        XCTAssertEqual(stopCallCountBeforeManualStop, 0)

        let lateSystemBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.75))
        await captureService.yield(.systemBuffer(
            lateSystemBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 102.0))
        ))

        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 101.0))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        XCTAssertNotNil(output.sourceAlignment.microphone)
        XCTAssertNotNil(output.sourceAlignment.system)
        XCTAssertEqual(output.sourceAlignment.system?.lastHostTime, firstSystemHostTime)
    }

    func testStopRecordingPreservesCrossStreamHostTimeOffsetsInSourceAlignment() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = SequencedMeetingSTTClient(results: [
            STTResult(text: "mic", words: [
                TimestampedWord(word: "mic", startMs: 0, endMs: 120, confidence: 0.9),
            ]),
            STTResult(text: "sys", words: [
                TimestampedWord(word: "sys", startMs: 0, endMs: 120, confidence: 0.9),
            ]),
            STTResult(text: "", words: []),
            STTResult(text: "", words: []),
        ])
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        let systemBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.5))

        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        await captureService.yield(.systemBuffer(
            systemBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.150))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        let microphone = try XCTUnwrap(output.sourceAlignment.microphone)
        let system = try XCTUnwrap(output.sourceAlignment.system)
        XCTAssertLessThanOrEqual(abs(microphone.startOffsetMs - 0), 10)
        XCTAssertLessThanOrEqual(abs(system.startOffsetMs - 150), 20)
        XCTAssertGreaterThan(microphone.writtenFrameCount, 0)
        XCTAssertGreaterThan(system.writtenFrameCount, 0)

        let metadataURL = MeetingRecordingMetadataStore.metadataURL(for: output.folderURL)
        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(MeetingRecordingMetadata.self, from: metadataData)
        XCTAssertEqual(metadata.sourceAlignment, output.sourceAlignment)
    }

    func testStopRecordingCancelsPendingLiveChunksInsteadOfWaitingForThem() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = SleepingMeetingSTTClient(liveChunkDelay: .seconds(1))
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        try await waitForLiveChunkTranscriptionStart(sttClient)

        let startedAt = ContinuousClock.now
        let output = try await service.stopRecording()
        let elapsed = startedAt.duration(to: .now)
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        XCTAssertLessThan(elapsed, .milliseconds(500))
        XCTAssertNotNil(output.sourceAlignment.microphone)
    }

    func testStopRecordingKeepsSourceAlignmentWhenPendingChunksTimeOut() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = PrefixScriptedMeetingSTTClient(
            microphoneSteps: [
                .result(
                    STTResult(text: "mic", words: [
                        TimestampedWord(word: "mic", startMs: 0, endMs: 120, confidence: 0.9),
                    ])
                ),
            ],
            systemSteps: [
                .result(
                    STTResult(text: "sys", words: [
                        TimestampedWord(word: "sys", startMs: 0, endMs: 120, confidence: 0.9),
                    ]),
                    delay: .seconds(1)
                ),
            ]
        )
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        let systemBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.5))

        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        await captureService.yield(.systemBuffer(
            systemBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.150))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        XCTAssertNotNil(output.sourceAlignment.microphone)
        XCTAssertNotNil(output.sourceAlignment.system)
    }

    func testBackpressureDropMarksNextTranscriptUpdateAsLagging() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = PrefixScriptedMeetingSTTClient(
            microphoneSteps: [
                .result(
                    STTResult(text: "first", words: [
                        TimestampedWord(word: "first", startMs: 0, endMs: 120, confidence: 0.9),
                    ]),
                    delay: .milliseconds(600)
                ),
                .dropBackpressure,
            ]
        )
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        let updates = await service.transcriptUpdates
        let nextUpdate = Task {
            var iterator = updates.makeAsyncIterator()
            return await iterator.next()
        }

        try await service.startRecording()

        let firstBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        let secondBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 64_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            firstBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        await captureService.yield(.microphoneBuffer(
            secondBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 104.0))
        ))

        let maybeUpdate = await nextUpdate.value
        let update = try XCTUnwrap(maybeUpdate)
        XCTAssertTrue(update.isTranscriptionLagging)
        XCTAssertEqual(update.words.map(\.word), ["first"])

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }
        XCTAssertNotNil(output.sourceAlignment.microphone)
    }

    func testStaleChunkFailureFromPreviousSessionDoesNotPoisonNextSession() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = PathScriptedMeetingSTTClient(responses: [
            "microphone-100000-105000": .failure(message: "late failure", delay: .milliseconds(300)),
            "microphone-200000-205000": .result(STTResult(text: "fresh", words: [
                TimestampedWord(word: "fresh", startMs: 0, endMs: 160, confidence: 0.9),
            ])),
        ])
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let firstBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            firstBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        let firstOutput = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: firstOutput.folderURL) }
        XCTAssertNotNil(firstOutput.sourceAlignment.microphone)

        try await service.startRecording()

        let secondBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.5))
        await captureService.yield(.microphoneBuffer(
            secondBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 200.0))
        ))
        try await Task.sleep(for: .milliseconds(350))

        let secondOutput = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: secondOutput.folderURL) }

        let microphone = try XCTUnwrap(secondOutput.sourceAlignment.microphone)
        XCTAssertGreaterThan(microphone.writtenFrameCount, 0)
    }

    func testSuppressesMicrophoneChunksWhenRecentSystemAudioDominates() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = CountingMeetingSTTClient()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let systemBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.6))
        let micBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.005))
        await captureService.yield(.systemBuffer(
            systemBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        await captureService.yield(.microphoneBuffer(
            micBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.1))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        let counts = await sttClient.callCounts
        XCTAssertEqual(counts.microphone, 0)
        XCTAssertGreaterThanOrEqual(counts.system, 1)
    }

    func testKeepsMicrophoneChunksWhenSystemAudioIsNotDominant() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = CountingMeetingSTTClient()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let systemBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.5))
        let micBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.systemBuffer(
            systemBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        await captureService.yield(.microphoneBuffer(
            micBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.1))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        let counts = await sttClient.callCounts
        XCTAssertGreaterThanOrEqual(counts.microphone, 1)
    }

    func testKeepsMicrophoneChunksWhenNoSystemAudioPresent() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = CountingMeetingSTTClient()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let micBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            micBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        let counts = await sttClient.callCounts
        XCTAssertGreaterThanOrEqual(counts.microphone, 1)
        XCTAssertEqual(counts.system, 0)
    }

    func testLivePreviewUsesConditionedMicrophoneSamplesForSignalGate() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = CountingMeetingSTTClient()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient,
            micConditionerFactory: {
                ZeroingMicConditioner()
            }
        )

        try await service.startRecording()

        let micBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            micBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        let counts = await sttClient.callCounts
        XCTAssertEqual(
            counts.microphone,
            0,
            "live mic STT should see conditioned mic samples; the zeroed cleaned stream must be dropped as low signal"
        )
        XCTAssertNotNil(output.sourceAlignment.microphone, "raw mic source audio should still be retained")
    }

    func testStopRecordingWritesEchoSuppressionDiagnosticsForInjectedConditioner() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            micConditionerFactory: {
                ZeroingMicConditioner()
            }
        )

        try await service.startRecording()
        let micBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            micBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        let log = try String(contentsOf: AudioCaptureDiagnostics.diagnosticLogURL(), encoding: .utf8)
        XCTAssertTrue(log.contains("meeting_echo_suppression_summary session=\(output.sessionID.uuidString)"))
        XCTAssertTrue(log.contains("processor=zeroing-test"))
        XCTAssertTrue(log.contains("processed_frames=1"))
        XCTAssertTrue(log.contains("missing_reference_frames=1"))
    }

    func testSystemOnlyCaptureProducesSystemSourceOnly() async throws {
        let captureService = MockMeetingAudioCaptureService(
            startReport: MeetingAudioCaptureStartReport(sourceMode: .systemOnly)
        )
        let audioConverter = RecordingMeetingAudioFileConverter()
        let sttClient = CountingMeetingSTTClient()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording(sourceMode: .systemOnly)

        let systemBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.5))
        await captureService.yield(.systemBuffer(
            systemBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        try await waitForMeetingSTTCall(sttClient) { $0.system >= 1 }

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        XCTAssertNil(output.sourceAlignment.microphone)
        XCTAssertNotNil(output.sourceAlignment.system)
        XCTAssertEqual(audioConverter.capturedMixedInputs(), [output.systemAudioURL])

        let requestedSourceModes = await captureService.requestedSourceModes
        XCTAssertEqual(requestedSourceModes, [.systemOnly])
        let counts = await sttClient.callCounts
        XCTAssertEqual(counts.microphone, 0)
        XCTAssertGreaterThanOrEqual(counts.system, 1)
    }

    func testStopRecordingMixesDualSourcesInMicrophoneThenSystemOrder() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = RecordingMeetingAudioFileConverter()
        let sttClient = CountingMeetingSTTClient()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 4_096, sampleValue: 0.2))
        let systemBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 4_096, sampleValue: 0.3))

        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        await captureService.yield(.systemBuffer(
            systemBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        XCTAssertEqual(
            audioConverter.capturedMixedInputs(),
            [output.microphoneAudioURL, output.systemAudioURL]
        )
        XCTAssertEqual(audioConverter.capturedSourceAlignment(), output.sourceAlignment)
    }

    func testAsymmetricSourceCadenceDoesNotInflateSystemChunkTimeline() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = ChunkRangeRecordingMeetingSTTClient()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording()

        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        for index in 0..<500 {
            let systemBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 160, sampleValue: 0.25))
            await captureService.yield(.systemBuffer(
                systemBuffer,
                AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0 + (Double(index) * 0.01)))
            ))
        }

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        let ranges = await sttClient.rangesBySource
        let microphoneRange = try XCTUnwrap(ranges[.microphone])
        let systemRange = try XCTUnwrap(ranges[.system])
        let microphoneSpanMs = microphoneRange.maxEndMs - microphoneRange.minStartMs
        let systemSpanMs = systemRange.maxEndMs - systemRange.minStartMs

        XCTAssertGreaterThan(microphoneSpanMs, 0)
        XCTAssertGreaterThan(systemSpanMs, 0)
        XCTAssertLessThanOrEqual(abs(microphoneSpanMs - systemSpanMs), 1_000)
    }

    func testStartRecordingUsesProvidedTitleAsDisplayName() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = CountingMeetingSTTClient()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        try await service.startRecording(title: "  Q1 Roadmap Standup  ")
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        // Trim is intentional — calendar event titles often have stray
        // whitespace and the user shouldn't see it surface in their library.
        XCTAssertEqual(output.displayName, "Q1 Roadmap Standup")
    }

    func testStartRecordingFallsBackToDateBasedDisplayNameWhenTitleIsBlank() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = CountingMeetingSTTClient()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient
        )

        // Whitespace-only title should not pollute the recording name —
        // we want the same default a manual recording gets.
        try await service.startRecording(title: "   \n  ")
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        XCTAssertTrue(output.displayName.hasPrefix("Meeting "),
                      "Expected date-based fallback, got \(output.displayName)")
    }

    private func waitForLiveChunkTranscriptionStart(
        _ client: SleepingMeetingSTTClient,
        timeout: Duration = .seconds(1)
    ) async throws {
        let startedAt = ContinuousClock.now
        while await client.liveChunkCallCount == 0 {
            if startedAt.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for live chunk transcription to start")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForRoutedLiveChunkSelection(
        _ client: LeasingMeetingSTTClient,
        timeout: Duration = .seconds(1)
    ) async throws {
        let startedAt = ContinuousClock.now
        while await client.routedSelections.isEmpty {
            if startedAt.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for routed live chunk transcription")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForMeetingSTTCall(
        _ client: CountingMeetingSTTClient,
        timeout: Duration = .seconds(1),
        _ predicate: @escaping ((microphone: Int, system: Int)) -> Bool
    ) async throws {
        let startedAt = ContinuousClock.now
        while !predicate(await client.callCounts) {
            if startedAt.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for meeting STT call")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForSystemLevel(
        _ service: MeetingRecordingService,
        timeout: Duration = .seconds(1),
        _ predicate: @escaping (Float) -> Bool
    ) async throws {
        let startedAt = ContinuousClock.now
        while !predicate(await service.systemLevel) {
            if startedAt.duration(to: .now) > timeout {
                XCTFail("Timed out waiting for system level predicate")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeMonoFloatBuffer(frameCount: Int, sampleValue: Float) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channelData = buffer.floatChannelData else { return nil }
        for index in 0..<frameCount {
            channelData[0][index] = sampleValue
        }
        return buffer
    }

    // MARK: - ADR-020 §8 — updateNotes

    func testUpdateNotesPersistsNotesIntoLockFileWithoutChangingState() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let lockStore = RecordingLockFileStore()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: lockStore
        )

        try await service.startRecording()
        let writeBeforeUpdate = try XCTUnwrap(lockStore.writes.last)
        XCTAssertEqual(writeBeforeUpdate.file.state, .recording)
        XCTAssertNil(writeBeforeUpdate.file.notes)

        await service.updateNotes("first jot")

        let writeAfterUpdate = try XCTUnwrap(lockStore.writes.last)
        XCTAssertEqual(writeAfterUpdate.file.notes, "first jot")
        // The state must be preserved — that's the load-bearing reason all
        // lock-file writes route through this single actor (ADR-020 §8).
        XCTAssertEqual(writeAfterUpdate.file.state, .recording)

        await service.cancelRecording()
    }

    func testUpdateNotesWithEmptyOrWhitespaceStoresNil() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let lockStore = RecordingLockFileStore()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: lockStore
        )

        try await service.startRecording()
        await service.updateNotes("typed something")
        XCTAssertEqual(lockStore.writes.last?.file.notes, "typed something")

        await service.updateNotes("   \n  ")
        XCTAssertNil(lockStore.writes.last?.file.notes, "whitespace-only notes must normalize to nil")

        await service.updateNotes("")
        XCTAssertNil(lockStore.writes.last?.file.notes, "empty notes must normalize to nil")

        await service.cancelRecording()
    }

    func testUpdateNotesIsNoOpWhenNotRecording() async throws {
        let lockStore = RecordingLockFileStore()
        let service = MeetingRecordingService(
            audioCaptureService: MockMeetingAudioCaptureService(),
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: lockStore
        )

        await service.updateNotes("type without recording")

        XCTAssertTrue(lockStore.writes.isEmpty, "no recording → no lock-file writes")
    }

    func testStopRecordingCarriesNotesIntoOutput() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let lockStore = RecordingLockFileStore()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: lockStore
        )

        try await service.startRecording()
        await service.updateNotes("notes from the meeting")
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        XCTAssertEqual(output.userNotes, "notes from the meeting")
        // Final lock-file write at finalize keeps the notes around so a crash
        // between finalize and Transcription save still recovers them.
        XCTAssertEqual(lockStore.writes.last?.file.notes, "notes from the meeting")
        XCTAssertEqual(lockStore.writes.last?.file.state, .awaitingTranscription)

        // notes.md is written to the meeting folder on finalize so the user
        // can read what they typed in Finder / any editor without launching
        // the app. Snapshot only — not synced with later DB edits.
        let notesURL = MeetingNotesFile.fileURL(for: output.folderURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: notesURL.path))
        let notesContent = try String(contentsOf: notesURL, encoding: .utf8)
        XCTAssertTrue(notesContent.contains("notes from the meeting"))

        await service.completeTranscription(for: output)
    }

    func testStopRecordingDoesNotWriteNotesFileWhenNoNotesTaken() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        // No updateNotes call — user attended without typing.
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        XCTAssertNil(output.userNotes)
        let notesURL = MeetingNotesFile.fileURL(for: output.folderURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: notesURL.path),
            "Empty-notes meeting should not produce a notes.md file"
        )

        await service.completeTranscription(for: output)
    }

    // MARK: - Pause / Resume (issue #235)

    func testPauseRecordingSetsCaptureModeToPausedAndZeroesLevels() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        defer {
            Task { await service.cancelRecording() }
        }

        // Push a buffer so levels are non-zero pre-pause.
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.5))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 1.0))
        ))
        // Yield so the actor processes the buffer before pause.
        try await Task.sleep(for: .milliseconds(20))

        await service.pauseRecording()

        let captureMode = await service.captureMode
        let isPaused = await service.isPaused
        let micLevel = await service.micLevel
        let systemLevel = await service.systemLevel
        XCTAssertEqual(captureMode, .paused)
        XCTAssertTrue(isPaused)
        XCTAssertEqual(micLevel, 0)
        XCTAssertEqual(systemLevel, 0)
    }

    func testResumeRecordingClearsPausedStateAndCaptureModeReturnsToFull() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        defer {
            Task { await service.cancelRecording() }
        }

        await service.pauseRecording()
        await service.resumeRecording()

        let captureMode = await service.captureMode
        let isPaused = await service.isPaused
        XCTAssertEqual(captureMode, .full)
        XCTAssertFalse(isPaused)
    }

    func testMicrophoneMuteWritesSilenceAndKeepsSystemAudioLive() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let audioConverter = MockMeetingAudioFileConverter()
        let sttClient = CountingMeetingSTTClient()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: audioConverter,
            sttTranscriber: sttClient,
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        let muteState = await service.setMicrophoneMuted(true)
        XCTAssertEqual(muteState, MeetingMicrophoneMuteState(isMuted: true, canMute: true))

        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.5))
        let systemBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.5))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: ProcessInfo.processInfo.systemUptime + 0.1))
        ))
        await captureService.yield(.systemBuffer(
            systemBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: ProcessInfo.processInfo.systemUptime + 0.1))
        ))
        // The level is set asynchronously when the actor drains a yielded buffer,
        // and it's a stored value with no decay — once non-zero it stays so. Poll
        // (up to 2s) for the system level instead of a fixed sleep: the old 80ms
        // sleep raced the yield→process pipeline under parallel CI load and
        // intermittently read 0. The poll still fails if the level never rises,
        // so it can't mask a real regression.
        var systemLevel = await service.systemLevel
        let levelDeadline = Date().addingTimeInterval(2)
        while systemLevel == 0, Date() < levelDeadline {
            try await Task.sleep(for: .milliseconds(10))
            systemLevel = await service.systemLevel
        }

        let micLevel = await service.micLevel
        XCTAssertEqual(micLevel, 0)
        XCTAssertGreaterThan(systemLevel, 0)

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        XCTAssertGreaterThan(output.sourceAlignment.microphone?.writtenFrameCount ?? 0, 0)
        XCTAssertGreaterThan(output.sourceAlignment.system?.writtenFrameCount ?? 0, 0)
        let counts = await sttClient.callCounts
        XCTAssertEqual(counts.microphone, 0)
        XCTAssertGreaterThanOrEqual(counts.system, 1)

        await service.completeTranscription(for: output)
    }

    func testMicrophoneMutePreservesQueuedPreMuteAudioByHostTime() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let sttClient = CountingMeetingSTTClient()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: sttClient,
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        let preMuteHostTime = AVAudioTime.hostTime(
            forSeconds: max(0, ProcessInfo.processInfo.systemUptime - 1)
        )
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: preMuteHostTime)
        ))

        await service.setMicrophoneMuted(true)

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        XCTAssertEqual(output.sourceAlignment.microphone?.firstHostTime, preMuteHostTime)
        let counts = await sttClient.callCounts
        XCTAssertGreaterThanOrEqual(counts.microphone, 1)

        await service.completeTranscription(for: output)
    }

    func testMicrophoneMuteUnmuteAllowsLaterMicAudio() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let sttClient = CountingMeetingSTTClient()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: sttClient,
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        await service.setMicrophoneMuted(true)

        let mutedBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.5))
        await captureService.yield(.microphoneBuffer(
            mutedBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: ProcessInfo.processInfo.systemUptime + 0.1))
        ))
        try await Task.sleep(for: .milliseconds(20))

        await service.setMicrophoneMuted(false)

        let unmutedBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            unmutedBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: ProcessInfo.processInfo.systemUptime + 0.3))
        ))
        try await Task.sleep(for: .milliseconds(80))

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        let counts = await sttClient.callCounts
        XCTAssertGreaterThanOrEqual(counts.microphone, 1)

        await service.completeTranscription(for: output)
    }

    func testMicrophoneMuteIsUnavailableForSystemOnlyRecordings() async throws {
        let captureService = MockMeetingAudioCaptureService(
            startReport: MeetingAudioCaptureStartReport(sourceMode: .systemOnly)
        )
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording(sourceMode: .systemOnly)
        defer {
            Task { await service.cancelRecording() }
        }

        let canMute = await service.canMuteMicrophone
        XCTAssertFalse(canMute)
        let muteState = await service.setMicrophoneMuted(true)
        XCTAssertEqual(muteState, MeetingMicrophoneMuteState(isMuted: false, canMute: false))
        let isMuted = await service.isMicrophoneMuted
        XCTAssertFalse(isMuted)
    }

    func testMicrophoneMuteStateClearsAfterCaptureFailure() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        let mutedState = await service.setMicrophoneMuted(true)
        XCTAssertEqual(mutedState, MeetingMicrophoneMuteState(isMuted: true, canMute: true))

        await captureService.yield(.error(.captureRuntimeFailure("simulated runtime failure")))
        try await Task.sleep(for: .milliseconds(50))

        let failedState = await service.microphoneMuteState
        XCTAssertEqual(failedState, MeetingMicrophoneMuteState(isMuted: false, canMute: false))
        let setStateAfterFailure = await service.setMicrophoneMuted(false)
        XCTAssertEqual(setStateAfterFailure, MeetingMicrophoneMuteState(isMuted: false, canMute: false))

        await service.cancelRecording()
    }

    func testPauseAndResumeAreNoOpsWhenNotRecording() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: RecordingLockFileStore()
        )

        // No active session — both calls must be safe no-ops.
        await service.pauseRecording()
        await service.resumeRecording()

        let isRecording = await service.isRecording
        let isPaused = await service.isPaused
        let captureMode = await service.captureMode
        XCTAssertFalse(isRecording)
        XCTAssertFalse(isPaused)
        XCTAssertEqual(captureMode, .stopped)
    }

    func testRedundantPauseAndResumeAreIdempotent() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        defer {
            Task { await service.cancelRecording() }
        }

        await service.pauseRecording()
        await service.pauseRecording() // redundant — must not double-account
        let pausedAfterDoublePause = await service.isPaused
        XCTAssertTrue(pausedAfterDoublePause)

        await service.resumeRecording()
        await service.resumeRecording() // redundant — must not flip back to paused
        let pausedAfterDoubleResume = await service.isPaused
        XCTAssertFalse(pausedAfterDoubleResume)
    }

    func testStopRecordingDurationExcludesPausedTime() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        // Yield so the actor's processingTask drains the buffer to disk
        // before pause flips the discard flag. Without this, the buffer can
        // sit in the events mailbox behind the pause call and stop fails
        // with `noAudioCaptured` on a clean session folder.
        try await Task.sleep(for: .milliseconds(50))

        // Hold the recording in pause for 1s so the accumulated paused
        // duration is comfortably measurable even under heavy CI load.
        // The previous 500ms / 0.3s-slack combo flaked on GitHub macOS
        // runners because the pre-pause buffer yield + actor mailbox
        // drain can spike to ~220ms (only ~50-100ms locally) — that left
        // negative margin against a wallclock of ~510ms minus 300ms slack.
        // Doubling the pause and the slack keeps the proof strength
        // ("at least 600ms of pause was carved out") while leaving 400ms
        // of headroom for scheduler/actor jitter.
        let startedAt = Date()
        await service.pauseRecording()
        try await Task.sleep(for: .milliseconds(1000))
        await service.resumeRecording()

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }
        let stoppedAt = Date()
        let totalWallclock = stoppedAt.timeIntervalSince(startedAt)

        XCTAssertLessThan(
            output.durationSeconds,
            totalWallclock,
            "Paused interval must be subtracted from the persisted duration"
        )
        // The pause was 1000ms — assert at least 600ms was carved out
        // (60% of the pause window), still proving subtraction happened
        // while leaving CI-friendly headroom for pre-pause overhead.
        XCTAssertLessThan(
            output.durationSeconds,
            totalWallclock - 0.6
        )

        await service.completeTranscription(for: output)
    }

    func testImmediatePauseKeepsAlreadyCapturedAudio() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        let prePauseHostTime = AVAudioTime.hostTime(
            forSeconds: max(0, ProcessInfo.processInfo.systemUptime - 1)
        )
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: prePauseHostTime)
        ))

        await service.pauseRecording()

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        XCTAssertNotNil(output.sourceAlignment.microphone)
        XCTAssertEqual(output.sourceAlignment.microphone?.firstHostTime, prePauseHostTime)

        await service.completeTranscription(for: output)
    }

    func testStopRecordingDrainsQueuedTailBuffers() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.25))
        let baseSeconds = max(0, ProcessInfo.processInfo.systemUptime - 1)
        var lastHostTime: UInt64 = 0
        for index in 0..<24 {
            lastHostTime = AVAudioTime.hostTime(forSeconds: baseSeconds + (Double(index) * 0.01))
            await captureService.yield(.microphoneBuffer(
                microphoneBuffer,
                AVAudioTime(hostTime: lastHostTime)
            ))
        }

        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }

        XCTAssertEqual(output.sourceAlignment.microphone?.lastHostTime, lastHostTime)

        await service.completeTranscription(for: output)
    }

    func testStopRecordingWhilePausedSettlesOngoingPauseIntoDuration() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 80_000, sampleValue: 0.25))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 100.0))
        ))
        // Same actor-mailbox ordering caveat as the resume sibling test.
        try await Task.sleep(for: .milliseconds(50))

        let startedAt = Date()
        await service.pauseRecording()
        try await Task.sleep(for: .milliseconds(1000))
        // Stop without resuming — the in-flight pause must still be
        // subtracted from the persisted duration. Pause is held 1s with
        // 0.6s of carved-out slack — same CI-resilience math as the
        // resume-sibling test above (see comment there for the rationale
        // behind doubling from the original 500ms / 0.3s budget).
        let output = try await service.stopRecording()
        defer { try? FileManager.default.removeItem(at: output.folderURL) }
        let stoppedAt = Date()
        let totalWallclock = stoppedAt.timeIntervalSince(startedAt)

        XCTAssertLessThan(
            output.durationSeconds,
            totalWallclock - 0.6,
            "Stopping while paused must still subtract the in-flight pause interval"
        )

        await service.completeTranscription(for: output)
    }

    func testBuffersDuringPauseAreDiscardedAndDoNotProduceTranscriptUpdates() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        defer {
            Task { await service.cancelRecording() }
        }

        await service.pauseRecording()

        // Push a non-trivial buffer while paused — service must drop it
        // without updating levels and without forwarding to the chunker.
        let microphoneBuffer = try XCTUnwrap(makeMonoFloatBuffer(frameCount: 4_800, sampleValue: 0.6))
        await captureService.yield(.microphoneBuffer(
            microphoneBuffer,
            AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 2.0))
        ))
        // Give the actor a chance to process the buffer.
        try await Task.sleep(for: .milliseconds(50))

        let micLevel = await service.micLevel
        XCTAssertEqual(micLevel, 0, "Pause must zero levels and discard incoming mic buffers")
    }

    func testCancelWhilePausedClearsAllPauseStateAndRecordingState() async throws {
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        await service.pauseRecording()
        let pausedBeforeCancel = await service.isPaused
        XCTAssertTrue(pausedBeforeCancel)

        await service.cancelRecording()

        let isPaused = await service.isPaused
        let isRecording = await service.isRecording
        let captureMode = await service.captureMode
        XCTAssertFalse(isPaused, "cancelRecording must clear paused via cleanupState")
        XCTAssertFalse(isRecording)
        XCTAssertEqual(captureMode, .stopped)
    }

    func testRapidPauseResumeStormSettlesInLastUserIntent() async throws {
        // Codex test-coverage agent flagged this as missing. Alternating
        // pause/resume rapidly should not double-count `accumulatedPausedDuration`
        // (resumeRecording's `guard … paused` clause is the safety net),
        // and the final state must match the last call.
        let captureService = MockMeetingAudioCaptureService()
        let service = MeetingRecordingService(
            audioCaptureService: captureService,
            audioConverter: MockMeetingAudioFileConverter(),
            sttTranscriber: CountingMeetingSTTClient(),
            lockFileStore: RecordingLockFileStore()
        )

        try await service.startRecording()
        defer {
            Task { await service.cancelRecording() }
        }

        // Ten alternating toggles, last is `resume` so we expect isPaused=false.
        for _ in 0..<5 {
            await service.pauseRecording()
            await service.resumeRecording()
        }

        let isPaused = await service.isPaused
        let captureMode = await service.captureMode
        XCTAssertFalse(isPaused)
        XCTAssertEqual(captureMode, .full)
    }

    func testLiveTranscriptDoesNotDieAfterPauseResume() async throws {
        // Direct assembler test that defends the captureOrchestrator-reset
        // bug fix (Codex audio P0 + my fresh-eye review). Before the fix,
        // pauseRecording called captureOrchestrator.reset() which zeroed
        // AudioChunker.totalSamplesProcessed; post-resume chunks emitted at
        // startMs near 0; MeetingTranscriptAssembler.apply dedupe filter
        // (`endMs > cutoff`) silently dropped every post-resume word.
        //
        // We simulate the assembler's own flow: pre-pause chunk @ 5s commits
        // `lastCommittedEndMs = 5500`. After pause/resume, the chunker
        // should NOT reset, so the next chunk emits at startMs=10s (not 0).
        // Assembler must accept those words.
        var assembler = MeetingTranscriptAssembler()

        let prePauseChunk = AudioChunker.AudioChunk(samples: [], startMs: 5000, endMs: 10_000)
        let prePauseResult = STTResult(
            text: "before pause",
            words: [
                TimestampedWord(word: "before", startMs: 0, endMs: 200, confidence: 0.9),
                TimestampedWord(word: "pause", startMs: 250, endMs: 500, confidence: 0.9),
            ]
        )
        let prePauseUpdate = assembler.apply(result: prePauseResult, chunk: prePauseChunk, source: .microphone)
        XCTAssertEqual(prePauseUpdate.words.count, 2)

        // After fix: chunker NOT reset on pause, so post-resume chunks
        // continue at higher startMs. Simulate post-resume chunk @ 10s.
        let postResumeChunk = AudioChunker.AudioChunk(samples: [], startMs: 10_000, endMs: 15_000)
        let postResumeResult = STTResult(
            text: "after resume",
            words: [
                TimestampedWord(word: "after", startMs: 0, endMs: 200, confidence: 0.9),
                TimestampedWord(word: "resume", startMs: 250, endMs: 500, confidence: 0.9),
            ]
        )
        let postResumeUpdate = assembler.apply(result: postResumeResult, chunk: postResumeChunk, source: .microphone)
        XCTAssertEqual(
            postResumeUpdate.words.count,
            4,
            "Post-resume words must be retained — regression guard against captureOrchestrator.reset()"
        )
    }
}

private actor BlockingEventsMeetingAudioCaptureService: MeetingAudioCapturing {
    private var continuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
    private var stream: AsyncStream<MeetingAudioCaptureEvent>?
    private var eventsWaiters: [CheckedContinuation<Void, Never>] = []
    private var eventsGate: CheckedContinuation<Void, Never>?
    private(set) var eventsCallCount = 0
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    var events: AsyncStream<MeetingAudioCaptureEvent> {
        get async {
            eventsCallCount += 1
            let waiters = eventsWaiters
            eventsWaiters.removeAll()
            waiters.forEach { $0.resume() }

            await withCheckedContinuation { continuation in
                eventsGate = continuation
            }

            if let stream {
                return stream
            }

            let stream = AsyncStream<MeetingAudioCaptureEvent>(bufferingPolicy: .unbounded) {
                self.continuation = $0
            }
            self.stream = stream
            return stream
        }
    }

    func start(sourceMode: MeetingAudioSourceMode?) async throws -> MeetingAudioCaptureStartReport {
        startCallCount += 1
        return MeetingAudioCaptureStartReport(
            microphone: MeetingMicrophoneCaptureStartReport(
                requestedMode: .vpioPreferred,
                effectiveMode: .vpio
            )
        )
    }

    func stop() async {
        stopCallCount += 1
        continuation?.finish()
        continuation = nil
        stream = nil
    }

    func waitForEventsCall() async {
        guard eventsCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            eventsWaiters.append(continuation)
        }
    }

    func releaseEvents() {
        eventsGate?.resume()
        eventsGate = nil
    }
}

private actor MockMeetingAudioCaptureService: MeetingAudioCapturing {
    private var continuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
    private var stream: AsyncStream<MeetingAudioCaptureEvent>?
    private let startReport: MeetingAudioCaptureStartReport
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var requestedSourceModes: [MeetingAudioSourceMode?] = []

    init(
        startReport: MeetingAudioCaptureStartReport = MeetingAudioCaptureStartReport(
            microphone: MeetingMicrophoneCaptureStartReport(
                requestedMode: .vpioPreferred,
                effectiveMode: .vpio
            )
        )
    ) {
        self.startReport = startReport
    }

    var events: AsyncStream<MeetingAudioCaptureEvent> {
        if let stream {
            return stream
        }

        let stream = AsyncStream<MeetingAudioCaptureEvent>(bufferingPolicy: .unbounded) {
            self.continuation = $0
        }
        self.stream = stream
        return stream
    }

    func start(sourceMode: MeetingAudioSourceMode?) async throws -> MeetingAudioCaptureStartReport {
        startCallCount += 1
        requestedSourceModes.append(sourceMode)
        _ = events
        return startReport
    }

    func stop() async {
        stopCallCount += 1
        continuation?.finish()
        continuation = nil
        stream = nil
    }

    func yield(_ event: MeetingAudioCaptureEvent) {
        continuation?.yield(event)
    }
}

private actor BlockingStartMeetingAudioCaptureService: MeetingAudioCapturing {
    private var continuation: AsyncStream<MeetingAudioCaptureEvent>.Continuation?
    private var stream: AsyncStream<MeetingAudioCaptureEvent>?
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var startGate: CheckedContinuation<Void, Never>?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    var events: AsyncStream<MeetingAudioCaptureEvent> {
        if let stream {
            return stream
        }

        let stream = AsyncStream<MeetingAudioCaptureEvent>(bufferingPolicy: .unbounded) {
            self.continuation = $0
        }
        self.stream = stream
        return stream
    }

    func start(sourceMode: MeetingAudioSourceMode?) async throws -> MeetingAudioCaptureStartReport {
        startCallCount += 1
        resumeSatisfiedStartWaiters()

        await withCheckedContinuation { continuation in
            startGate = continuation
        }
        return MeetingAudioCaptureStartReport(
            microphone: MeetingMicrophoneCaptureStartReport(
                requestedMode: .vpioPreferred,
                effectiveMode: .vpio
            )
        )
    }

    func stop() async {
        stopCallCount += 1
        continuation?.finish()
        continuation = nil
        stream = nil
    }

    func waitForStartCall(count: Int = 1) async {
        guard startCallCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func releaseStart() {
        startGate?.resume()
        startGate = nil
    }

    private func resumeSatisfiedStartWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in startWaiters {
            if startCallCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        startWaiters = remaining
    }
}

private enum TestError: Error {
    case lockWriteFailed
}

private final class RecordingLockFileStore: MeetingRecordingLockFileStoring, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var writes: [(file: MeetingRecordingLockFile, folderURL: URL)] = []
    private(set) var writeAttempts: [(file: MeetingRecordingLockFile, folderURL: URL)] = []
    private(set) var deletes: [URL] = []
    var errorToThrow: Error?

    func write(_ file: MeetingRecordingLockFile, folderURL: URL) throws {
        if let errorToThrow {
            lock.withLock {
                writeAttempts.append((file, folderURL))
            }
            throw errorToThrow
        }
        lock.withLock {
            writeAttempts.append((file, folderURL))
            writes.append((file, folderURL))
        }
    }

    func read(folderURL: URL) throws -> MeetingRecordingLockFile? {
        lock.withLock {
            writes.first { $0.folderURL == folderURL }?.file
        }
    }

    func delete(folderURL: URL) throws {
        lock.withLock {
            deletes.append(folderURL)
        }
    }

    func discoverOrphans(meetingsRoot: URL) throws -> [MeetingRecordingLockFile] {
        []
    }
}

private final class MockMeetingAudioFileConverter: AudioFileConverting, @unchecked Sendable {
    func convert(fileURL: URL) async throws -> URL {
        fileURL
    }

    func mixToM4A(
        inputURLs: [URL],
        outputURL: URL,
        sourceAlignment: MeetingSourceAlignment?
    ) async throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: Data("mixed".utf8))
    }
}

private final class ThrowingMeetingAudioFileConverter: AudioFileConverting, @unchecked Sendable {
    func convert(fileURL: URL) async throws -> URL {
        fileURL
    }

    func mixToM4A(
        inputURLs: [URL],
        outputURL: URL,
        sourceAlignment: MeetingSourceAlignment?
    ) async throws {
        throw MeetingAudioError.mixFailed("simulated")
    }
}

private final class RecordingMeetingAudioFileConverter: AudioFileConverting, @unchecked Sendable {
    private let lock = NSLock()
    private var mixedInputs: [URL] = []
    private var mixedSourceAlignment: MeetingSourceAlignment?

    func convert(fileURL: URL) async throws -> URL {
        fileURL
    }

    func mixToM4A(
        inputURLs: [URL],
        outputURL: URL,
        sourceAlignment: MeetingSourceAlignment?
    ) async throws {
        lock.withLock {
            mixedInputs = inputURLs
            mixedSourceAlignment = sourceAlignment
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: Data("mixed".utf8))
    }

    func capturedMixedInputs() -> [URL] {
        lock.withLock { mixedInputs }
    }

    func capturedSourceAlignment() -> MeetingSourceAlignment? {
        lock.withLock { mixedSourceAlignment }
    }
}

private actor SequencedMeetingSTTClient: STTClientProtocol {
    private var remainingResults: [STTResult]

    init(results: [STTResult]) {
        self.remainingResults = results
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        guard !remainingResults.isEmpty else {
            XCTFail("Unexpected extra meeting STT request")
            return STTResult(text: "", words: [])
        }
        return remainingResults.removeFirst()
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {}

    func backgroundWarmUp() async {}

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        return (UUID(), stream)
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool { true }

    func clearModelCache() async {}

    func shutdown() async {}
}

private actor SleepingMeetingSTTClient: STTClientProtocol {
    private let liveChunkDelay: Duration
    private(set) var liveChunkCallCount = 0

    init(liveChunkDelay: Duration) {
        self.liveChunkDelay = liveChunkDelay
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        if job == .meetingLiveChunk {
            liveChunkCallCount += 1
            try await Task.sleep(for: liveChunkDelay)
        }
        return STTResult(text: "", words: [])
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {}

    func backgroundWarmUp() async {}

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        return (UUID(), stream)
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool { true }

    func clearModelCache() async {}

    func shutdown() async {}
}

private actor PrefixScriptedMeetingSTTClient: STTClientProtocol {
    enum Step: Sendable {
        case result(STTResult, delay: Duration = .zero)
        case dropBackpressure
    }

    private var microphoneSteps: [Step]
    private var systemSteps: [Step]

    init(
        microphoneSteps: [Step] = [],
        systemSteps: [Step] = []
    ) {
        self.microphoneSteps = microphoneSteps
        self.systemSteps = systemSteps
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        let fileName = URL(fileURLWithPath: audioPath).lastPathComponent
        let step: Step
        if fileName.hasPrefix("microphone-"), !microphoneSteps.isEmpty {
            step = microphoneSteps.removeFirst()
        } else if fileName.hasPrefix("system-"), !systemSteps.isEmpty {
            step = systemSteps.removeFirst()
        } else {
            step = .result(STTResult(text: "", words: []))
        }

        switch step {
        case .result(let result, let delay):
            if delay > .zero {
                try await Task.sleep(for: delay)
            }
            return result
        case .dropBackpressure:
            throw STTSchedulerError.droppedDueToBackpressure(job: .meetingLiveChunk)
        }
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {}

    func backgroundWarmUp() async {}

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        return (UUID(), stream)
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool { true }

    func clearModelCache() async {}

    func shutdown() async {}
}

private actor PathScriptedMeetingSTTClient: STTClientProtocol {
    enum Response {
        case result(STTResult, delay: Duration = .zero)
        case failure(message: String, delay: Duration = .zero)
    }

    private let responses: [String: Response]

    init(responses: [String: Response]) {
        self.responses = responses
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        guard let response = responses.first(where: { audioPath.contains($0.key) })?.value else {
            return STTResult(text: "", words: [])
        }

        switch response {
        case .result(let result, let delay):
            await waitIgnoringCancellation(for: delay)
            return result
        case .failure(let message, let delay):
            await waitIgnoringCancellation(for: delay)
            throw STTError.transcriptionFailed(message)
        }
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {}

    func backgroundWarmUp() async {}

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        return (UUID(), stream)
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool { true }

    func clearModelCache() async {}

    func shutdown() async {}

    private func waitIgnoringCancellation(for delay: Duration) async {
        guard delay > .zero else { return }
        let startedAt = ContinuousClock.now
        while startedAt.duration(to: .now) < delay {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor CountingMeetingSTTClient: STTClientProtocol {
    private(set) var callCounts: (microphone: Int, system: Int) = (0, 0)

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        let fileName = URL(fileURLWithPath: audioPath).lastPathComponent
        if fileName.hasPrefix("microphone-") {
            callCounts.microphone += 1
        } else if fileName.hasPrefix("system-") {
            callCounts.system += 1
        }
        return STTResult(text: "", words: [])
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {}

    func backgroundWarmUp() async {}

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        return (UUID(), stream)
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool { true }

    func clearModelCache() async {}

    func shutdown() async {}
}

private final class ZeroingMicConditioner: MicConditioning, @unchecked Sendable {
    private(set) var diagnostics = MeetingEchoSuppressionDiagnostics(
        processorName: "zeroing-test",
        loaded: true,
        micFrames: 0,
        processedFrames: 0,
        rawFallbackFrames: 0,
        fullReferenceFrames: 0,
        partialReferenceFrames: 0,
        missingReferenceFrames: 0,
        processingFailures: 0
    )

    func condition(microphone: [Float], speaker: [Float], hasSpeakerReference: Bool) -> [Float] {
        diagnostics.micFrames += 1
        diagnostics.processedFrames += 1
        if hasSpeakerReference {
            diagnostics.fullReferenceFrames += 1
        } else {
            diagnostics.missingReferenceFrames += 1
        }
        return [Float](repeating: 0, count: microphone.count)
    }

    func reset() {
        diagnostics = MeetingEchoSuppressionDiagnostics(
            processorName: "zeroing-test",
            loaded: true,
            micFrames: 0,
            processedFrames: 0,
            rawFallbackFrames: 0,
            fullReferenceFrames: 0,
            partialReferenceFrames: 0,
            missingReferenceFrames: 0,
            processingFailures: 0
        )
    }
}

private actor LeasingMeetingSTTClient: STTClientProtocol, SpeechEngineRoutedTranscribing, SpeechEngineSessionManaging {
    private let selection: SpeechEngineSelection
    private var activeLeases: Set<UUID> = []
    private(set) var routedSelections: [SpeechEngineSelection] = []

    init(selection: SpeechEngineSelection) {
        self.selection = selection
    }

    var activeLeaseCount: Int {
        activeLeases.count
    }

    func beginSpeechEngineSession() async -> SpeechEngineLease {
        let lease = SpeechEngineLease(selection: selection)
        activeLeases.insert(lease.id)
        return lease
    }

    func endSpeechEngineSession(_ lease: SpeechEngineLease) async {
        activeLeases.remove(lease.id)
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        STTResult(text: "", words: [])
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        speechEngine: SpeechEngineSelection,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        if job == .meetingLiveChunk {
            routedSelections.append(speechEngine)
        }
        return STTResult(text: "", words: [])
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {}

    func backgroundWarmUp() async {}

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        return (UUID(), stream)
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool { true }

    func clearModelCache() async {}

    func shutdown() async {}
}

private actor ChunkRangeRecordingMeetingSTTClient: STTClientProtocol {
    struct ChunkRange: Sendable {
        var minStartMs: Int
        var maxEndMs: Int
    }

    private(set) var rangesBySource: [AudioSource: ChunkRange] = [:]

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        let fileName = URL(fileURLWithPath: audioPath).lastPathComponent
        let stem = fileName.replacingOccurrences(of: ".wav", with: "")
        let parts = stem.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let startMs = Int(parts[1]),
              let endMs = Int(parts[2]) else {
            return STTResult(text: "", words: [])
        }

        let source: AudioSource?
        if parts[0] == "microphone" {
            source = .microphone
        } else if parts[0] == "system" {
            source = .system
        } else {
            source = nil
        }

        if let source {
            if let existing = rangesBySource[source] {
                rangesBySource[source] = ChunkRange(
                    minStartMs: min(existing.minStartMs, startMs),
                    maxEndMs: max(existing.maxEndMs, endMs)
                )
            } else {
                rangesBySource[source] = ChunkRange(minStartMs: startMs, maxEndMs: endMs)
            }
        }

        return STTResult(text: "", words: [])
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {}

    func backgroundWarmUp() async {}

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        return (UUID(), stream)
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool { true }

    func clearModelCache() async {}

    func shutdown() async {}
}
