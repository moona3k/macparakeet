import FluidAudio
import Foundation
import XCTest
@testable import MacParakeetCore

final class NemotronDiarizationServiceTests: XCTestCase {
    func testArrivalIDsPreserveOverlapAndBriefReplyWithoutVoiceprints() {
        let result = NemotronDiarizationService.result(from: [
            .init(speakerIndex: 6, startSeconds: 1, endSeconds: 2),
            .init(speakerIndex: 2, startSeconds: 0, endSeconds: 1.5),
            .init(speakerIndex: 6, startSeconds: 3, endSeconds: 3.08),
        ])
        XCTAssertEqual(result.speakerCount, 2)
        XCTAssertEqual(result.segments.map(\.speakerId), ["S1", "S2", "S2"])
        XCTAssertEqual(result.segments.map(\.startMs), [0, 1000, 3000])
        XCTAssertEqual(result.segments.map(\.endMs), [1500, 2000, 3080])
        XCTAssertEqual(result.speechMsBySpeaker, ["S1": 1500, "S2": 1080])
        XCTAssertTrue(result.speakerEmbeddings.isEmpty)
    }

    func testSimultaneousArrivalHasDeterministicIDsAndInvalidActivityIsOmitted() {
        let result = NemotronDiarizationService.result(from: [
            .init(speakerIndex: 4, startSeconds: 0, endSeconds: 1),
            .init(speakerIndex: 1, startSeconds: 0, endSeconds: 2),
            .init(speakerIndex: 0, startSeconds: .nan, endSeconds: 3),
            .init(speakerIndex: 8, startSeconds: 3, endSeconds: 4),
            .init(speakerIndex: 0, startSeconds: 3, endSeconds: 3),
        ])
        XCTAssertEqual(result.segments.map(\.speakerId), ["S1", "S2"])
        XCTAssertEqual(result.segments.map(\.endMs), [2000, 1000])
        XCTAssertEqual(result.speakers.map(\.label), ["Speaker 1", "Speaker 2"])
    }

    func testCalendarCapFallsBackInsteadOfDeletingARealChannel() async throws {
        let fallback = MockDiarizationService()
        await fallback.configure(
            result: .init(
                segments: [.init(speakerId: "S1", startMs: 0, endMs: 2000)], speakerCount: 1,
                speakers: [.init(id: "S1", label: "Speaker 1")]
            ))
        let service = NemotronDiarizationService(
            loadRunner: {
                FixtureRunner(segments: [
                    .init(speakerIndex: 0, startSeconds: 0, endSeconds: 1),
                    .init(speakerIndex: 1, startSeconds: 1, endSeconds: 2),
                ])
            }, fallback: fallback)
        let result = try await service.diarize(audioURL: audioURL, speakerConstraint: .range(min: 1, max: 1))
        XCTAssertEqual(result.speakerCount, 1)
        XCTAssertEqual(result.segments.first?.endMs, 2000)
        let called = await fallback.diarizeCalled
        XCTAssertTrue(called)
    }

    func testNaturalCountWithinCalendarBoundsUsesNemotron() async throws {
        let fallback = MockDiarizationService()
        let service = NemotronDiarizationService(
            loadRunner: {
                FixtureRunner(segments: [.init(speakerIndex: 3, startSeconds: 0, endSeconds: 1)])
            }, fallback: fallback)
        let result = try await service.diarize(audioURL: audioURL, speakerConstraint: .range(min: 1, max: 3))
        XCTAssertEqual(result.speakerCount, 1)
        let called = await fallback.diarizeCalled
        XCTAssertFalse(called)
    }

    func testUnavailableCalendarFallbackPreservesSuccessfulNativeAttribution() async throws {
        let fallback = MockDiarizationService()
        await fallback.configure(error: URLError(.notConnectedToInternet))
        let service = NemotronDiarizationService(
            loadRunner: {
                FixtureRunner(segments: [
                    .init(speakerIndex: 0, startSeconds: 0, endSeconds: 1),
                    .init(speakerIndex: 1, startSeconds: 1, endSeconds: 2),
                ])
            }, fallback: fallback)
        let result = try await service.diarize(audioURL: audioURL, speakerConstraint: .range(min: 1, max: 1))
        XCTAssertEqual(result.speakerCount, 2)
        XCTAssertEqual(result.segments.map(\.speakerId), ["S1", "S2"])
        let called = await fallback.diarizeCalled
        XCTAssertTrue(called)
    }

