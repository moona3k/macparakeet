import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TranscriptionViewModelBatchTests: XCTestCase {
    private var mockService: MockTranscriptionService!
    private var mockRepo: MockTranscriptionRepository!
    private var tempDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        mockService = MockTranscriptionService()
        mockRepo = MockTranscriptionRepository()
        suiteName = "TranscriptionViewModelBatchTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VMBatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeViewModel() -> TranscriptionViewModel {
        let vm = TranscriptionViewModel(defaults: defaults)
        vm.configure(transcriptionService: mockService, transcriptionRepo: mockRepo)
        return vm
    }

    private func touch(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Single-file regression

    func testSingleFileRoutesThroughSinglePathAndSignals() async throws {
        let vm = makeViewModel()
        var captured: TranscriptionCompletionNotifier.Content?
        vm.onTranscriptionCompleted = { captured = $0 }

        let url = try touch("only.mp3")
        let accepted = vm.transcribeFiles(urls: [url])
        XCTAssertTrue(accepted)
        XCTAssertFalse(vm.isBatchActive, "One file must never enter batch mode")

        try await waitUntil { !vm.isTranscribing }
        XCTAssertNotNil(vm.currentTranscription, "Single file still presents its result")
        XCTAssertEqual(captured?.title, "only.mp3")
        // Mock default transcript is "Mock transcription" (two words).
        XCTAssertEqual(captured?.body, "Transcription complete \u{00B7} 2 words")
    }

    // MARK: - Batch happy path

    func testBatchProcessesAllFilesInNameOrderAndSignalsOnce() async throws {
        let vm = makeViewModel()
        var signalCount = 0
        var captured: TranscriptionCompletionNotifier.Content?
        vm.onTranscriptionCompleted = { signalCount += 1; captured = $0 }

        // Provide out of order; enumerator sorts to a, b, c.
        let urls = [try touch("c.mp3"), try touch("a.mp3"), try touch("b.mp3")]
        let accepted = vm.transcribeFiles(urls: urls)
        XCTAssertTrue(accepted)
        XCTAssertTrue(vm.isBatchActive)
        XCTAssertEqual(vm.batchTotalCount, 3)

        try await waitUntil { !vm.isBatchActive }

        let order = await mockService.transcribedFileNames
        XCTAssertEqual(order, ["a.mp3", "b.mp3", "c.mp3"], "Sequential, name-ordered")
        XCTAssertEqual(signalCount, 1, "Exactly one signal for the whole batch")
        XCTAssertEqual(captured?.body, "3 files transcribed")
        XCTAssertNil(vm.currentTranscription, "Batch is ambient — no per-file presentation")
    }

    // MARK: - Failure continues the batch

    func testFailedFileDoesNotAbortBatch() async throws {
        await mockService.configureBatch(errors: [
            "b.mp3": NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        ])
        let vm = makeViewModel()
        var captured: TranscriptionCompletionNotifier.Content?
        vm.onTranscriptionCompleted = { captured = $0 }

        let urls = [try touch("a.mp3"), try touch("b.mp3"), try touch("c.mp3")]
        vm.transcribeFiles(urls: urls)

        try await waitUntil { !vm.isBatchActive }

        let order = await mockService.transcribedFileNames
        XCTAssertEqual(order, ["a.mp3", "b.mp3", "c.mp3"], "All files attempted despite the failure")
        XCTAssertEqual(captured?.title, "Transcriptions finished with errors")
        XCTAssertEqual(captured?.body, "2 transcribed \u{00B7} 1 failed")
        XCTAssertNil(vm.errorMessage, "Batch failures don't raise a blocking error card")
    }

    // MARK: - Cancel

    func testCancelBatchStopsAdvancing() async throws {
        await mockService.configureDelay(milliseconds: 60)
        let vm = makeViewModel()
        var signalCount = 0
        vm.onTranscriptionCompleted = { _ in signalCount += 1 }

        let urls = [try touch("a.mp3"), try touch("b.mp3"), try touch("c.mp3"), try touch("d.mp3")]
        vm.transcribeFiles(urls: urls)
        XCTAssertTrue(vm.isBatchActive)

        // Cancel while the first file is still in flight.
        try await waitUntil { vm.isTranscribing }
        vm.cancelBatch()

        // Cancellation is deterministic — state is cleared synchronously.
        XCTAssertFalse(vm.isBatchActive)
        XCTAssertEqual(vm.batchTotalCount, 0, "Batch state reset after cancel")
        XCTAssertFalse(vm.isTranscribing)

        // Let the in-flight file's (delayed, not cancellation-aware) transcription
        // resolve and let any (incorrectly) queued work get a chance to run.
        try await Task.sleep(for: .milliseconds(200))
        let count = await mockService.transcribedFileNames.count
        XCTAssertLessThan(count, 4, "Cancelling must stop draining the queue")
        XCTAssertEqual(signalCount, 0, "No completion signal fires after Cancel all")
        XCTAssertFalse(vm.isBatchActive, "A late-resolving file must not revive the batch")
    }

    // MARK: - Notification setting

    func testNoSignalWhenNotificationSettingOff() async throws {
        defaults.set(false, forKey: UserDefaultsAppRuntimePreferences.notifyOnTranscriptionCompleteKey)
        let vm = makeViewModel()
        var captured: TranscriptionCompletionNotifier.Content?
        vm.onTranscriptionCompleted = { captured = $0 }

        let url = try touch("only.mp3")
        vm.transcribeFiles(urls: [url])
        try await waitUntil { !vm.isTranscribing }

        XCTAssertNil(captured, "No completion signal when the setting is off")
    }

    // MARK: - Unsupported drop

    func testNoSupportedFilesIsRejected() async throws {
        let vm = makeViewModel()
        let txt = try touch("notes.txt")
        let accepted = vm.transcribeFiles(urls: [txt])
        XCTAssertFalse(accepted)
        XCTAssertFalse(vm.isBatchActive)
        XCTAssertFalse(vm.isTranscribing)
        XCTAssertNotNil(vm.errorMessage)
    }
}
