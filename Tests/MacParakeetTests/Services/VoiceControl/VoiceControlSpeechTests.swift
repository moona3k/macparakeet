import AVFoundation
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels
@testable import MacParakeet

final class VoiceControlSpeechTests: XCTestCase {
    func testDryRunDoesNotAdmitLiveGrammar() {
        XCTAssertFalse(VoiceControlCoordinator.admitsLiveGrammar(dryRun: true))
        XCTAssertTrue(VoiceControlCoordinator.admitsLiveGrammar(dryRun: false))
    }

    func testSilenceNeverCommitsAnUtterance() {
        var endpoint = VoiceControlEndpointer()
        for _ in 0..<1000 {
            XCTAssertEqual(endpoint.consume(Array(repeating: 0, count: 1600)), .none)
        }
    }
    func testRequiresSpeechBeforePauseCommitsAndResets() {
        var endpoint = VoiceControlEndpointer()
        XCTAssertEqual(endpoint.consume(Array(repeating: 0.1, count: 1600)), .none)
        XCTAssertEqual(endpoint.consume(Array(repeating: 0.1, count: 1600)), .began)
        for _ in 0..<8 { XCTAssertEqual(endpoint.consume(Array(repeating: 0, count: 1600)), .none) }
        XCTAssertEqual(endpoint.consume(Array(repeating: 0, count: 1600)), .ended)
        XCTAssertEqual(endpoint.consume(Array(repeating: 0, count: 32_000)), .none)
    }
    func testBriefNoiseDoesNotCountAsSpeechAcrossLongSilence() {
        var endpoint = VoiceControlEndpointer()
        for _ in 0..<10 {
            XCTAssertEqual(endpoint.consume(Array(repeating: 0.1, count: 800)), .none)
            XCTAssertEqual(endpoint.consume(Array(repeating: 0, count: 8000)), .none)
        }
    }
    func testUtteranceHasBoundedLength() {
        var endpoint = VoiceControlEndpointer()
        XCTAssertEqual(endpoint.consume(Array(repeating: 0.1, count: 2400)), .began)
        XCTAssertEqual(endpoint.consume(Array(repeating: 0.1, count: 480_000)), .tooLong)
        XCTAssertEqual(endpoint.consume(Array(repeating: 0, count: 32_000)), .none)
    }
    @MainActor func testOwnershipExcludesCompetingEffectsUntilCleanup() {
        let arbiter = GUIMutationArbiter()
        let transform = arbiter.acquire(.transform)!
        XCTAssertNil(arbiter.acquire(.voiceControl))
        XCTAssertNil(arbiter.acquire(.dictation))
        arbiter.release(transform)
        let voice = arbiter.acquire(.voiceControl)!
        arbiter.release(transform)
        XCTAssertEqual(arbiter.current, voice, "An old cleanup cannot release a newer session")
        XCTAssertNil(arbiter.acquire(.historyPaste))
        arbiter.release(voice)
        XCTAssertNotNil(arbiter.acquire(.dictation))
    }
}

private actor VoiceControlTestAudio: AudioProcessorProtocol {
    let url: URL
    var isRecording = false
    var sink: DictationAudioSampleSink?
    var audioLevel: Float { 0 }
    var recordingDeviceInfo: RecordingDeviceInfo? { nil }
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-speech-test-\(UUID()).wav")
        try Data([1, 2, 3]).write(to: url)
    }
    func convert(fileURL: URL) async throws -> URL { fileURL }
    func startCapture() async throws { isRecording = true }
    func startCapture(sampleSink: DictationAudioSampleSink?) async throws { sink = sampleSink; isRecording = true }
    func emit(_ samples: [Float]) { sink?.onSamples(samples) }
    func stopCapture() async throws -> URL { isRecording = false; return url }
}

