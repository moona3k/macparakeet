import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class DictationFlowCoordinatorLoadCaptionTests: XCTestCase {
    private let timing = DictationProcessingLoadCaptionTiming(
        graceMs: 20,
        escalationMs: 50,
        failureDisplayMs: 40
    )

    override func tearDown() {
        Telemetry.configure(NoOpTelemetryService())
        super.tearDown()
    }

    func testModelReadyAtProcessingEntryNeverShowsCaption() async throws {
        let harness = try makeHarness(isReady: true, transcribeDelayMs: 90)

        try await harness.startAndStop()
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertNil(harness.coordinator.processingLoadCaptionForTesting)
        XCTAssertFalse(harness.telemetry.snapshot().containsCaptionShown)
    }

    func testProcessingExitBeforeGraceSuppressesCaption() async throws {
        let harness = try makeHarness(
            isReady: false,
            transcribeDelayMs: 5,
            timing: DictationProcessingLoadCaptionTiming(
                graceMs: 700,
                escalationMs: 1000,
                failureDisplayMs: 40
            )
        )

        try await harness.startAndStop()
        try await Task.sleep(for: .milliseconds(620))

        XCTAssertNil(harness.coordinator.processingLoadCaptionForTesting)
        XCTAssertFalse(harness.telemetry.snapshot().containsCaptionShown)
    }

    func testRuntimeReadyBeforeGraceSuppressesCaption() async throws {
        let harness = try makeHarness(
            isReady: false,
            transcribeDelayMs: 140,
            timing: DictationProcessingLoadCaptionTiming(
                graceMs: 80,
                escalationMs: 160,
                failureDisplayMs: 40
            )
        )

        harness.coordinator.startDictation(mode: .persistent, trigger: .hotkey)
        let started = await waitUntil { harness.coordinator.overlayStateForTesting?.isRecordingForTest == true }
        XCTAssertTrue(started)
        harness.coordinator.stopDictation()
        let processing = await waitUntil { harness.coordinator.overlayStateForTesting?.isProcessingForTest == true }
        XCTAssertTrue(processing)

        await harness.stt.setReady(true)
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertNil(harness.coordinator.processingLoadCaptionForTesting)
        XCTAssertFalse(harness.telemetry.snapshot().containsCaptionShown)
    }

    func testFirstInstallShowsPreparingThenClearsOnSuccess() async throws {
        let harness = try makeHarness(isReady: false, transcribeDelayMs: 90, hasCompletedFirstDictation: false)

        try await harness.startAndStop()
        let shown = await waitUntil { self.isPreparingCaption(harness.coordinator.processingLoadCaptionForTesting) }
        XCTAssertTrue(shown)
        let cleared = await waitUntil { harness.coordinator.processingLoadCaptionForTesting == nil }
        XCTAssertTrue(cleared)

        let events = harness.telemetry.snapshot()
        XCTAssertTrue(events.containsCaptionShown(firstInstall: true))
        XCTAssertTrue(events.containsCaptionDuration(outcome: "success"))
    }

    func testFirstInstallEscalatesToSubcopyAfterDelay() async throws {
        let harness = try makeHarness(isReady: false, transcribeDelayMs: 140, hasCompletedFirstDictation: false)

        try await harness.startAndStop()

        let escalated = await waitUntil { harness.coordinator.processingLoadCaptionForTesting == .preparingExtended }
        XCTAssertTrue(escalated)
    }

    func testSubsequentColdLaunchDoesNotEscalate() async throws {
        let harness = try makeHarness(isReady: false, transcribeDelayMs: 140, hasCompletedFirstDictation: true)

        try await harness.startAndStop()
        let shown = await waitUntil { self.isPreparingCaption(harness.coordinator.processingLoadCaptionForTesting) }
        XCTAssertTrue(shown)
        try await Task.sleep(for: .milliseconds(70))

        XCTAssertEqual(harness.coordinator.processingLoadCaptionForTesting, .preparing)
        XCTAssertTrue(harness.telemetry.snapshot().containsCaptionShown(firstInstall: false))
    }

    func testFailureShowsFailureCaptionBeforeErrorCard() async throws {
        let harness = try makeHarness(
            isReady: false,
            transcribeDelayMs: 60,
            transcribeError: STTError.engineStartFailed("load failed")
        )

        try await harness.startAndStop()
        let failedCaptionShown = await waitUntil { harness.coordinator.processingLoadCaptionForTesting == .failed }
        XCTAssertTrue(failedCaptionShown)
        XCTAssertTrue(harness.coordinator.overlayStateForTesting?.isProcessingForTest == true)

        let errorShown = await waitUntil { harness.coordinator.overlayStateForTesting?.isErrorForTest == true }
        XCTAssertTrue(errorShown)
        XCTAssertNil(harness.coordinator.processingLoadCaptionForTesting)
        XCTAssertTrue(harness.telemetry.snapshot().containsCaptionDuration(outcome: "failure"))
    }

    func testNoSpeechDismissesCaptionWithSnakeCaseOutcome() async throws {
        let harness = try makeHarness(
            isReady: false,
            transcribeDelayMs: 140,
            transcribeError: DictationServiceError.emptyTranscript
        )

        try await harness.startAndStop()
        let shown = await waitUntil { self.isPreparingCaption(harness.coordinator.processingLoadCaptionForTesting) }
        XCTAssertTrue(shown)
        let cleared = await waitUntil { harness.coordinator.processingLoadCaptionForTesting == nil }
        XCTAssertTrue(cleared)

        XCTAssertTrue(harness.telemetry.snapshot().containsCaptionDuration(outcome: "no_speech"))
    }

    func testCancelDuringVisibleCaptionClearsCaption() async throws {
        let harness = try makeHarness(isReady: false, transcribeDelayMs: 2_000)

        try await harness.startAndStop()
        let shown = await waitUntil(timeoutMs: 3_000) {
            self.isPreparingCaption(harness.coordinator.processingLoadCaptionForTesting)
        }
        XCTAssertTrue(shown)

        harness.coordinator.cancelDictation(reason: .escape)
        let cleared = await waitUntil(timeoutMs: 3_000) {
            harness.coordinator.processingLoadCaptionForTesting == nil
        }
        XCTAssertTrue(cleared)
        XCTAssertTrue(harness.telemetry.snapshot().containsCaptionDuration(outcome: "cancelled"))
    }

    func testSecondDictationWarmRuntimeDoesNotShowCaption() async throws {
        let harness = try makeHarness(isReady: false, transcribeDelayMs: 80)

        try await harness.startAndStop()
        let firstShown = await waitUntil { self.isPreparingCaption(harness.coordinator.processingLoadCaptionForTesting) }
        XCTAssertTrue(firstShown)
        let firstCleared = await waitUntil { harness.coordinator.processingLoadCaptionForTesting == nil }
        XCTAssertTrue(firstCleared)
        let returnedToIdle = await waitUntil(timeoutMs: 2500) { harness.coordinator.overlayStateForTesting == nil }
        XCTAssertTrue(returnedToIdle)

        await harness.stt.setReady(true)
        await harness.stt.setTranscribeDelay(milliseconds: 80)
        try await harness.startAndStop()
        try await Task.sleep(for: .milliseconds(60))

        let shownCount = harness.telemetry.snapshot().captionShownCount
        XCTAssertEqual(shownCount, 1)
        XCTAssertNil(harness.coordinator.processingLoadCaptionForTesting)
    }

    func testKeepDictationOnClipboardPastesNormalPayloadWithoutRestore() async throws {
        let harness = try makeHarness(
            isReady: true,
            transcribeDelayMs: 5,
            keepDictationOnClipboard: true
        )

        try await harness.startAndStop()
        let pasted = await waitUntilAsync {
            await harness.clipboard.snapshot().lastPastedText != nil
        }
        let clipboard = await harness.clipboard.snapshot()

        XCTAssertTrue(pasted)
        XCTAssertEqual(clipboard.lastPastedText, "Mock transcription ")
        XCTAssertEqual(clipboard.lastRestoresClipboard, false)
        XCTAssertNil(clipboard.lastCopiedText)
    }

    func testKeepDictationOnClipboardDoesNotRetainWhitespaceForEmptyCleanTranscript() async throws {
        let harness = try makeHarness(
            isReady: true,
            transcribeDelayMs: 5,
            transcribeText: "um",
            keepDictationOnClipboard: true,
            processingMode: .clean
        )

        try await harness.startAndStop()
        let dismissed = await waitUntil(timeoutMs: 2_500) {
            harness.coordinator.overlayStateForTesting == nil
        }
        let clipboard = await harness.clipboard.snapshot()

        XCTAssertTrue(dismissed)
        XCTAssertNil(clipboard.lastPastedText)
        XCTAssertNil(clipboard.lastCopiedText)
        XCTAssertNil(clipboard.lastRestoresClipboard)
    }

    private func makeHarness(
        isReady: Bool,
        transcribeDelayMs: UInt64,
        transcribeText: String = "Mock transcription",
        transcribeError: Error? = nil,
        hasCompletedFirstDictation: Bool = false,
        keepDictationOnClipboard: Bool = false,
        processingMode: Dictation.ProcessingMode = .raw,
        timing: DictationProcessingLoadCaptionTiming? = nil
    ) throws -> Harness {
        let telemetry = LoadCaptionTelemetrySpy()
        Telemetry.configure(telemetry)

        let dbManager = try DatabaseManager()
        let audio = MockAudioProcessor()
        let stt = DelayedSTTClient(
            ready: isReady,
            transcribeDelayMs: transcribeDelayMs,
            transcribeText: transcribeText,
            transcribeError: transcribeError
        )
        let repo = DictationRepository(dbQueue: dbManager.dbQueue)
        let preferencesDefaults = UserDefaults(suiteName: "load-caption-\(UUID().uuidString)")!
        preferencesDefaults.set(keepDictationOnClipboard, forKey: UserDefaultsAppRuntimePreferences.keepDictationOnClipboardKey)
        let preferences = UserDefaultsAppRuntimePreferences(defaults: preferencesDefaults)
        if hasCompletedFirstDictation {
            preferences.markFirstDictationCompleted()
        }

        let service = DictationService(
            audioProcessor: audio,
            sttTranscriber: stt,
            dictationRepo: repo,
            processingMode: { processingMode },
            markFirstDictationCompleted: {
                preferences.markFirstDictationCompleted()
            }
        )

        let settingsDefaults = UserDefaults(suiteName: "load-caption-settings-\(UUID().uuidString)")!
        settingsDefaults.set(false, forKey: UserDefaultsAppRuntimePreferences.showIdlePillKey)
        let settings = SettingsViewModel(defaults: settingsDefaults)

        let entitlements = EntitlementsService(
            config: LicensingConfig(checkoutURL: nil, expectedVariantID: nil),
            store: InMemoryKeyValueStore(),
            api: StubLicenseAPI()
        )

        let clipboard = MockClipboardService()
        let coordinator = DictationFlowCoordinator(
            dictationService: service,
            clipboardService: clipboard,
            entitlementsService: entitlements,
            dictationRepo: repo,
            settingsViewModel: settings,
            sttRuntime: stt,
            runtimePreferences: preferences,
            captionTiming: timing ?? self.timing,
            overlayControllerFactory: { SpyDictationOverlayController(viewModel: $0) },
            onMenuBarIconUpdate: { _ in },
            onHistoryReload: {},
            onPresentEntitlementsAlert: { _ in }
        )

        return Harness(coordinator: coordinator, stt: stt, telemetry: telemetry, clipboard: clipboard)
    }

    private func waitUntil(
        timeoutMs: UInt64 = 1200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func waitUntilAsync(
        timeoutMs: UInt64 = 1200,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func isPreparingCaption(_ caption: DictationOverlayViewModel.ProcessingLoadCaption?) -> Bool {
        caption == .preparing || caption == .preparingExtended
    }

    private struct Harness {
        let coordinator: DictationFlowCoordinator
        let stt: DelayedSTTClient
        let telemetry: LoadCaptionTelemetrySpy
        let clipboard: MockClipboardService

        @MainActor
        func startAndStop() async throws {
            coordinator.startDictation(mode: .persistent, trigger: .hotkey)
            let started = await waitUntil { coordinator.overlayStateForTesting?.isRecordingForTest == true }
            XCTAssertTrue(started)
            coordinator.stopDictation()
        }

        @MainActor
        private func waitUntil(
            timeoutMs: UInt64 = 1200,
            condition: @escaping @MainActor () -> Bool
        ) async -> Bool {
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return condition()
        }
    }
}

@MainActor
private final class SpyDictationOverlayController: DictationOverlayControlling {
    let viewModel: DictationOverlayViewModel
    private(set) var isShown = false

    init(viewModel: DictationOverlayViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        isShown = true
    }

    func hide() {
        isShown = false
    }

    func resignKeyWindow() {}
}

private actor DelayedSTTClient: STTClientProtocol, DictationSTTReadinessChecking {
    private var ready: Bool
    private var transcribeDelayMs: UInt64
    private var transcribeText: String
    private var transcribeError: Error?

    init(ready: Bool, transcribeDelayMs: UInt64, transcribeText: String, transcribeError: Error?) {
        self.ready = ready
        self.transcribeDelayMs = transcribeDelayMs
        self.transcribeText = transcribeText
        self.transcribeError = transcribeError
    }

    func setReady(_ ready: Bool) {
        self.ready = ready
    }

    func setTranscribeDelay(milliseconds: UInt64) {
        transcribeDelayMs = milliseconds
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        if transcribeDelayMs > 0 {
            try await Task.sleep(for: .milliseconds(Int(transcribeDelayMs)))
        }
        if let transcribeError {
            throw transcribeError
        }
        let words = transcribeText.split(whereSeparator: \.isWhitespace).enumerated().map { index, word in
            TimestampedWord(
                word: String(word),
                startMs: index * 320,
                endMs: index * 320 + 300,
                confidence: 0.99
            )
        }
        return STTResult(
            text: transcribeText,
            words: words
        )
    }

    func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        ready = true
    }

    func backgroundWarmUp() async {
        ready = true
    }

    func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let id = UUID()
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(ready ? .ready : .idle)
            continuation.finish()
        }
        return (id, stream)
    }

    func removeWarmUpObserver(id: UUID) async {}

    func isReady() async -> Bool {
        ready
    }

    func clearModelCache() async {
        ready = false
    }

    func shutdown() async {}
}

