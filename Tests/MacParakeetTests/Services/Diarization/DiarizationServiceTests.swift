import XCTest
import FluidAudio
@testable import MacParakeetCore

final class DiarizationServiceTests: XCTestCase {

    func testMockDiarizationServiceReturnsConfiguredResult() async throws {
        let mock = MockDiarizationService()
        let expected = MacParakeetDiarizationResult(
            segments: [
                SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 5000),
                SpeakerSegment(speakerId: "S2", startMs: 5000, endMs: 10000),
            ],
            speakerCount: 2,
            speakers: [
                SpeakerInfo(id: "S1", label: "Speaker 1"),
                SpeakerInfo(id: "S2", label: "Speaker 2"),
            ]
        )
        await mock.configure(result: expected)

        let dummyURL = URL(fileURLWithPath: "/tmp/test.wav")
        let result = try await mock.diarize(audioURL: dummyURL)
        XCTAssertEqual(result.speakerCount, 2)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.speakers.count, 2)
        XCTAssertEqual(result.speakers[0].id, "S1")
        XCTAssertEqual(result.speakers[1].label, "Speaker 2")

        let wasCalled = await mock.diarizeCalled
        XCTAssertTrue(wasCalled)
    }

    func testMockDiarizationServiceThrowsConfiguredError() async {
        let mock = MockDiarizationService()
        await mock.configure(error: STTError.transcriptionFailed("mock error"))

        let dummyURL = URL(fileURLWithPath: "/tmp/test.wav")
        do {
            _ = try await mock.diarize(audioURL: dummyURL)
            XCTFail("Expected error")
        } catch {
            // Expected
        }
    }

    func testMockDiarizationServiceDefaultsToEmpty() async throws {
        let mock = MockDiarizationService()
        let dummyURL = URL(fileURLWithPath: "/tmp/test.wav")
        let result = try await mock.diarize(audioURL: dummyURL)
        XCTAssertEqual(result.speakerCount, 0)
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertTrue(result.speakers.isEmpty)
    }

    func testMockPrepareModels() async throws {
        let mock = MockDiarizationService()
        try await mock.prepareModels()
        let wasCalled = await mock.prepareModelsCalled
        XCTAssertTrue(wasCalled)
        let ready = await mock.isReady()
        XCTAssertTrue(ready)
        let cached = await mock.hasCachedModels()
        XCTAssertTrue(cached)
    }

    func testIsReady() async {
        let mock = MockDiarizationService()
        let ready = await mock.isReady()
        XCTAssertFalse(ready)
    }

    func testClearModelCacheRemovesCachedSpeakerModels() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoDirectory = DiarizationService.modelCacheDirectory(directory: tempDirectory)
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        for modelName in DiarizationService.requiredModelNames() {
            let modelURL = repoDirectory.appendingPathComponent(modelName, isDirectory: false)
            FileManager.default.createFile(atPath: modelURL.path, contents: Data())
        }

        XCTAssertTrue(DiarizationService.isModelCached(directory: tempDirectory))

        DiarizationService.clearModelCache(directory: tempDirectory)

        XCTAssertFalse(DiarizationService.isModelCached(directory: tempDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoDirectory.path))
    }

    // MARK: - Configuration

    func testHighAccuracyConfigUsesAsyncSettings() {
        let config = DiarizationService.highAccuracyConfig
        let fast = OfflineDiarizerConfig.default

        XCTAssertEqual(config.segmentation.stepRatio, 0.1)
        XCTAssertEqual(config.embedding.minSegmentDurationSeconds, 0)
        XCTAssertTrue(config.zeroVoteReembed.enabled)
        XCTAssertTrue(config.clustering.constrainedAssignment)
        // Never tuned by the app; 0.15.6 changed its semantics to a plain distance cut.
        XCTAssertEqual(config.clustering.threshold, fast.clustering.threshold)
        XCTAssertNil(config.clustering.numSpeakers)
        XCTAssertNil(config.clustering.minSpeakers)
        XCTAssertNil(config.clustering.maxSpeakers)
        XCTAssertNoThrow(try config.validate())
    }

    func testOfflineConfigStartsFromHighAccuracyConfig() {
        let config = DiarizationService.offlineConfig(speakerConstraint: .exact(2))

        XCTAssertEqual(config.segmentation.stepRatio, 0.1)
        XCTAssertEqual(config.embedding.minSegmentDurationSeconds, 0)
        XCTAssertTrue(config.zeroVoteReembed.enabled)
    }

    func testOfflineConfigAppliesExactSpeakerConstraint() {
        let config = DiarizationService.offlineConfig(speakerConstraint: .exact(2))

        XCTAssertEqual(config.clustering.numSpeakers, 2)
        XCTAssertNil(config.clustering.minSpeakers)
        XCTAssertNil(config.clustering.maxSpeakers)
    }

    func testRetranscriptionSpeakerSelectionAcceptsDocumentedBounds() throws {
        XCTAssertEqual(
            try RetranscriptionSpeakerSelection.exact(1).validated(),
            .exact(1)
        )
        XCTAssertEqual(
            try RetranscriptionSpeakerSelection.exact(100).validated(),
            .exact(100)
        )
        XCTAssertEqual(
            try RetranscriptionSpeakerSelection.automatic.validated(),
            .automatic
        )
    }

    func testRetranscriptionSpeakerSelectionRejectsValuesOutsideDocumentedBounds() {
        XCTAssertThrowsError(try RetranscriptionSpeakerSelection.exact(0).validated()) { error in
            XCTAssertEqual(error as? RetranscriptionSpeakerSelectionError, .unsupportedExactCount(0))
        }
        XCTAssertThrowsError(try RetranscriptionSpeakerSelection.exact(101).validated()) { error in
            XCTAssertEqual(error as? RetranscriptionSpeakerSelectionError, .unsupportedExactCount(101))
        }
    }

    func testOfflineConfigAppliesSpeakerRangeConstraint() {
        let config = DiarizationService.offlineConfig(speakerConstraint: .range(min: 2, max: 4))

        XCTAssertNil(config.clustering.numSpeakers)
        XCTAssertEqual(config.clustering.minSpeakers, 2)
        XCTAssertEqual(config.clustering.maxSpeakers, 4)
    }

    func testOfflineConfigAppliesMinimumSpeakerRangeConstraint() {
        let config = DiarizationService.offlineConfig(speakerConstraint: .range(min: 2, max: nil))

        XCTAssertNil(config.clustering.numSpeakers)
        XCTAssertEqual(config.clustering.minSpeakers, 2)
        XCTAssertNil(config.clustering.maxSpeakers)
    }

    func testOfflineConfigAppliesMaximumSpeakerRangeConstraint() {
        let config = DiarizationService.offlineConfig(speakerConstraint: .range(min: nil, max: 4))

        XCTAssertNil(config.clustering.numSpeakers)
        XCTAssertNil(config.clustering.minSpeakers)
        XCTAssertEqual(config.clustering.maxSpeakers, 4)
    }

    // MARK: - Shared model loading

    func testSuspendedDownloadDoesNotHoldInferenceGate() async throws {
        let loader = RecordingModelLoader()
        let entered = expectation(description: "load entered")
        let release = AsyncPermit(value: 0)
        await loader.configure(entered: entered, release: release)
        let gate = ANEInferenceGate(serializationRequired: true)
        let service = makeService(loader, gate: gate)
        let preparation = Task { try await service.prepareModels() }
        await fulfillment(of: [entered], timeout: 2)

        let inference = expectation(description: "unrelated inference completes during download")
        let other = Task {
            try await gate.withExclusiveAccess { inference.fulfill() }
        }
        await fulfillment(of: [inference], timeout: 2)
        release.signal()
        try await preparation.value
        try await other.value
    }

    func testConcurrentConstraintsAndCancelledWaiterShareOneLoad() async throws {
        let loader = RecordingModelLoader()
        let entered = expectation(description: "load entered")
        let release = AsyncPermit(value: 0)
        await loader.configure(entered: entered, release: release)
        let service = makeService(loader)
        let cancelled = expectation(description: "cancelled caller returns before load finishes")
        let first = Task {
            do {
                _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav"), speakerConstraint: .exact(2))
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                cancelled.fulfill()
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task {
            try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/b.wav"), speakerConstraint: .exact(3))
        }
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        let readyWhileLoading = await service.isReady()
        XCTAssertFalse(readyWhileLoading)
        release.signal()
        await first.value
        _ = try await second.value
        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/c.wav"), speakerConstraint: .exact(4))
        let loads = await loader.directories.count
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(loader.factory.constraints, [.exact(3), .exact(4)])
        let ready = await service.isReady()
        XCTAssertTrue(ready)
    }

    func testEachRequestGetsManagerWithItsOwnConstraintAndSharedModels() async throws {
        let loader = RecordingModelLoader()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = makeService(loader, directory: directory)
        for constraint: SpeakerDiarizationConstraint? in [nil, .exact(2), .exact(2), .range(min: 1, max: 3)] {
            _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav"), speakerConstraint: constraint)
        }
        XCTAssertEqual(loader.factory.constraints, [nil, .exact(2), .exact(2), .range(min: 1, max: 3)])
        XCTAssertEqual(loader.factory.managers.count, 4)
        let directories = await loader.directories
        XCTAssertEqual(directories, [directory.standardizedFileURL])
    }

    func testExplicitConstraintWinsOverPerCallHint() async throws {
        let loader = RecordingModelLoader()
        let service = makeService(loader, explicitConstraint: .exact(3))
        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav"), speakerConstraint: .exact(2))
        XCTAssertEqual(loader.factory.constraints, [.exact(3)])
        let explicit = await service.explicitSpeakerConstraint()
        XCTAssertEqual(explicit, .exact(3))
    }

    func testFailedLoadCanRetryIncludingCancellationError() async throws {
        let loader = RecordingModelLoader()
        await loader.configure(errors: [OfflineDiarizationError.modelNotLoaded("first"), CancellationError()])
        let service = makeService(loader)
        for _ in 0..<2 {
            do {
                try await service.prepareModels()
                XCTFail("Expected load failure")
            } catch {}
            let ready = await service.isReady()
            XCTAssertFalse(ready)
        }
        try await service.prepareModels()
        let loads = await loader.directories.count
        let ready = await service.isReady()
        XCTAssertEqual(loads, 3)
        XCTAssertTrue(ready)
    }

    func testProcessingWaitsForInferenceGateAfterLoading() async throws {
        let gate = ANEInferenceGate(serializationRequired: true)
        let loader = RecordingModelLoader()
        let made = expectation(description: "manager initialized")
        loader.factory.made = made
        let service = makeService(loader, gate: gate)
        let acquired = expectation(description: "gate held")
        let release = AsyncPermit(value: 0)
        let holder = Task {
            try await gate.withExclusiveAccess {
                acquired.fulfill()
                try await release.wait()
            }
        }
        await fulfillment(of: [acquired], timeout: 2)
        let diarization = Task { try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav")) }
        await fulfillment(of: [made], timeout: 2)
        let manager = try XCTUnwrap(loader.factory.managers.first)
        let mustNotProcess = expectation(description: "processing cannot start while gate is held")
        mustNotProcess.isInverted = true
        await manager.observeProcessing(mustNotProcess)
        await fulfillment(of: [mustNotProcess], timeout: 0.1)
        await manager.observeProcessing(nil)
        let before = await manager.processedAudioURLs
        XCTAssertTrue(before.isEmpty)
        release.signal()
        try await holder.value
        _ = try await diarization.value
        let after = await manager.processedAudioURLs
        XCTAssertEqual(after, [URL(fileURLWithPath: "/tmp/a.wav")])
    }

    func testAlreadyCancelledCallerDoesNotStartLoad() async throws {
        let loader = RecordingModelLoader()
        let service = makeService(loader)
        let start = AsyncPermit(value: 0)
        let task = Task {
            // The signal orders cancellation before entering the service.
            _ = try? await start.wait()
            do {
                try await service.prepareModels()
                XCTFail("Expected cancellation")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
        task.cancel()
        start.signal()
        await task.value
        let loads = await loader.directories.count
        XCTAssertEqual(loads, 0)
    }

    func testMetadataRepairReplacesOnlyMalformedMetadata() async throws {
        let directory = try makeMetadataCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = DiarizationService.modelCacheDirectory(directory: directory).appendingPathComponent("plda-parameters.json")
        let replacement = Data(#"{"tensors":{"psi":{"data_base64":"AACAPw=="}}}"#.utf8)
        try await DiarizationService.repairPLDAParameters(directory: directory, offlineMode: false) { url in
            XCTAssertEqual(url, try ModelRegistry.resolveModel(Repo.diarizer.remotePath, "plda-parameters.json"))
            return replacement
        }
        XCTAssertEqual(try Data(contentsOf: metadata), replacement)
        XCTAssertTrue(DiarizationService.isModelCached(directory: directory))
        try await DiarizationService.repairPLDAParameters(directory: directory, offlineMode: false) { _ in
            XCTFail("Valid metadata must not be downloaded again")
            return Data()
        }
    }

    func testMetadataRepairPreservesCacheOnNetworkCancellationOrInvalidReplacement() async throws {
        for error: Error? in [URLError(.notConnectedToInternet), CancellationError(), nil] {
            let directory = try makeMetadataCache()
            defer { try? FileManager.default.removeItem(at: directory) }
            let metadata = DiarizationService.modelCacheDirectory(directory: directory).appendingPathComponent("plda-parameters.json")
            do {
                try await DiarizationService.repairPLDAParameters(directory: directory, offlineMode: false) { _ in
                    if let error { throw error }
                    return Data("bad replacement".utf8)
                }
                XCTFail("Expected repair failure")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: metadata), Data("malformed".utf8))
            XCTAssertTrue(DiarizationService.isModelCached(directory: directory))
        }
    }

    func testMetadataRepairDoesNotFetchOfflineOrForMissingMetadata() async throws {
        let directory = try makeMetadataCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await DiarizationService.repairPLDAParameters(directory: directory, offlineMode: true) { _ in
            XCTFail("Offline mode must not fetch")
            return Data()
        }
        let metadata = DiarizationService.modelCacheDirectory(directory: directory).appendingPathComponent("plda-parameters.json")
        XCTAssertEqual(try Data(contentsOf: metadata), Data("malformed".utf8))
        try FileManager.default.removeItem(at: metadata)
        try await DiarizationService.repairPLDAParameters(directory: directory, offlineMode: false) { _ in
            XCTFail("Missing metadata belongs to normal model download")
            return Data()
        }
    }

    private func makeMetadataCache() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = DiarizationService.modelCacheDirectory(directory: directory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for name in DiarizationService.requiredModelNames() {
            let file = repo.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("model sentinel".utf8).write(to: file)
        }
        try Data("malformed".utf8).write(to: repo.appendingPathComponent("plda-parameters.json"))
        return directory
    }

    private func makeService(
        _ loader: RecordingModelLoader,
        directory: URL = FileManager.default.temporaryDirectory,
        explicitConstraint: SpeakerDiarizationConstraint? = nil,
        gate: ANEInferenceGate = ANEInferenceGate(serializationRequired: false)
    ) -> DiarizationService {
        DiarizationService(
            loadManagerFactory: { try await loader.load(from: $0) },
            modelsDirectory: directory,
            explicitConstraint: explicitConstraint,
            inferenceGate: gate
        )
    }
}

private actor RecordingModelLoader {
    nonisolated let factory = RecordingManagerFactory()
    var directories: [URL] = []
    private var entered: XCTestExpectation?
    private var release: AsyncPermit?
    private var errors: [Error] = []

    func configure(entered: XCTestExpectation? = nil, release: AsyncPermit? = nil, errors: [Error] = []) {
        self.entered = entered
        self.release = release
        self.errors = errors
    }

    func load(from directory: URL) async throws -> DiarizationService.ManagerFactory {
        directories.append(directory)
        entered?.fulfill()
        if !errors.isEmpty { throw errors.removeFirst() }
        if let release { try await release.wait() }
        return { [factory] in factory.make(for: $0) }
    }
}

private final class RecordingManagerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var storedConstraints: [SpeakerDiarizationConstraint?] = []
    private var storedManagers: [RecordingOfflineDiarizerManager] = []
    var made: XCTestExpectation?
    var constraints: [SpeakerDiarizationConstraint?] { lock.withLock { storedConstraints } }
    var managers: [RecordingOfflineDiarizerManager] { lock.withLock { storedManagers } }

    func make(for constraint: SpeakerDiarizationConstraint?) -> any OfflineDiarizerManaging {
        lock.withLock {
            storedConstraints.append(constraint)
            let manager = RecordingOfflineDiarizerManager()
            storedManagers.append(manager)
            made?.fulfill()
            return manager
        }
    }
}

private actor RecordingOfflineDiarizerManager: OfflineDiarizerManaging {
    var processedAudioURLs: [URL] = []
    private var processing: XCTestExpectation?
    func observeProcessing(_ expectation: XCTestExpectation?) {
        processing = expectation
        if !processedAudioURLs.isEmpty { processing?.fulfill() }
    }
    func process(audioURL: URL) async throws -> DiarizationResult {
        processedAudioURLs.append(audioURL)
        processing?.fulfill()
        return DiarizationResult(segments: [])
    }
}