private actor VoiceControlTestSTT: STTTranscribing {
    var jobs: [STTJobKind] = []
    var frames: [Int64] = []
    var audioURLs: [URL] = []
    var startExpectations: [XCTestExpectation] = []
    var shouldWait = false
    var waitsOnlyOnce = false
    var waiting: CheckedContinuation<Void, Never>?
    func setWait(onlyOnce: Bool = false) { shouldWait = true; waitsOnlyOnce = onlyOnce }
    func expectStarts(_ expectations: [XCTestExpectation]) { startExpectations = expectations }
    func release() { shouldWait = false; waiting?.resume(); waiting = nil }
    func transcribe(audioPath: String, job: STTJobKind, onProgress: (@Sendable (Int, Int) -> Void)?) async throws
        -> STTResult
    {
        jobs.append(job)
        let audioURL = URL(fileURLWithPath: audioPath)
        audioURLs.append(audioURL)
        frames.append((try? AVAudioFile(forReading: audioURL).length) ?? -1)
        let started = jobs.count <= startExpectations.count ? startExpectations[jobs.count - 1] : nil
        if shouldWait {
            if waitsOnlyOnce { shouldWait = false }
            await withCheckedContinuation {
                waiting = $0
                started?.fulfill()
            }
        } else {
            started?.fulfill()
        }
        return STTResult(text: "type um, DO NOT expand this snippet")
    }
}

extension VoiceControlSpeechTests {
    func testCommitUsesRawFinalDictationLaneAndDeletesOnlyOwnedAudio() async throws {
        let audio = try VoiceControlTestAudio()
        let stt = VoiceControlTestSTT()
        let session = VoiceControlSpeechSession(audio: audio, stt: stt)
        let events = session.events
        let collector = Task<String?, Never> {
            for await event in events {
                if case .transcript(let text, _, _) = event { return text }
                if case .failed = event { return nil }
                if case .stopped = event { return nil }
            }
            return nil
        }
        try await session.begin(handsFree: false)
        await session.commit()
        let text = await collector.value
        XCTAssertEqual(text, "type um, DO NOT expand this snippet")
        let jobs = await stt.jobs
        XCTAssertEqual(jobs, [.dictation])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.url.path))
    }
    func testCancelDeletesCaptureWithoutSubmittingSTT() async throws {
        let audio = try VoiceControlTestAudio()
        let stt = VoiceControlTestSTT()
        let session = VoiceControlSpeechSession(audio: audio, stt: stt)
        try await session.begin(handsFree: false)
        await session.cancel()
        let jobs = await stt.jobs
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.url.path))
    }
}

extension VoiceControlSpeechTests {
    @MainActor func testSpeechCapturePreservesPendingConfirmation() {
        let model = VoiceControlViewModel()
        let action = VoiceControlAction(operation: .press, targetID: "send")
        model.apply(.confirmation(action, "Send this message?"))
        XCTAssertFalse(model.conversation.shouldPauseForSpeech)
        model.phase = .listening
        XCTAssertTrue(model.conversation.takeConfirmation())
        XCTAssertFalse(model.conversation.takeConfirmation(), "Confirmation can only be consumed once")
    }
    @MainActor func testPhysicalStopClearsPendingResponse() {
        let model = VoiceControlViewModel()
        model.apply(.confirmation(VoiceControlAction(operation: .press, targetID: "send"), "Send?"))
        model.conversation.cancel()
        XCTAssertFalse(model.conversation.takeConfirmation())
        XCTAssertTrue(model.conversation.shouldPauseForSpeech)
    }
    @MainActor func testClarificationSurvivesVisibleListeningPhase() {
        let model = VoiceControlViewModel()
        model.apply(.clarification("Which Save button?"))
        model.phase = .listening
        XCTAssertFalse(model.conversation.shouldPauseForSpeech)
        XCTAssertTrue(model.conversation.takeClarification())
        XCTAssertTrue(model.conversation.shouldPauseForSpeech)
    }
}