    func testCancelledCalendarFallbackDoesNotReturnSuccessfulAttribution() async throws {
        let fallback = MockDiarizationService()
        await fallback.configure(error: CancellationError())
        let service = NemotronDiarizationService(
            loadRunner: {
                FixtureRunner(segments: [
                    .init(speakerIndex: 0, startSeconds: 0, endSeconds: 1),
                    .init(speakerIndex: 1, startSeconds: 1, endSeconds: 2),
                ])
            }, fallback: fallback)
        do {
            _ = try await service.diarize(audioURL: audioURL, speakerConstraint: .range(min: 1, max: 1))
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
    }

    func testSilenceDoesNotForceTheMinimumSpeakerCount() async throws {
        let fallback = MockDiarizationService()
        let service = NemotronDiarizationService(loadRunner: { FixtureRunner(segments: []) }, fallback: fallback)
        let result = try await service.diarize(audioURL: audioURL, speakerConstraint: .range(min: 1, max: 3))
        XCTAssertEqual(result.speakerCount, 0)
        let called = await fallback.diarizeCalled
        XCTAssertFalse(called)
    }

    func testConcurrentPreparationLoadsOnceAndFailedPreparationCanRetry() async throws {
        let loader = CountingLoader()
        let service = NemotronDiarizationService(
            loadRunner: { try await loader.load() }, fallback: MockDiarizationService())
        do {
            try await service.prepareModels()
            XCTFail("First load should fail")
        } catch TestFailure.firstLoad {}
        async let first: Void = service.prepareModels()
        async let second: Void = service.prepareModels()
        try await first
        try await second
        let count = await loader.count
        XCTAssertEqual(count, 2)
        let ready = await service.isReady()
        XCTAssertTrue(ready)
    }

    func testReadinessAndSetupIncludeExplicitCountCompatibilityModels() async throws {
        let fallback = MockDiarizationService()
        let service = NemotronDiarizationService(
            loadRunner: { FixtureRunner(segments: []) }, cached: { true }, fallback: fallback)
        let partiallyCached = await service.hasCachedModels()
        XCTAssertFalse(partiallyCached)
        _ = try await service.diarize(audioURL: audioURL)
        let nativeOnlyReady = await service.isReady()
        let unnecessaryPreparation = await fallback.prepareModelsCalled
        XCTAssertFalse(nativeOnlyReady)
        XCTAssertFalse(unnecessaryPreparation)

        try await service.prepareModels()
        let ready = await service.isReady()
        let fullyCached = await service.hasCachedModels()
        XCTAssertTrue(ready)
        XCTAssertTrue(fullyCached)
    }

    func testFailedCompatibilityPreparationDoesNotClaimReadinessOrPreventNativeInference() async throws {
        let fallback = MockDiarizationService()
        await fallback.configurePrepareModels(error: URLError(.notConnectedToInternet))
        let service = NemotronDiarizationService(loadRunner: { FixtureRunner(segments: []) }, fallback: fallback)
        do {
            try await service.prepareModels()
            XCTFail("Setup must report unavailable compatibility models")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        let ready = await service.isReady()
        XCTAssertFalse(ready)
        let result = try await service.diarize(audioURL: audioURL)
        XCTAssertEqual(result.speakerCount, 0)
    }

    func testCancelledCallerCannotStartInference() async throws {
        let service = NemotronDiarizationService(loadRunner: { FixtureRunner(segments: []) })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.diarize(audioURL: URL(fileURLWithPath: "/unused.wav"))
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation should propagate")
        } catch is CancellationError {}
        let ready = await service.isReady()
        XCTAssertFalse(ready)
    }

    func testCorruptDownloadDoesNotReplacePreviousArtifact() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = NemotronDiarizationModelStore.directory(base: base, preset: .fast128)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let asset = root.appendingPathComponent("learnable_sil_emb.bin")
        let previous = Data([1, 2, 3])
        try previous.write(to: asset)
        do {
            _ = try await NemotronDiarizationModelStore.prepare(
                base: base, preset: .fast128,
                fetch: { url in
                    XCTAssertTrue(url.path.contains(NemotronDiarizationModelStore.revision))
                    return Data([4, 5, 6])
                })
            XCTFail("Invalid model bytes should be rejected")
        } catch NemotronDiarizationError.invalidModelAsset {}
        XCTAssertEqual(try Data(contentsOf: asset), previous)
        XCTAssertFalse(NemotronDiarizationModelStore.isCached(base: base, preset: .fast128))
    }

