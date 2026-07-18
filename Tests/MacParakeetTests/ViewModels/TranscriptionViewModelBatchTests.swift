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

    private func makeViewModel(audioTrackService: MockAudioTrackSelectionService) -> TranscriptionViewModel {
        let vm = TranscriptionViewModel(defaults: defaults)
        vm.configure(
            transcriptionService: mockService,
            transcriptionRepo: mockRepo,
            audioTrackService: audioTrackService
        )
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

    func testSingleAudioTrackContinuesWithoutShowingPicker() async throws {
        let url = try touch("only.mkv")
        let trackService = MockAudioTrackSelectionService(
            base: mockService,
            tracksByFileName: [
                "only.mkv": [AudioTrackDescriptor(ordinal: 0, streamIndex: 1)]
            ]
        )
        let vm = makeViewModel(audioTrackService: trackService)

        XCTAssertTrue(vm.transcribeFiles(urls: [url]))
        try await waitUntil { vm.currentTranscription != nil && !vm.isTranscribing }

        XCTAssertNil(vm.pendingAudioTrackSelection)
        let selectedOrdinals = await trackService.selectedOrdinals()
        XCTAssertEqual(selectedOrdinals, [])
    }

    func testMultipleAudioTracksWaitForSelectionBeforeTranscribing() async throws {
        let url = try touch("episode.mkv")
        let trackService = MockAudioTrackSelectionService(
            base: mockService,
            tracksByFileName: [
                "episode.mkv": [
                    AudioTrackDescriptor(ordinal: 0, streamIndex: 1, languageCode: "jpn", isDefault: true),
                    AudioTrackDescriptor(ordinal: 1, streamIndex: 2, languageCode: "eng"),
                ]
            ]
        )
        let vm = makeViewModel(audioTrackService: trackService)

        XCTAssertTrue(vm.transcribeFiles(urls: [url]))
        try await waitUntil { vm.pendingAudioTrackSelection != nil }

        XCTAssertFalse(vm.isTranscribing)
        let callsBeforeSelection = await mockService.transcribeCallCount
        XCTAssertEqual(callsBeforeSelection, 0)
        XCTAssertEqual(vm.pendingAudioTrackSelection?.tracks.count, 2)

        vm.selectAudioTrack(ordinal: 1)
        try await waitUntil { vm.currentTranscription != nil && !vm.isTranscribing }

        let selectedOrdinals = await trackService.selectedOrdinals()
        XCTAssertEqual(selectedOrdinals, [1])
    }

    func testCancellingAudioTrackSelectionStartsNothing() async throws {
        let url = try touch("episode.mkv")
        let tracks = [
            AudioTrackDescriptor(ordinal: 0, streamIndex: 1),
            AudioTrackDescriptor(ordinal: 1, streamIndex: 2),
        ]
        let trackService = MockAudioTrackSelectionService(
            base: mockService,
            tracksByFileName: ["episode.mkv": tracks]
        )
        let vm = makeViewModel(audioTrackService: trackService)

        XCTAssertTrue(vm.transcribeFiles(urls: [url]))
        try await waitUntil { vm.pendingAudioTrackSelection != nil }

        vm.cancelAudioTrackSelection()

        XCTAssertNil(vm.pendingAudioTrackSelection)
        XCTAssertNil(vm.currentTranscription)
        let callCount = await mockService.transcribeCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testURLTranscriptionCannotReplaceAudioTrackPreflight() async throws {
        let url = try touch("episode.mkv")
        let tracks = [
            AudioTrackDescriptor(ordinal: 0, streamIndex: 1),
            AudioTrackDescriptor(ordinal: 1, streamIndex: 2),
        ]
        let trackService = MockAudioTrackSelectionService(
            base: mockService,
            tracksByFileName: ["episode.mkv": tracks],
            probeDelay: .milliseconds(100)
        )
        let vm = makeViewModel(audioTrackService: trackService)
        vm.urlInput = "https://example.com/talk.mp4"

        XCTAssertTrue(vm.transcribeFiles(urls: [url]))
        XCTAssertTrue(vm.isInspectingAudioTracks)

        vm.transcribeURL()
        try await waitUntil { vm.pendingAudioTrackSelection != nil }

        let urlCallCount = await mockService.transcribeURLCallCount
        XCTAssertEqual(vm.urlInput, "https://example.com/talk.mp4")
        XCTAssertFalse(vm.isInspectingAudioTracks)
        XCTAssertEqual(urlCallCount, 0)
        XCTAssertEqual(vm.pendingAudioTrackSelection?.tracks, tracks)
    }

    func testBatchUsesOneSelectedAudioTrackOrdinalForEveryMultiTrackFile() async throws {
        let urls = [try touch("c.mkv"), try touch("a.mkv"), try touch("b.mkv")]
        let tracks = [
            AudioTrackDescriptor(ordinal: 0, streamIndex: 1, languageCode: "jpn", isDefault: true),
            AudioTrackDescriptor(ordinal: 1, streamIndex: 2, languageCode: "eng"),
        ]
        let trackService = MockAudioTrackSelectionService(
            base: mockService,
            tracksByFileName: ["a.mkv": tracks, "b.mkv": tracks, "c.mkv": tracks]
        )
        let vm = makeViewModel(audioTrackService: trackService)

        XCTAssertTrue(vm.transcribeFiles(urls: urls))
        try await waitUntil { vm.pendingAudioTrackSelection != nil }
        XCTAssertEqual(vm.pendingAudioTrackSelection?.fileCount, 3)

        vm.selectAudioTrack(ordinal: 1)
        try await waitUntil { !vm.isBatchActive && !vm.isTranscribing }

        let selectedOrdinals = await trackService.selectedOrdinals()
        let transcribedFileNames = await mockService.transcribedFileNames
        XCTAssertEqual(selectedOrdinals, [1, 1, 1])
        XCTAssertEqual(transcribedFileNames, ["a.mkv", "b.mkv", "c.mkv"])
    }

    func testBatchLeavesSingleTrackFilesOnAutomaticSelection() async throws {
        let urls = [try touch("a.mkv"), try touch("b.mkv"), try touch("c.mkv")]
        let multiTracks = [
            AudioTrackDescriptor(ordinal: 0, streamIndex: 1),
            AudioTrackDescriptor(ordinal: 1, streamIndex: 2),
        ]
        let trackService = MockAudioTrackSelectionService(
            base: mockService,
            tracksByFileName: [
                "a.mkv": multiTracks,
                "b.mkv": [AudioTrackDescriptor(ordinal: 0, streamIndex: 1)],
                "c.mkv": multiTracks,
            ]
        )
        let vm = makeViewModel(audioTrackService: trackService)

        XCTAssertTrue(vm.transcribeFiles(urls: urls))
        try await waitUntil { vm.pendingAudioTrackSelection != nil }

        vm.selectAudioTrack(ordinal: 1)
        try await waitUntil { !vm.isBatchActive && !vm.isTranscribing }

        let selectedOrdinals = await trackService.selectedOrdinals()
        let transcribedFileNames = await mockService.transcribedFileNames
        XCTAssertEqual(selectedOrdinals, [1, 1])
        XCTAssertEqual(transcribedFileNames, ["a.mkv", "b.mkv", "c.mkv"])
    }

    func testBatchContinuesWhenLaterMultiTrackFileLacksSelectedOrdinal() async throws {
        let urls = [try touch("a.mkv"), try touch("b.mkv"), try touch("c.mkv")]
        let threeTracks = (0...2).map { AudioTrackDescriptor(ordinal: $0, streamIndex: $0 + 1) }
        let twoTracks = (0...1).map { AudioTrackDescriptor(ordinal: $0, streamIndex: $0 + 1) }
        let trackService = MockAudioTrackSelectionService(
            base: mockService,
            tracksByFileName: ["a.mkv": threeTracks, "b.mkv": twoTracks, "c.mkv": threeTracks]
        )
        let vm = makeViewModel(audioTrackService: trackService)
        var captured: TranscriptionCompletionNotifier.Content?
        vm.onTranscriptionCompleted = { captured = $0 }

        XCTAssertTrue(vm.transcribeFiles(urls: urls))
        try await waitUntil { vm.pendingAudioTrackSelection != nil }

        vm.selectAudioTrack(ordinal: 2)
        try await waitUntil { !vm.isBatchActive && !vm.isTranscribing }

        let selectedOrdinals = await trackService.selectedOrdinals()
        let transcribedFileNames = await mockService.transcribedFileNames
        XCTAssertEqual(selectedOrdinals, [2, 2, 2])
        XCTAssertEqual(transcribedFileNames, ["a.mkv", "c.mkv"])
        XCTAssertEqual(captured?.body, "2 transcribed \u{00B7} 1 failed")
    }

    func testBatchContinuesWhenOneFileFailsAudioTrackDiscovery() async throws {
        let urls = [try touch("a.mkv"), try touch("b.mkv"), try touch("c.mkv")]
        let tracks = [
            AudioTrackDescriptor(ordinal: 0, streamIndex: 1),
            AudioTrackDescriptor(ordinal: 1, streamIndex: 2),
        ]
        let trackService = MockAudioTrackSelectionService(
            base: mockService,
            tracksByFileName: ["a.mkv": tracks, "c.mkv": tracks],
            probeFailureFileNames: ["b.mkv"]
        )
        let vm = makeViewModel(audioTrackService: trackService)
        var captured: TranscriptionCompletionNotifier.Content?
        vm.onTranscriptionCompleted = { captured = $0 }

        XCTAssertTrue(vm.transcribeFiles(urls: urls))
        try await waitUntil { vm.pendingAudioTrackSelection != nil }

        vm.selectAudioTrack(ordinal: 1)
        try await waitUntil { !vm.isBatchActive && !vm.isTranscribing }

        let selectedOrdinals = await trackService.selectedOrdinals()
        let transcribedFileNames = await mockService.transcribedFileNames
        XCTAssertEqual(selectedOrdinals, [1, 1])
        XCTAssertEqual(transcribedFileNames, ["a.mkv", "c.mkv"])
        XCTAssertEqual(captured?.body, "2 transcribed \u{00B7} 1 failed")
        XCTAssertNil(vm.errorMessage)
    }

    func testFileWithoutAudioTrackFailsBeforeTranscription() async throws {
        let url = try touch("silent.mkv")
        let trackService = MockAudioTrackSelectionService(
            base: mockService,
            tracksByFileName: ["silent.mkv": []]
        )
        let vm = makeViewModel(audioTrackService: trackService)

        XCTAssertTrue(vm.transcribeFiles(urls: [url]))
        try await waitUntil { vm.errorMessage != nil }

        XCTAssertTrue(vm.errorMessage?.contains("No audio tracks") == true)
        let callCount = await mockService.transcribeCallCount
        XCTAssertEqual(callCount, 0)
        XCTAssertNil(vm.pendingAudioTrackSelection)
    }

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

private actor MockAudioTrackSelectionService: AudioTrackSelectingTranscriptionService {
    private let base: MockTranscriptionService
    private let tracksByFileName: [String: [AudioTrackDescriptor]]
    private let probeFailureFileNames: Set<String>
    private let probeDelay: Duration?
    private var ordinals: [Int] = []

    init(
        base: MockTranscriptionService,
        tracksByFileName: [String: [AudioTrackDescriptor]],
        probeFailureFileNames: Set<String> = [],
        probeDelay: Duration? = nil
    ) {
        self.base = base
        self.tracksByFileName = tracksByFileName
        self.probeFailureFileNames = probeFailureFileNames
        self.probeDelay = probeDelay
    }

    func audioTracks(in fileURL: URL) async throws -> [AudioTrackDescriptor] {
        if let probeDelay {
            try await Task.sleep(for: probeDelay)
        }
        if probeFailureFileNames.contains(fileURL.lastPathComponent) {
            throw AudioProcessorError.conversionFailed("Audio-track discovery failed.")
        }
        return tracksByFileName[fileURL.lastPathComponent]
            ?? [AudioTrackDescriptor(ordinal: 0, streamIndex: 0)]
    }

    func transcribe(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        audioTrackOrdinal: Int,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        ordinals.append(audioTrackOrdinal)
        guard tracksByFileName[fileURL.lastPathComponent]?.contains(where: {
            $0.ordinal == audioTrackOrdinal
        }) == true else {
            throw AudioProcessorError.conversionFailed(
                "Audio track \(audioTrackOrdinal + 1) is unavailable."
            )
        }
        return try await base.transcribe(fileURL: fileURL, source: source, onProgress: onProgress)
    }

    func transcribeTransient(
        fileURL: URL,
        source: TelemetryTranscriptionSource,
        audioTrackOrdinal: Int,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> Transcription {
        try await transcribe(
            fileURL: fileURL,
            source: source,
            audioTrackOrdinal: audioTrackOrdinal,
            onProgress: onProgress
        )
    }

    func selectedOrdinals() -> [Int] { ordinals }
}