extension VoiceControlSpeechTests {
    func testStopDiscardsLateAuthoritativeResultEvenIfSTTIgnoresCancellation() async throws {
        let audio = try VoiceControlTestAudio()
        let stt = VoiceControlTestSTT()
        await stt.setWait()
        let session = VoiceControlSpeechSession(audio: audio, stt: stt)
        let events = session.events
        let collector = Task<Bool, Never> {
            for await event in events {
                if case .transcript = event { return true }
                if case .stopped = event { return false }
            }
            return false
        }
        try await session.begin(handsFree: false)
        let commit = Task { await session.commit() }
        for _ in 0..<10_000 {
            if await stt.waiting != nil { break }
            await Task.yield()
        }
        let didStart = await stt.waiting != nil
        XCTAssertTrue(didStart)
        await session.discardPendingUtterance()
        await stt.release()
        await commit.value
        let emitted = await collector.value
        XCTAssertFalse(emitted, "A final arriving after Stop must never become another command")
    }
    func testHandsFreeFinishDoesNotReplayPriorCommandsFromSessionRecording() async throws {
        let audio = try VoiceControlTestAudio()
        let stt = VoiceControlTestSTT()
        let session = VoiceControlSpeechSession(audio: audio, stt: stt)
        let events = session.events
        let first = Task {
            for await event in events {
                if case .transcript = event { return }
            }
        }
        try await session.begin(handsFree: true)
        for _ in 0..<2 { await audio.emit(Array(repeating: 0.1, count: 1600)) }
        for _ in 0..<9 { await audio.emit(Array(repeating: 0, count: 1600)) }
        await first.value
        await session.commit()
        let jobs = await stt.jobs
        XCTAssertEqual(jobs.count, 1, "Finish speaking must not transcribe the whole rolling session again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.url.path))
    }
}

extension VoiceControlSpeechTests {
    @MainActor func testLiteralModePreservesEscapePrefixAndPayload() {
        XCTAssertEqual(VoiceControlCoordinator.literalInstruction("type literally hello"), "type literally hello")
        XCTAssertEqual(
            VoiceControlCoordinator.literalInstruction("type literally command mode"), "type literally command mode")
        XCTAssertEqual(VoiceControlCoordinator.literalInstruction("stop listening"), "type stop listening")
        XCTAssertEqual(VoiceControlCoordinator.literalInstruction("um, not two"), "type um, not two")
    }
}

extension VoiceControlSpeechTests {
    func testPhysicalStopRevokesQueuedSpeechBeforeActorCleanupRuns() {
        let fence = VoiceControlSpeechRevocation()
        let queuedUtterance = UUID()
        fence.beginCapture(utterance: queuedUtterance)
        XCTAssertTrue(fence.accepts(queuedUtterance))
        fence.revoke()
        XCTAssertFalse(fence.accepts(queuedUtterance), "A queued speechBegan or final cannot revive this utterance")
        let remainder = UUID()
        XCTAssertFalse(fence.beginUtterance(remainder), "Remaining stopped speech cannot re-arm listening")
        XCTAssertFalse(fence.accepts(remainder))
        fence.rearmAfterSilence()
        let next = UUID()
        XCTAssertTrue(fence.beginUtterance(next))
        XCTAssertTrue(fence.accepts(next))
        XCTAssertFalse(fence.accepts(queuedUtterance))
    }
}

extension VoiceControlSpeechTests {
    func testContextualCorrectionPhrasesDoNotTreatUnrelatedGoalsAsRevisions() {
        let open = VoiceControlUtteranceIntent.State(hasOpenTask: true)
        for phrase in ["Actually London", "No, the other one", "Change that to tomorrow"] {
            XCTAssertEqual(VoiceControlUtteranceIntent.classify(phrase, state: open), .correction)
        }
        XCTAssertEqual(VoiceControlUtteranceIntent.classify("Undo that", state: open), .newInstruction)
        XCTAssertEqual(VoiceControlUtteranceIntent.classify("Find flights to London", state: open), .newInstruction)
        XCTAssertEqual(VoiceControlUtteranceIntent.classify("Type hello", state: open), .newInstruction)
        let closed = VoiceControlUtteranceIntent.State(hasOpenTask: true, taskClosed: true)
        XCTAssertEqual(
            VoiceControlUtteranceIntent.classify("Actually London", state: closed), .newInstruction,
            "a finished task is never revised")
    }

    @MainActor func testActivityPreservesPendingConfirmationAndDoesNotClaimAttemptsSucceeded() {
        let model = VoiceControlViewModel()
        model.apply(.confirmation(VoiceControlAction(operation: .press, targetID: "send"), "Send?"))
        model.apply(.activity("Unknown effect: check the current app before continuing."))
        XCTAssertEqual(model.phase, .confirmation)
        XCTAssertTrue(model.conversation.takeConfirmation())
        XCTAssertEqual(model.steps.last, "Unknown effect: check the current app before continuing.")
        for _ in 0..<110 { model.appendActivity("Observed transition") }
        XCTAssertEqual(model.steps.count, 100)
    }
}

extension VoiceControlSpeechTests {
    @MainActor func testStoppedTypedSubmissionCannotResumeAfterSnapshotCompletes() async {
        let submissions = VoiceControlSubmissionState()
        let token = submissions.begin()
        let snapshot = AsyncStream<Void>.makeStream()
        let preparation = Task { @MainActor in
            for await _ in snapshot.stream { break }
            return submissions.accepts(token)
        }
        submissions.invalidate()
        snapshot.continuation.yield(())
        snapshot.continuation.finish()
        let admitted = await preparation.value
        XCTAssertFalse(admitted)
        XCTAssertFalse(token.isValid, "The runner actor receives the same revoked authority")
    }