    func testQueuedInferenceCancelsWithoutWaitingForPreviousRecording() async throws {
        let permit = AsyncPermit(value: 0)
        let loaded = expectation(description: "Runner loaded")
        let cancelled = expectation(description: "Queued caller cancelled")
        let service = NemotronDiarizationService(
            loadRunner: {
                loaded.fulfill()
                return FixtureRunner(segments: [])
            }, inferencePermit: permit)
        let task = Task {
            do {
                _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/unused.wav"))
                XCTFail("Queued inference must not start")
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await fulfillment(of: [loaded], timeout: 2)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        permit.signal()
        await task.value
    }

    func testReadinessStaysResponsiveAndCancellationReachesRunningInference() async throws {
        let runner = BlockingRunner()
        let service = NemotronDiarizationService(loadRunner: { runner }, fallback: MockDiarizationService())
        let task = Task { try await service.diarize(audioURL: audioURL) }
        let deadline = Date().addingTimeInterval(5)
        while !runner.started, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(runner.started)

        // Before inference moved off the actor, this waited for the runner.
        _ = await service.isReady()
        XCTAssertTrue(runner.running, "Readiness must not wait for an in-flight recording")

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertTrue(runner.observedCancellation)
    }

    func testAutomaticAndExplicitFactoryPolicies() async {
        XCTAssertTrue(DiarizationServiceFactory.live.make(speakerConstraint: nil) is NemotronDiarizationService)
        for constraint in [SpeakerDiarizationConstraint.exact(12), .range(min: 2, max: 5)] {
            let service = DiarizationServiceFactory.live.make(speakerConstraint: constraint)
            XCTAssertTrue(service is DiarizationService)
            let configured = await service.explicitSpeakerConstraint()
            XCTAssertEqual(configured, constraint)
        }
    }

    func testClearingSpeakerCachesRemovesBothBackendsAndPreservesASR() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = [
            "speaker-diarization/model", "nemotron-diarization/old/fast128/model",
            "nemotron-diarization/current/offline/model", "nemotron-asr/model",
        ]
        for path in paths {
            let asset = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: asset)
        }
        DiarizationServiceFactory.clearModelCaches(directory: base)
        DiarizationServiceFactory.clearModelCaches(directory: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("speaker-diarization").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("nemotron-diarization").path))
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("nemotron-asr/model")), Data([1]))
    }

    func testExperimentalVoiceProfilesKeepEmbeddingCompatibleBackend() async {
        let automatic = DiarizationServiceFactory.makeLiveService(speakerConstraint: nil, voiceProfilesAvailable: true)
        XCTAssertTrue(automatic is DiarizationService)
        let explicit = DiarizationServiceFactory.makeLiveService(
            speakerConstraint: .exact(12), voiceProfilesAvailable: true)
        XCTAssertTrue(explicit is DiarizationService)
        let configured = await explicit.explicitSpeakerConstraint()
        XCTAssertEqual(configured, .exact(12))
    }

    private var audioURL: URL { URL(fileURLWithPath: "/unused.wav") }

    private struct FixtureRunner: NemotronDiarizationRunning {
        let segments: [NemotronSpeakerActivity]
        func process(audioURL: URL) throws -> [NemotronSpeakerActivity] { segments }
    }

    /// Spins like chunked inference until cancelled, giving up after a bound
    /// so a regression fails the assertions instead of hanging the suite.
    private final class BlockingRunner: NemotronDiarizationRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var state = (started: false, running: false, observedCancellation: false)
        var started: Bool { lock.withLock { state.started } }
        var running: Bool { lock.withLock { state.running } }
        var observedCancellation: Bool { lock.withLock { state.observedCancellation } }

        func process(audioURL: URL) throws -> [NemotronSpeakerActivity] {
            lock.withLock {
                state.started = true
                state.running = true
            }
            defer { lock.withLock { state.running = false } }
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if Task.isCancelled {
                    lock.withLock { state.observedCancellation = true }
                    throw CancellationError()
                }
                usleep(1_000)
            }
            return []
        }
    }

    private enum TestFailure: Error { case firstLoad }
    private actor CountingLoader {
        private(set) var count = 0
        func load() throws -> any NemotronDiarizationRunning {
            count += 1
            if count == 1 { throw TestFailure.firstLoad }
            return FixtureRunner(segments: [])
        }
    }
}
