import XCTest
@testable import MacParakeetCore

final class OrukeetModelStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func manifest(
        filename: String = "orukeet-r3-coreml-baseline.zip",
        bytes: Int = OrukeetModelStore.archiveBytes,
        sha256: String = OrukeetModelStore.archiveSHA256
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "archives": [
                "baseline": [
                    "filename": filename, "bytes": bytes, "sha256": sha256,
                ]
            ]
        ])
    }

    func testManifestRejectsChangedArtifactMetadata() throws {
        XCTAssertNoThrow(try OrukeetModelStore.validateManifest(manifest()))
        XCTAssertThrowsError(try OrukeetModelStore.validateManifest(manifest(filename: "other.zip")))
        XCTAssertThrowsError(try OrukeetModelStore.validateManifest(manifest(bytes: 1)))
        XCTAssertThrowsError(try OrukeetModelStore.validateManifest(manifest(sha256: "incorrect")))
        XCTAssertThrowsError(try OrukeetModelStore.validateManifest(Data("{}".utf8)))
    }

    func testIncompleteCacheIsNotInstalled() throws {
        let directory = try temporaryDirectory()
        try OrukeetModelStore.revision.write(
            to: directory.appendingPathComponent(".revision"),
            atomically: true, encoding: .utf8)
        XCTAssertFalse(OrukeetModelStore.installed(at: directory))
        XCTAssertThrowsError(try OrukeetModelStore.load(from: directory))
    }

    func testCorruptArchivePreservesExistingCache() throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("previous")
        try Data("valid previous install".utf8).write(to: marker)
        let archive = directory.appendingPathComponent("corrupt.zip")
        try Data("corrupt".utf8).write(to: archive)
        XCTAssertThrowsError(try OrukeetModelStore.installArchive(at: archive, to: destination))
        XCTAssertEqual(try Data(contentsOf: marker), Data("valid previous install".utf8))
    }

    func testFailedCommitRestoresExistingCache() throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("previous")
        try Data("previous".utf8).write(to: marker)
        XCTAssertThrowsError(
            try OrukeetModelStore.commitInstallation(
                from: directory.appendingPathComponent("missing"), to: destination))
        XCTAssertEqual(try Data(contentsOf: marker), Data("previous".utf8))
    }

    func testSuccessfulCommitReplacesExistingCache() throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("installed")
        let staged = directory.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("old"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("new"))
        try OrukeetModelStore.commitInstallation(from: staged, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("new")), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testCancellingFirstCallerPreservesOtherWaiterAndProgress() async throws {
        try await checkSharedCancellation(cancelFirst: true)
    }

    func testCancellingSecondCallerPreservesFirstWaiterAndProgress() async throws {
        try await checkSharedCancellation(cancelFirst: false)
    }

    private func checkSharedCancellation(cancelFirst: Bool) async throws {
        let gate = OrukeetInstallationTestGate()
        let started = expectation(description: "one shared installation")
        started.assertForOverFulfill = true
        let firstJoined = expectation(description: "first subscriber")
        let secondJoined = expectation(description: "second subscriber")
        let survivorProgress = expectation(description: "remaining subscriber receives progress")
        let cancelledReturned = expectation(description: "cancelled subscriber returns promptly")
        let installation = OrukeetInstallation { progress in
            started.fulfill()
            await gate.wait()
            try Task.checkCancellation()
            progress(0.5)
            // Let the relayed progress reach the remaining waiter before completing.
            await gate.waitForProgress()
        }
        let first = Task {
            do {
                try await installation.install { value in
                    if value == 0 { firstJoined.fulfill() }
                    if value == 0.5 && !cancelFirst {
                        survivorProgress.fulfill()
                        Task { await gate.progressReceived() }
                    }
                }
            } catch {
                if cancelFirst { cancelledReturned.fulfill() }
                throw error
            }
        }
        await fulfillment(of: [firstJoined, started], timeout: 5)
        let second = Task {
            do {
                try await installation.install { value in
                    if value == 0 { secondJoined.fulfill() }
                    if value == 0.5 && cancelFirst {
                        survivorProgress.fulfill()
                        Task { await gate.progressReceived() }
                    }
                }
            } catch {
                if !cancelFirst { cancelledReturned.fulfill() }
                throw error
            }
        }
        await fulfillment(of: [secondJoined], timeout: 5)
        let cancelled = cancelFirst ? first : second
        let survivor = cancelFirst ? second : first
        cancelled.cancel()
        await fulfillment(of: [cancelledReturned], timeout: 5)
        await gate.open()
        await fulfillment(of: [survivorProgress], timeout: 5)
        // Also unblock a failing implementation so the test does not leave a task suspended.
        await gate.progressReceived()
        try await survivor.value
        do {
            try await cancelled.value
            XCTFail("Cancelled caller must not report success")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLastCancellationStopsInstallAndRetryWaitsForCleanup() async throws {
        let gate = OrukeetInstallationTestGate()
        let probe = OrukeetInstallationTestProbe()
        let started = expectation(description: "first installation started")
        let cancelledReturned = expectation(description: "lone caller returns promptly")
        let retryStarted = expectation(description: "retry starts after cleanup")
        let installation = OrukeetInstallation { _ in
            let attempt = await probe.start()
            if attempt == 1 {
                started.fulfill()
                await gate.wait()
                await probe.end()
                try Task.checkCancellation()
                XCTFail("Last caller cancellation must cancel underlying work")
            } else {
                retryStarted.fulfill()
                await probe.end()
            }
        }
        let first = Task {
            do { try await installation.install { _ in } } catch {
                cancelledReturned.fulfill()
                throw error
            }
        }
        await fulfillment(of: [started], timeout: 5)
        first.cancel()
        await fulfillment(of: [cancelledReturned], timeout: 5)
        let retry = Task { try await installation.install { _ in } }
        await gate.open()
        await fulfillment(of: [retryStarted], timeout: 5)
        try await retry.value
        do {
            try await first.value
            XCTFail("Cancelled caller must not report success")
        } catch { XCTAssertTrue(error is CancellationError) }
        let counts = await probe.counts()
        XCTAssertEqual(counts.attempts, 2)
        XCTAssertEqual(counts.maximumActive, 1)
    }

    func testOrukeetUsesDistinctIdentityAndConservativeCapabilities() {
        XCTAssertNil(ParakeetModelVariant.orukeet.asrModelVersion)
        XCTAssertFalse(ParakeetModelVariant.orukeet.usesUnifiedEngine)
        XCTAssertFalse(ParakeetModelVariant.orukeet.isEnglishOnly)
        let capabilities = SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.orukeet))
        XCTAssertFalse(capabilities.supportsNativeLiveDictation)
        XCTAssertFalse(capabilities.supportsTailPreview)
        XCTAssertFalse(capabilities.supportsCustomVocabulary)
        XCTAssertEqual(capabilities.modelLifecycle.variantID, "orukeet")
        XCTAssertEqual(capabilities.telemetryIdentity.engineVariant, .fixed("orukeet"))
        XCTAssertEqual(SpeechEnginePreference.defaultParakeetModelVariant, .v3)
    }

    // Opt in with the immutable archive downloaded from the model card. Default CI uses no weights.
    func testPinnedArchiveInstallsAndLoadsOffline() throws {
        guard let path = ProcessInfo.processInfo.environment["ORUKEET_COREML_ARCHIVE"] else {
            throw XCTSkip("Set ORUKEET_COREML_ARCHIVE to run the real Core ML installation test")
        }
        let destination = try temporaryDirectory().appendingPathComponent("installed")
        try OrukeetModelStore.installArchive(at: URL(fileURLWithPath: path), to: destination)
        XCTAssertTrue(OrukeetModelStore.installed(at: destination))
        XCTAssertNoThrow(try OrukeetModelStore.load(from: destination))
        try FileManager.default.removeItem(at: destination.appendingPathComponent("Encoder.mlmodelc"))
        XCTAssertFalse(OrukeetModelStore.installed(at: destination))
        XCTAssertThrowsError(try OrukeetModelStore.load(from: destination))
    }
    func testRealSchedulerTranscriptionAndCachedReload() async throws {
        guard let path = ProcessInfo.processInfo.environment["ORUKEET_AUDIO_DIR"] else {
            throw XCTSkip("Set ORUKEET_AUDIO_DIR for real Hugging Face installation and scheduler smoke tests")
        }
        let audio = URL(fileURLWithPath: path)
        try await OrukeetModelStore.download()
        var previous: [String: String] = [:]
        for round in 0..<2 {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "OrukeetSmoke-\(UUID().uuidString)"))
            let client = STTClient(parakeetModelVariant: .orukeet, defaults: defaults)
            for name in ["en", "de", "fr", "silence"] {
                for job: STTJobKind in [.fileTranscription, .dictation, .meetingLiveChunk] {
                    let start = Date()
                    let result = try await client.transcribe(
                        audioPath: audio.appendingPathComponent(name + ".wav").path,
                        job: job, onProgress: nil)
                    XCTAssertEqual(result.engineVariant, "orukeet")
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if name == "silence" { XCTAssertTrue(text.isEmpty) } else { XCTAssertFalse(text.isEmpty) }
                    let key = "\(name)-\(job)"
                    if let expected = previous[key] { XCTAssertEqual(text, expected) }
                    previous[key] = text
                    XCTAssertTrue(result.words.allSatisfy { $0.startMs >= 0 && $0.endMs >= $0.startMs })
                    print(
                        "ORUKEET_SMOKE round=\(round) clip=\(name) job=\(job) seconds=\(Date().timeIntervalSince(start)) text=\(text)"
                    )
                }
            }
            await client.shutdown()
        }
    }
}

private actor OrukeetInstallationTestGate {
    private var isOpen = false
    private var receivedProgress = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var progressContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if !isOpen { await withCheckedContinuation { continuation = $0 } }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
    func waitForProgress() async {
        if !receivedProgress { await withCheckedContinuation { progressContinuation = $0 } }
    }
    func progressReceived() {
        receivedProgress = true
        progressContinuation?.resume()
        progressContinuation = nil
    }
}

private actor OrukeetInstallationTestProbe {
    private var attempts = 0
    private var active = 0
    private var maximumActive = 0
    func start() -> Int {
        attempts += 1
        active += 1
        maximumActive = max(maximumActive, active)
        return attempts
    }
    func end() { active -= 1 }
    func counts() -> (attempts: Int, maximumActive: Int) { (attempts, maximumActive) }
}