    @MainActor func testNewIntentSupersedesQueuedResumeOrCancellation() {
        let submissions = VoiceControlSubmissionState()
        let queued = submissions.begin()
        let newer = submissions.begin()
        XCTAssertFalse(submissions.accepts(queued))
        XCTAssertFalse(queued.isValid)
        XCTAssertTrue(submissions.accepts(newer))
    }

    @MainActor func testConfirmationKeepsBoundAuthorityUntilExplicitRevocation() {
        let submissions = VoiceControlSubmissionState()
        let pending = submissions.begin()
        XCTAssertTrue(submissions.currentOrBegin() === pending)
        XCTAssertTrue(pending.isValid)
        submissions.invalidate()
        XCTAssertFalse(pending.isValid)
        XCTAssertFalse(submissions.accepts(pending))
        XCTAssertFalse(submissions.currentOrBegin() === pending)
    }
}

extension VoiceControlSpeechTests {
    @MainActor func testCancelledTaskClearsGoalAndActivityBeforeLaterCorrection() {
        let model = VoiceControlViewModel()
        model.goal = "Find flights from Zurich to Paris"
        model.appendActivity("Verified: selected Paris")
        model.apply(.clarification("Which departure date?"))
        model.apply(.cancelled)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.goal.isEmpty, "A later correction cannot attach to the cancelled goal")
        XCTAssertTrue(model.steps.isEmpty)
        XCTAssertNil(model.conversation.expectedResponse)
    }
}

extension VoiceControlSpeechTests {
    // 2 x 1600 speech samples begin an utterance; 9 x 1600 silent samples (900 ms) end it.
    private static let speech = Array(repeating: Float(0.1), count: 1600)
    private static let silence = Array(repeating: Float(0), count: 1600)

    private func speakThenPause(_ audio: VoiceControlTestAudio) async {
        for _ in 0..<2 { await audio.emit(Self.speech) }
        for _ in 0..<9 { await audio.emit(Self.silence) }
    }