private final class LoadCaptionTelemetrySpy: TelemetryServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TelemetryEventSpec] = []

    func send(_ event: TelemetryEventSpec) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func sendAndFlush(_ event: TelemetryEventSpec) async -> Bool {
        send(event)
        return true
    }

    func flush() async {}
    func clearQueue() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }
    func flushForTermination() {}

    func snapshot() -> [TelemetryEventSpec] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private extension Array where Element == TelemetryEventSpec {
    var containsCaptionShown: Bool {
        contains { event in
            if case .dictationFirstLoadCaptionShown = event { return true }
            return false
        }
    }

    var captionShownCount: Int {
        filter { event in
            if case .dictationFirstLoadCaptionShown = event { return true }
            return false
        }.count
    }

    func containsCaptionShown(firstInstall: Bool) -> Bool {
        contains { event in
            guard case .dictationFirstLoadCaptionShown(let value) = event else { return false }
            return value == firstInstall
        }
    }

    func containsCaptionDuration(outcome: String) -> Bool {
        contains { event in
            guard case .dictationFirstLoadCaptionDuration(let durationMs, let value) = event else {
                return false
            }
            return durationMs >= 0 && value == outcome
        }
    }
}

private extension DictationOverlayViewModel.OverlayState {
    var isRecordingForTest: Bool {
        if case .recording = self { return true }
        return false
    }

    var isProcessingForTest: Bool {
        if case .processing = self { return true }
        return false
    }

    var isErrorForTest: Bool {
        if case .error = self { return true }
        return false
    }
}
