import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class EngineSettingsViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        defaultsSuiteName = "test.enginesettings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        Telemetry.configure(NoOpTelemetryService())
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
    }

    private func makeViewModel(
        parakeetCached: @escaping @Sendable (ParakeetModelVariant) -> Bool = { _ in false },
        nemotronCached: @escaping @Sendable (NemotronModelVariant, String?) -> Bool = { _, _ in false },
        cohereCached: @escaping @Sendable () -> Bool = { false },
        cohereCacheDirectoryExists: @escaping @Sendable () -> Bool = { false },
        deleteParakeet: @escaping @Sendable (ParakeetModelVariant) -> Bool = { _ in false },
        deleteNemotron: @escaping @Sendable (NemotronModelVariant, String?) -> Bool = { _, _ in false },
        deleteWhisper: @escaping @Sendable (String) -> Bool = { _ in false },
        deleteCohere: @escaping @Sendable () -> Bool = { false }
    ) -> EngineSettingsViewModel {
        EngineSettingsViewModel(
            defaults: defaults,
            parakeetModelVariantCached: parakeetCached,
            nemotronModelVariantCached: nemotronCached,
            cohereModelCached: cohereCached,
            cohereModelCacheDirectoryExists: cohereCacheDirectoryExists,
            deleteParakeetModelOnDisk: deleteParakeet,
            deleteNemotronModelOnDisk: deleteNemotron,
            deleteWhisperModelOnDisk: deleteWhisper,
            deleteCohereModelOnDisk: deleteCohere
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(10),
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
            try await Task.sleep(for: pollInterval)
        }
    }

    private func waitForModelStatusRefreshToFinish(
        _ vm: EngineSettingsViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitUntil(file: file, line: line) {
            vm.nemotronModelStatus != .checking &&
                vm.whisperModelStatus != .checking &&
                vm.cohereModelStatus != .checking
        }
    }

    func testSelectionDefaultsReadFromSpeechEnginePreferenceHelpers() {
        let vm = makeViewModel()

        XCTAssertEqual(vm.speechEnginePreference, SpeechEnginePreference.current(defaults: defaults))
        XCTAssertEqual(vm.parakeetModelVariant, SpeechEnginePreference.parakeetModelVariant(defaults: defaults))
        XCTAssertEqual(vm.nemotronModelVariant, SpeechEnginePreference.nemotronModelVariant(defaults: defaults))
        XCTAssertEqual(vm.whisperDefaultLanguage, SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults) ?? "auto")
        XCTAssertEqual(vm.whisperDefaultLanguage, "auto")
        XCTAssertEqual(vm.cohereComputePolicy, CohereTranscribeEngine.ComputePolicy.current(defaults: defaults))
        XCTAssertEqual(vm.cohereComputePolicy, .ane)
    }

    func testSetSpeechEnginePreferencePersistsWhenTargetModelIsMarkedDownloaded() {
        let vm = makeViewModel()
        vm.whisperModelStatus = .notLoaded

        vm.speechEnginePreference = .whisper

        let reloaded = makeViewModel()
        XCTAssertEqual(reloaded.speechEnginePreference, .whisper)
        XCTAssertEqual(SpeechEnginePreference.current(defaults: defaults), .whisper)
        XCTAssertNil(vm.speechEngineError)
    }

    func testSetParakeetModelVariantPersists() {
        let vm = makeViewModel()

        vm.parakeetModelVariant = .v2

        let reloaded = makeViewModel()
        XCTAssertEqual(reloaded.parakeetModelVariant, .v2)
        XCTAssertEqual(SpeechEnginePreference.parakeetModelVariant(defaults: defaults), .v2)
    }

    func testSetNemotronModelVariantPersists() {
        let vm = makeViewModel()

        vm.nemotronModelVariant = .english1120

        let reloaded = makeViewModel()
        XCTAssertEqual(reloaded.nemotronModelVariant, .english1120)
        XCTAssertEqual(SpeechEnginePreference.nemotronModelVariant(defaults: defaults), .english1120)
    }

    func testSetWhisperDefaultLanguagePersistsNormalizedValue() {
        let vm = makeViewModel()

        vm.whisperDefaultLanguage = "KO_kr"

        let reloaded = makeViewModel()
        XCTAssertEqual(reloaded.whisperDefaultLanguage, "ko")
        XCTAssertEqual(SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults), "ko")
    }

    func testSetCohereComputePolicyPersists() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.cohereComputePolicy, .ane)

        vm.cohereComputePolicy = .gpu

        let reloaded = makeViewModel()
        XCTAssertEqual(reloaded.cohereComputePolicy, .gpu)
        XCTAssertEqual(CohereTranscribeEngine.ComputePolicy.current(defaults: defaults), .gpu)
    }

    func testCohereComputePolicyNeedsRelaunchTracksDivergenceFromLaunchValue() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.cohereComputePolicyNeedsRelaunch)

        vm.cohereComputePolicy = .gpu
        XCTAssertTrue(vm.cohereComputePolicyNeedsRelaunch)

        // Flipping back to the launch value clears the pending state — the
        // running engine already matches, so no relaunch is needed.
        vm.cohereComputePolicy = .ane
        XCTAssertFalse(vm.cohereComputePolicyNeedsRelaunch)
    }

    func testRequestConfirmationSetsPendingAndClearsExistingError() {
        let vm = makeViewModel()
        vm.speechEngineError = "previous error"

        vm.requestSpeechEngineSwitchConfirmation(to: .whisper)

        XCTAssertEqual(vm.pendingSpeechEngineSwitchConfirmation, .whisper)
        XCTAssertNil(vm.speechEngineError)
    }

    func testRequestConfirmationIgnoresCurrentEngine() {
        let vm = makeViewModel()

        vm.requestSpeechEngineSwitchConfirmation(to: .parakeet)

        XCTAssertNil(vm.pendingSpeechEngineSwitchConfirmation)
    }

    func testCancelPendingConfirmationClearsPending() {
        let vm = makeViewModel()
        vm.requestSpeechEngineSwitchConfirmation(to: .whisper)

        vm.cancelPendingSpeechEngineSwitchConfirmation()

        XCTAssertNil(vm.pendingSpeechEngineSwitchConfirmation)
    }

    func testConfirmPendingSwitchClearsPendingAndPersistsWhenTargetModelIsMarkedDownloaded() {
        let vm = makeViewModel()
        vm.whisperModelStatus = .notLoaded
        vm.requestSpeechEngineSwitchConfirmation(to: .whisper)

        vm.confirmPendingSpeechEngineSwitch()

        XCTAssertNil(vm.pendingSpeechEngineSwitchConfirmation)
        XCTAssertEqual(vm.speechEnginePreference, .whisper)
        XCTAssertEqual(SpeechEnginePreference.current(defaults: defaults), .whisper)
        XCTAssertNil(vm.speechEngineError)
        XCTAssertFalse(vm.speechEngineSwitching)
        XCTAssertNil(vm.speechEngineSwitchTarget)
    }

    func testConfirmPendingSwitchClearsPendingAndRestoresCurrentEngineWhenTargetModelIsMissing() {
        let vm = makeViewModel()
        vm.requestSpeechEngineSwitchConfirmation(to: .whisper)

        vm.confirmPendingSpeechEngineSwitch()

        XCTAssertNil(vm.pendingSpeechEngineSwitchConfirmation)
        XCTAssertEqual(vm.speechEnginePreference, .parakeet)
        XCTAssertEqual(SpeechEnginePreference.current(defaults: defaults), .parakeet)
        XCTAssertEqual(vm.speechEngineError, "Download the Whisper model before switching engines.")
        XCTAssertFalse(vm.speechEngineSwitching)
        XCTAssertNil(vm.speechEngineSwitchTarget)
    }

    func testConfirmPendingSwitchClearsPendingAndPersistsWhenCohereIsMarkedDownloaded() {
        let vm = makeViewModel()
        vm.cohereModelStatus = .notLoaded
        vm.requestSpeechEngineSwitchConfirmation(to: .cohere)

        vm.confirmPendingSpeechEngineSwitch()

        XCTAssertNil(vm.pendingSpeechEngineSwitchConfirmation)
        XCTAssertEqual(vm.speechEnginePreference, .cohere)
        XCTAssertEqual(SpeechEnginePreference.current(defaults: defaults), .cohere)
        XCTAssertNil(vm.speechEngineError)
        XCTAssertFalse(vm.speechEngineSwitching)
        XCTAssertNil(vm.speechEngineSwitchTarget)
    }

    func testConfirmPendingSwitchAllowsCohereWhileModelStatusCheckIsInFlight() {
        let vm = makeViewModel(cohereCached: { true })
        vm.cohereModelStatus = .checking
        vm.requestSpeechEngineSwitchConfirmation(to: .cohere)

        vm.confirmPendingSpeechEngineSwitch()

        XCTAssertNil(vm.pendingSpeechEngineSwitchConfirmation)
        XCTAssertEqual(vm.speechEnginePreference, .cohere)
        XCTAssertEqual(SpeechEnginePreference.current(defaults: defaults), .cohere)
        XCTAssertNil(vm.speechEngineError)
    }

    func testConfirmPendingSwitchBlocksCohereWhileModelDeleteIsInFlight() {
        let vm = makeViewModel(cohereCached: { true })
        vm.cohereModelStatus = .notLoaded
        vm.cohereDeleting = true
        vm.requestSpeechEngineSwitchConfirmation(to: .cohere)

        vm.confirmPendingSpeechEngineSwitch()

        XCTAssertNil(vm.pendingSpeechEngineSwitchConfirmation)
        XCTAssertEqual(vm.speechEnginePreference, .parakeet)
        XCTAssertEqual(SpeechEnginePreference.current(defaults: defaults), .parakeet)
        XCTAssertEqual(vm.speechEngineError, "Finish deleting Cohere Transcribe before switching engines.")
    }

    func testConfirmPendingSwitchBlocksCohereWhileModelStatusCheckIsInFlightAndCacheMissing() {
        let vm = makeViewModel(cohereCached: { false })
        vm.cohereModelStatus = .checking
        vm.requestSpeechEngineSwitchConfirmation(to: .cohere)

        vm.confirmPendingSpeechEngineSwitch()

        XCTAssertNil(vm.pendingSpeechEngineSwitchConfirmation)
        XCTAssertEqual(vm.speechEnginePreference, .parakeet)
        XCTAssertEqual(SpeechEnginePreference.current(defaults: defaults), .parakeet)
        XCTAssertEqual(vm.speechEngineError, "Download Cohere Transcribe before switching engines.")
    }

    func testConfirmPendingSwitchClearsPendingAndRestoresCurrentEngineWhenCohereModelIsMissing() {
        let vm = makeViewModel()
        vm.cohereModelStatus = .notDownloaded
        vm.requestSpeechEngineSwitchConfirmation(to: .cohere)

        vm.confirmPendingSpeechEngineSwitch()

        XCTAssertNil(vm.pendingSpeechEngineSwitchConfirmation)
        XCTAssertEqual(vm.speechEnginePreference, .parakeet)
        XCTAssertEqual(SpeechEnginePreference.current(defaults: defaults), .parakeet)
        XCTAssertEqual(vm.speechEngineError, "Download Cohere Transcribe before switching engines.")
        XCTAssertFalse(vm.speechEngineSwitching)
        XCTAssertNil(vm.speechEngineSwitchTarget)
    }

    func testSwitchUnavailableMessageReturnsNilWhenAvailable() {
        XCTAssertNil(EngineSettingsViewModel.speechEngineSwitchUnavailableMessage(for: .available))
    }

    func testSwitchUnavailableMessagePinsCurrentCopyForUnavailableStates() {
        let cases: [(SpeechEngineSwitchAvailability, String)] = [
            (.meetingActive, "Stop the meeting recording to switch engines"),
            (.transcribing, "Finishing transcription — switch when it completes"),
            (.switchInProgress, "Finishing engine switch — try again in a moment"),
            (.unavailable, "Speech engine is temporarily unavailable"),
        ]

        for (availability, message) in cases {
            XCTAssertEqual(
                EngineSettingsViewModel.speechEngineSwitchUnavailableMessage(for: availability),
                message
            )
        }
    }

    func testInstanceSwitchUnavailableMessageReflectsStoredAvailability() {
        let vm = makeViewModel()

        vm.speechEngineSwitchAvailability = .switchInProgress

        XCTAssertEqual(
            vm.speechEngineSwitchUnavailableMessage,
            "Finishing engine switch — try again in a moment"
        )
    }

    func testDownloadedParakeetVariantsReflectsTrueCachedStub() async throws {
        let vm = makeViewModel(parakeetCached: { _ in true })

        vm.refreshModelStatus()

        try await waitUntil { vm.downloadedParakeetVariants == Set(ParakeetModelVariant.allCases) }
        XCTAssertEqual(vm.downloadedParakeetVariants, Set(ParakeetModelVariant.allCases))
        XCTAssertEqual(vm.parakeetStatus, .unknown)
        XCTAssertEqual(vm.parakeetStatusDetail, "Unavailable in this runtime.")
    }

    func testDownloadedParakeetVariantsReflectsFalseCachedStub() async throws {
        let vm = makeViewModel(parakeetCached: { _ in false })

        vm.refreshModelStatus()

        try await waitForModelStatusRefreshToFinish(vm)
        XCTAssertTrue(vm.downloadedParakeetVariants.isEmpty)
        XCTAssertEqual(vm.parakeetStatus, .unknown)
        XCTAssertEqual(vm.parakeetStatusDetail, "Unavailable in this runtime.")
    }

    func testDownloadedNemotronVariantsReflectsTrueCachedStubAndMarksSelectedVariantAvailable() async throws {
        let vm = makeViewModel(nemotronCached: { _, _ in true })

        vm.refreshModelStatus()

        try await waitUntil { vm.downloadedNemotronVariants == Set(NemotronModelVariant.allCases) }
        XCTAssertEqual(vm.downloadedNemotronVariants, Set(NemotronModelVariant.allCases))
        XCTAssertTrue(vm.isNemotronModelAvailable)
        XCTAssertEqual(vm.nemotronModelStatus, .notLoaded)
        XCTAssertEqual(
            vm.nemotronModelStatusDetail,
            "Nemotron 3.5 ASR Streaming 0.6B · Installed locally, loads when selected."
        )
    }

    func testDownloadedNemotronVariantsReflectsFalseCachedStubAndMarksSelectedVariantUnavailable() async throws {
        let vm = makeViewModel(nemotronCached: { _, _ in false })

        vm.refreshModelStatus()

        try await waitForModelStatusRefreshToFinish(vm)
        XCTAssertTrue(vm.downloadedNemotronVariants.isEmpty)
        XCTAssertFalse(vm.isNemotronModelAvailable)
        XCTAssertEqual(vm.nemotronModelStatus, .notDownloaded)
        XCTAssertEqual(
            vm.nemotronModelStatusDetail,
            "Nemotron 3.5 ASR Streaming 0.6B · Needs download before use."
        )
    }

    func testCohereCacheStatusMarksDownloadedModelInstalledWhenInactive() async throws {
        let vm = makeViewModel(cohereCached: { true })

        vm.refreshModelStatus()

        try await waitForModelStatusRefreshToFinish(vm)
        XCTAssertTrue(vm.isCohereModelDownloaded)
        XCTAssertEqual(vm.cohereModelStatus, .notLoaded)
        XCTAssertEqual(
            vm.cohereModelStatusDetail,
            "Cohere Transcribe · Installed locally, loads when selected."
        )
    }

    func testCohereCacheStatusMarksMissingModelNotDownloaded() async throws {
        let vm = makeViewModel(cohereCached: { false })

        vm.refreshModelStatus()

        try await waitForModelStatusRefreshToFinish(vm)
        XCTAssertFalse(vm.isCohereModelDownloaded)
        XCTAssertEqual(vm.cohereModelStatus, .notDownloaded)
        XCTAssertEqual(
            vm.cohereModelStatusDetail,
            "Cohere Transcribe · Needs download before use."
        )
    }

    func testCoherePartialCacheRemainsNotDownloadedButCanBeDeleted() async throws {
        let vm = makeViewModel(
            cohereCached: { false },
            cohereCacheDirectoryExists: { true }
        )

        vm.refreshModelStatus()

        try await waitForModelStatusRefreshToFinish(vm)
        XCTAssertFalse(vm.isCohereModelDownloaded)
        XCTAssertEqual(vm.cohereModelStatus, .notDownloaded)
        XCTAssertTrue(vm.cohereCacheDirectoryExists)
        XCTAssertTrue(vm.canDeleteCohereModel)
    }

    func testRefreshModelStatusPreservesCohereDownloadState() async throws {
        let recorder = CohereDiskStateRecorder(cached: false, cacheDirectoryExists: true)
        let vm = makeViewModel(
            cohereCached: { recorder.isCached() },
            cohereCacheDirectoryExists: { recorder.cacheDirectoryExists() }
        )
        vm.configure(sttClient: MockSTTClient())
        vm.cohereDownloading = true
        vm.cohereModelStatus = .repairing
        vm.cohereModelStatusDetail = "Downloading Cohere Transcribe..."
        vm.cohereCacheDirectoryExists = false

        vm.refreshModelStatus()

        try await waitForModelStatusRefreshToFinish(vm)
        XCTAssertTrue(recorder.didCheckCohere)
        XCTAssertEqual(vm.cohereModelStatus, .repairing)
        XCTAssertEqual(vm.cohereModelStatusDetail, "Downloading Cohere Transcribe...")
        XCTAssertFalse(vm.cohereCacheDirectoryExists)
    }

    func testRefreshStartedDuringCohereDownloadDoesNotOverwriteFailureAfterDownloadEnds() async throws {
        let recorder = BlockingCohereDiskStateRecorder(cached: true, cacheDirectoryExists: true)
        let vm = makeViewModel(
            cohereCached: { recorder.isCached() },
            cohereCacheDirectoryExists: { recorder.cacheDirectoryExists() }
        )
        vm.configure(sttClient: MockSTTClient())
        vm.cohereDownloading = true
        vm.cohereModelStatus = .repairing
        vm.cohereModelStatusDetail = "Downloading Cohere Transcribe..."
        vm.cohereCacheDirectoryExists = false

        vm.refreshModelStatus()
        try await waitUntil { recorder.cacheCheckStarted }

        vm.cohereDownloading = false
        vm.cohereModelStatus = .failed
        vm.cohereModelStatusDetail = "Download failed"

        recorder.release()

        try await waitUntil { recorder.didCheckCohere && vm.parakeetStatus != .checking }
        XCTAssertEqual(vm.cohereModelStatus, .failed)
        XCTAssertEqual(vm.cohereModelStatusDetail, "Download failed")
        XCTAssertFalse(vm.cohereCacheDirectoryExists)
    }

    func testRefreshModelStatusPreservesCohereDeleteState() async throws {
        let recorder = CohereDiskStateRecorder(cached: true, cacheDirectoryExists: true)
        let vm = makeViewModel(
            cohereCached: { recorder.isCached() },
            cohereCacheDirectoryExists: { recorder.cacheDirectoryExists() }
        )
        vm.configure(sttClient: MockSTTClient())
        vm.cohereDeleting = true
        vm.cohereModelStatus = .notDownloaded
        vm.cohereModelStatusDetail = "Deleting Cohere Transcribe..."
        vm.cohereCacheDirectoryExists = false

        vm.refreshModelStatus()

        try await waitForModelStatusRefreshToFinish(vm)
        XCTAssertTrue(recorder.didCheckCohere)
        XCTAssertEqual(vm.cohereModelStatus, .notDownloaded)
        XCTAssertEqual(vm.cohereModelStatusDetail, "Deleting Cohere Transcribe...")
        XCTAssertFalse(vm.cohereCacheDirectoryExists)
    }

    func testActiveReadyCohereReportsLoadedInMemory() async throws {
        SpeechEnginePreference.cohere.save(to: defaults)
        let vm = makeViewModel(cohereCached: { true })
        let stt = MockSTTClient()
        await stt.setReady(true)
        vm.configure(sttClient: stt)

        vm.refreshModelStatus()

        try await waitUntil { vm.cohereModelStatus == .ready }
        XCTAssertEqual(vm.cohereModelStatusDetail, "Cohere Transcribe · Loaded in memory.")
    }

    func testDeleteCohereModelUsesInjectedDeleterAndRefreshesStatus() async throws {
        let recorder = CohereDeleteRecorder()
        let vm = makeViewModel(
            cohereCached: { recorder.isCached },
            deleteCohere: {
                recorder.delete()
                return true
            }
        )
        vm.cohereModelStatus = .notLoaded

        vm.deleteCohereModel()

        try await waitUntil { recorder.deleteCount == 1 && vm.cohereModelStatus == .notDownloaded }
        XCTAssertFalse(vm.isCohereModelDownloaded)
        XCTAssertEqual(vm.cohereModelStatusDetail, "Cohere Transcribe · Needs download before use.")
    }

    func testDeleteCohereModelAllowsFailedPartialDownloadCleanup() async throws {
        let recorder = CohereDeleteRecorder()
        let vm = makeViewModel(
            cohereCached: { false },
            cohereCacheDirectoryExists: { recorder.isCached },
            deleteCohere: {
                recorder.delete()
                return true
            }
        )
        vm.cohereModelStatus = .failed
        vm.cohereCacheDirectoryExists = true

        vm.deleteCohereModel()

        try await waitUntil { recorder.deleteCount == 1 && vm.cohereModelStatus == .notDownloaded }
        XCTAssertFalse(vm.canDeleteCohereModel)
        XCTAssertEqual(vm.cohereModelStatusDetail, "Cohere Transcribe · Needs download before use.")
    }

    func testDeleteCohereModelBlocksConcurrentDeleteAndDownloadUntilDiskWorkFinishes() async throws {
        let recorder = BlockingCohereDeleteRecorder()
        let vm = makeViewModel(
            cohereCached: { recorder.isCached },
            deleteCohere: {
                recorder.delete()
                return true
            }
        )
        vm.cohereModelStatus = .notLoaded

        vm.deleteCohereModel()
        try await waitUntil { recorder.deleteStarted && vm.cohereDeleting }

        vm.deleteCohereModel()
        vm.downloadCohereModel()

        XCTAssertEqual(recorder.deleteCount, 1)
        XCTAssertTrue(vm.cohereDeleting)
        XCTAssertFalse(vm.cohereDownloading)
        XCTAssertEqual(vm.cohereModelStatus, .notDownloaded)

        recorder.finishDelete()
        try await waitUntil { !vm.cohereDeleting && vm.cohereModelStatus == .notDownloaded }
        XCTAssertFalse(vm.canDeleteCohereModel)
    }

    func testRefreshModelStatusPassesStoredNemotronLanguageToCachedStub() async throws {
        SpeechEnginePreference.saveNemotronDefaultLanguage("en_US", defaults: defaults)
        let recorder = NemotronCacheCheckRecorder()
        let vm = makeViewModel(nemotronCached: { variant, language in
            recorder.record(variant, language)
            return variant == .english1120
        })

        vm.refreshModelStatus()

        try await waitUntil { vm.downloadedNemotronVariants == [.english1120] }
        XCTAssertEqual(vm.downloadedNemotronVariants, [.english1120])
        XCTAssertTrue(recorder.calls.contains { $0.variant == .multilingual1120 && $0.language == "en-US" })
        XCTAssertTrue(recorder.calls.contains { $0.variant == .english1120 && $0.language == "en-US" })
    }

    func testIsWhisperModelDownloadedReflectsPublicStatus() {
        let vm = makeViewModel()

        vm.whisperModelStatus = .notDownloaded
        XCTAssertFalse(vm.isWhisperModelDownloaded)

        vm.whisperModelStatus = .notLoaded
        XCTAssertTrue(vm.isWhisperModelDownloaded)

        vm.whisperModelStatus = .ready
        XCTAssertTrue(vm.isWhisperModelDownloaded)
    }

    func testIsCohereModelDownloadedReflectsPublicStatus() {
        let vm = makeViewModel()

        vm.cohereModelStatus = .notDownloaded
        XCTAssertFalse(vm.isCohereModelDownloaded)

        vm.cohereModelStatus = .notLoaded
        XCTAssertTrue(vm.isCohereModelDownloaded)

        vm.cohereModelStatus = .ready
        XCTAssertTrue(vm.isCohereModelDownloaded)
    }
}