    private func waitForSegmentCleanup(_ url: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "The superseded final must return through its cleanup before the session is stopped"
        )
    }

    func testSpeechResumingBeforePendingFinalMergesEarlierWordsIntoOneCommand() async throws {
        let audio = try VoiceControlTestAudio()
        let stt = VoiceControlTestSTT()
        let firstStarted = expectation(description: "First final STT is suspended")
        let secondStarted = expectation(description: "Merged final reached STT")
        let transcriptDelivered = expectation(description: "Merged transcript delivered")
        await stt.expectStarts([firstStarted, secondStarted])
        await stt.setWait(onlyOnce: true)
        let session = VoiceControlSpeechSession(audio: audio, stt: stt)
        let events = session.events
        let delivered = TranscriptCounter(expectations: [transcriptDelivered])
        let collector = Task {
            for await event in events {
                if case .transcript = event { await delivered.increment() }
                if case .measured(let metrics, _) = event { await delivered.note(metrics) }
                if case .stopped = event { return }
            }
        }
        try await session.begin(handsFree: true)
        await speakThenPause(audio)
        let firstStartResult = await XCTWaiter.fulfillment(of: [firstStarted], timeout: 5)
        guard firstStartResult == .completed else {
            await stt.release()
            await session.cancel()
            await collector.value
            return XCTFail("The first segment must reach final STT before speech resumes")
        }
        let firstAudioURL = await stt.audioURLs.first
        let supersededAudioURL = try XCTUnwrap(firstAudioURL)
        await speakThenPause(audio)
        await fulfillment(of: [secondStarted], timeout: 5)
        await stt.release()
        await fulfillment(of: [transcriptDelivered], timeout: 5)
        // The service deletes this file in transcribe's defer, after deciding
        // whether its late result may publish. Stop must not mask that decision.
        try await waitForSegmentCleanup(supersededAudioURL)
        await session.cancel()
        await collector.value
        let frames = await stt.frames
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.first, 17_600)
        XCTAssertEqual(
            frames.last, 35_200, "The resumed utterance carries the earlier segment instead of dropping it")
        let transcripts = await delivered.count
        XCTAssertEqual(transcripts, 1, "The superseded partial segment never becomes its own command")
        let measured = await delivered.metrics
        XCTAssertEqual(measured.count, 1)
        XCTAssertEqual(measured.first?.mergedSegments, 1)
        XCTAssertEqual(measured.first?.pauseMilliseconds, [900], "The merged gap is logged at its full length")
        XCTAssertEqual(measured.first?.speechMilliseconds, 1_300)
        XCTAssertEqual(measured.first?.endpointSilenceMilliseconds, 900)
        XCTAssertNil(measured.first?.sincePreviousMilliseconds)
    }

    func testSpeechAfterDeliveredFinalStartsAFreshUtterance() async throws {
        let audio = try VoiceControlTestAudio()
        let stt = VoiceControlTestSTT()
        let firstDelivered = expectation(description: "First command transcript delivered")
        let secondDelivered = expectation(description: "Second command transcript delivered")
        let session = VoiceControlSpeechSession(audio: audio, stt: stt)
        let events = session.events
        let delivered = TranscriptCounter(expectations: [firstDelivered, secondDelivered])
        let collector = Task {
            for await event in events {
                if case .transcript = event { await delivered.increment() }
                if case .measured(let metrics, _) = event { await delivered.note(metrics) }
                if case .stopped = event { return }
            }
        }
        try await session.begin(handsFree: true)
        await speakThenPause(audio)
        let firstDeliveryResult = await XCTWaiter.fulfillment(of: [firstDelivered], timeout: 5)
        guard firstDeliveryResult == .completed else {
            await session.cancel()
            await collector.value
            return XCTFail("The first command must be delivered before fresh speech begins")
        }
        await speakThenPause(audio)
        await fulfillment(of: [secondDelivered], timeout: 5)
        await session.cancel()
        await collector.value
        let frames = await stt.frames
        XCTAssertEqual(frames, [17_600, 17_600], "A delivered command is never merged into the next one")
        let measured = await delivered.metrics
        XCTAssertEqual(measured.map(\.mergedSegments), [0, 0])
        XCTAssertNil(measured.first?.sincePreviousMilliseconds)
        XCTAssertNotNil(measured.last?.sincePreviousMilliseconds)
        XCTAssertEqual(measured.last?.overlapWithPrevious, 1, "Saying the same command again reads as a repeat")
    }

    func testTimerRecordsInTurnPausesButNotLeadingSilenceOrNoise() {
        var timer = VoiceControlSpeechTimer()
        timer.consume(count: 1600, voiced: true, inTurn: false)  // a stray blip
        timer.consume(count: 16_000, voiced: false, inTurn: false)
        timer.consume(count: 3200, voiced: true, inTurn: false)
        timer.began(continuing: false)
        timer.consume(count: 1600, voiced: false, inTurn: true)  // 100 ms: within a word run
        timer.consume(count: 1600, voiced: true, inTurn: true)
        timer.consume(count: 8000, voiced: false, inTurn: true)  // 500 ms pause
        timer.consume(count: 1600, voiced: true, inTurn: true)
        timer.consume(count: 14_400, voiced: false, inTurn: true)
        let span = timer.ended()
        XCTAssertEqual(span.pauseSamples, [8000])
        XCTAssertEqual(span.segments, 1)
        XCTAssertEqual(span.speechSamples, 3200 + 1600 + 1600 + 8000 + 1600)
    }

    func testOverlapIsWordJaccardIgnoringCaseAndPunctuation() {
        let words = VoiceControlSpeechTurnMetrics.words
        XCTAssertEqual(VoiceControlSpeechTurnMetrics.overlap(words("Open Safari."), words("open safari")), 1)
        XCTAssertEqual(VoiceControlSpeechTurnMetrics.overlap(words("open safari"), words("open mail")), 0.33)
        XCTAssertEqual(VoiceControlSpeechTurnMetrics.overlap([], []), 0)
    }
}

private actor TranscriptCounter {
    var count = 0
    var metrics: [VoiceControlSpeechTurnMetrics] = []
    let expectations: [XCTestExpectation]
    init(expectations: [XCTestExpectation] = []) { self.expectations = expectations }
    func increment() {
        count += 1
        if count <= expectations.count { expectations[count - 1].fulfill() }
    }
    func note(_ value: VoiceControlSpeechTurnMetrics) { metrics.append(value) }
}