private final class NemotronCacheCheckRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [(variant: NemotronModelVariant, language: String?)] = []

    func record(_ variant: NemotronModelVariant, _ language: String?) {
        lock.lock()
        recordedCalls.append((variant, language))
        lock.unlock()
    }

    var calls: [(variant: NemotronModelVariant, language: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }
}

private final class CohereDeleteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var cached = true
    private var deletes = 0

    var isCached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    var deleteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deletes
    }

    func delete() {
        lock.lock()
        deletes += 1
        cached = false
        lock.unlock()
    }
}

private final class CohereDiskStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let cached: Bool
    private let directoryExists: Bool
    private var cacheCheckCount = 0
    private var directoryCheckCount = 0

    init(cached: Bool, cacheDirectoryExists: Bool) {
        self.cached = cached
        self.directoryExists = cacheDirectoryExists
    }

    var didCheckCohere: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cacheCheckCount > 0 && directoryCheckCount > 0
    }

    func isCached() -> Bool {
        lock.lock()
        cacheCheckCount += 1
        let value = cached
        lock.unlock()
        return value
    }

    func cacheDirectoryExists() -> Bool {
        lock.lock()
        directoryCheckCount += 1
        let value = directoryExists
        lock.unlock()
        return value
    }
}

private final class BlockingCohereDiskStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let cached: Bool
    private let directoryExists: Bool
    private var cacheCheckCount = 0
    private var directoryCheckCount = 0

    init(cached: Bool, cacheDirectoryExists: Bool) {
        self.cached = cached
        self.directoryExists = cacheDirectoryExists
    }

    var cacheCheckStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cacheCheckCount > 0
    }

    var didCheckCohere: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cacheCheckCount > 0 && directoryCheckCount > 0
    }

    func release() {
        releaseSemaphore.signal()
    }

    func isCached() -> Bool {
        lock.lock()
        cacheCheckCount += 1
        lock.unlock()
        _ = releaseSemaphore.wait(timeout: .now() + 1)
        return cached
    }

    func cacheDirectoryExists() -> Bool {
        lock.lock()
        directoryCheckCount += 1
        lock.unlock()
        return directoryExists
    }
}

private final class BlockingCohereDeleteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var cached = true
    private var deletes = 0
    private var started = false

    var isCached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    var deleteStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var deleteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return deletes
    }

    func delete() {
        lock.lock()
        started = true
        deletes += 1
        lock.unlock()
        releaseSemaphore.wait()
        lock.lock()
        cached = false
        lock.unlock()
    }

    func finishDelete() {
        releaseSemaphore.signal()
    }
}
