import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private enum FakeVADPrepError: Error {
    case boom
}

private final class OnboardingTelemetrySpy: TelemetryServiceProtocol, @unchecked Sendable {
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

private final class MutableDateBox: @unchecked Sendable {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

private actor WhisperDownloadSpy {
    private var calls: [String] = []
    var error: Error?

    func download(
        model: String,
        onProgress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void
    ) async throws {
        calls.append(model)

        onProgress(1, 2)
        onProgress(2, 2)

        if let error {
            throw error
        }
    }

    func snapshot() -> [String] {
        calls
    }
}

@MainActor
final class OnboardingViewModelTests: XCTestCase {
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

    private func makeViewModel(
        permissionService: PermissionServiceProtocol,
        sttClient: STTClientProtocol,
        speechEngineSwitcher: SpeechEngineSwitching? = nil,
        diarizationService: DiarizationServiceProtocol? = nil,
        meetingVADModelPreparer: MeetingVADModelPreparing? = nil,
        isMeetingVADLiveChunkingEnabled: @escaping @Sendable () -> Bool = { false },
        defaults: UserDefaults,
        isRuntimeSupported: @escaping @Sendable () -> Bool = { true },
        availableDiskBytes: @escaping @Sendable () -> Int64? = { 20 * 1_024 * 1_024 * 1_024 },
        isNetworkReachable: @escaping @Sendable () async -> Bool = { true },
        isSpeechModelCached: @escaping @Sendable () -> Bool = { false },
        isWhisperModelDownloaded: @escaping @Sendable () -> Bool = { true },
        downloadWhisperModel: OnboardingViewModel.WhisperModelDownloader? = nil,
        preferredLanguages: @escaping @Sendable () -> [String] = { ["en-US"] },
        now: @escaping @Sendable () -> Date = { Date() },
        permissionPollingInterval: Duration = .seconds(2),
        relaunchHintDelay: TimeInterval = 10
    ) -> OnboardingViewModel {
        OnboardingViewModel(
            permissionService: permissionService,
            sttClient: sttClient,
            speechEngineSwitcher: speechEngineSwitcher,
            diarizationService: diarizationService,
            meetingVADModelPreparer: meetingVADModelPreparer,
            isMeetingVADLiveChunkingEnabled: isMeetingVADLiveChunkingEnabled,
            isRuntimeSupported: isRuntimeSupported,
            availableDiskBytes: availableDiskBytes,
            isNetworkReachable: isNetworkReachable,
            isSpeechModelCached: isSpeechModelCached,
            isWhisperModelDownloaded: isWhisperModelDownloaded,
            downloadWhisperModel: downloadWhisperModel,
            preferredLanguages: preferredLanguages,
            defaults: defaults,
            now: now,
            permissionPollingInterval: permissionPollingInterval,
            relaunchHintDelay: relaunchHintDelay
        )
    }

    func testMicrophoneStepRequiresGrantedPermission() async throws {
        let perms = MockPermissionService()
        perms.microphonePermission = .notDetermined
        let stt = MockSTTClient()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        vm.jump(to: .microphone)

        // Not granted => can't continue.
        vm.refresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(vm.canContinueFromCurrentStep())

        // Granted => can continue.
        perms.microphonePermission = .granted
        vm.refresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(vm.canContinueFromCurrentStep())
    }

    func testAccessibilityStepRequiresPermission() async throws {
        let perms = MockPermissionService()
        perms.accessibilityPermission = false
        let stt = MockSTTClient()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        vm.jump(to: .accessibility)

        vm.refresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(vm.canContinueFromCurrentStep())

        perms.accessibilityPermission = true
        vm.refresh()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(vm.canContinueFromCurrentStep())
    }

    func testMeetingRecordingStepOrdering() {
        XCTAssertEqual(
            OnboardingViewModel.Step.allCases,
            [.welcome, .microphone, .accessibility, .meetingRecording, .calendar, .hotkey, .engine, .done]
        )
    }

    func testWhisperOnboardingRecommendationDetectsCJKPreferredLanguages() {
        XCTAssertEqual(
            OnboardingViewModel.recommendedWhisperLanguage(preferredLanguages: ["ko-KR"])?.languageCode,
            "ko"
        )
        XCTAssertEqual(
            OnboardingViewModel.recommendedWhisperLanguage(preferredLanguages: ["en-US", "ja-JP"])?.languageCode,
            "ja"
        )
        XCTAssertEqual(
            OnboardingViewModel.recommendedWhisperLanguage(preferredLanguages: ["zh-Hant-HK"])?.languageCode,
            "zh"
        )
        XCTAssertNil(OnboardingViewModel.recommendedWhisperLanguage(preferredLanguages: ["en-US", "fr-FR"]))
    }

    func testMeetingRecordingStepCanContinueWithoutPermission() {
        let perms = MockPermissionService()
        perms.screenRecordingPermission = false
        let stt = MockSTTClient()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        vm.jump(to: .meetingRecording)

        XCTAssertTrue(vm.canContinueFromCurrentStep())
    }

    func testSkipMeetingRecordingStepSetsFlagAndAdvances() {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        vm.jump(to: .meetingRecording)

        vm.skipMeetingRecordingStep()

        XCTAssertTrue(vm.meetingRecordingSkipped)
        XCTAssertTrue(defaults.bool(forKey: OnboardingViewModel.meetingRecordingSkippedKey))
        // Skip advances to the next *visible* step. With `calendarEnabled` on
        // that's `.calendar`; with it off the calendar step is filtered out
        // and the flow jumps straight to `.hotkey`.
        let expected: OnboardingViewModel.Step = AppFeatures.calendarEnabled ? .calendar : .hotkey
        XCTAssertEqual(vm.step, expected)
    }

    func testResetOnboardingClearsMeetingRecordingSkippedFlag() {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        vm.jump(to: .meetingRecording)
        vm.skipMeetingRecordingStep()
        XCTAssertTrue(defaults.bool(forKey: OnboardingViewModel.meetingRecordingSkippedKey))

        vm.resetOnboarding()

        XCTAssertFalse(vm.meetingRecordingSkipped)
        XCTAssertNil(defaults.object(forKey: OnboardingViewModel.meetingRecordingSkippedKey))
        XCTAssertEqual(vm.step, .welcome)
    }

    func testScreenRecordingGrantTransitionEmitsPermissionGrantedOnce() async throws {
        let telemetry = OnboardingTelemetrySpy()
        Telemetry.configure(telemetry)
        defer { Telemetry.configure(NoOpTelemetryService()) }

        let perms = MockPermissionService()
        perms.screenRecordingPermissionSequence = [false, true, true]
        let stt = MockSTTClient()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!
        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)

        vm.refresh()
        try await Task.sleep(for: .milliseconds(60))
        vm.refresh()
        try await Task.sleep(for: .milliseconds(60))
        vm.refresh()
        try await Task.sleep(for: .milliseconds(60))

        let grantedEvents = telemetry.snapshot().filter {
            if case .permissionGranted(let permission) = $0 {
                return permission == .screenRecording
            }
            return false
        }
        XCTAssertEqual(grantedEvents.count, 1)
    }

    func testRelaunchHintShowsAfterDelayWhenScreenRecordingStillNotGranted() async throws {
        let perms = MockPermissionService()
        perms.screenRecordingPermission = false
        perms.requestScreenRecordingResult = false
        let stt = MockSTTClient()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!
        let nowBox = MutableDateBox(Date(timeIntervalSince1970: 0))
        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            defaults: defaults,
            now: { nowBox.value }
        )

        vm.jump(to: .meetingRecording)
        vm.requestScreenRecordingAccess()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(vm.showRelaunchHint)

        nowBox.value = nowBox.value.addingTimeInterval(11)
        vm.refresh()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(vm.showRelaunchHint)
    }

    func testPermissionPollingLifecycleStopsAfterCancellation() async throws {
        let perms = MockPermissionService()
        perms.screenRecordingPermission = false
        let stt = MockSTTClient()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!
        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            defaults: defaults,
            permissionPollingInterval: .milliseconds(25)
        )

        vm.startPermissionPolling()
        vm.startPermissionPolling()
        try await waitUntil(timeout: .milliseconds(500)) {
            perms.checkScreenRecordingPermissionCallCount > 1
        }
        let beforeStopCount = perms.checkScreenRecordingPermissionCallCount
        XCTAssertGreaterThan(beforeStopCount, 1)

        vm.stopPermissionPolling()
        let atStopCount = perms.checkScreenRecordingPermissionCallCount
        try await Task.sleep(for: .milliseconds(100))
        let firstSettledCount = perms.checkScreenRecordingPermissionCallCount
        try await Task.sleep(for: .milliseconds(100))
        let secondSettledCount = perms.checkScreenRecordingPermissionCallCount

        // Allow at most one in-flight refresh tick to finish after cancellation.
        XCTAssertLessThanOrEqual(firstSettledCount, atStopCount + 1)
        // After settling, polling must remain stopped.
        XCTAssertEqual(secondSettledCount, firstSettledCount)
    }

    func testEngineWarmUpTransitionsToReady() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(vm.engineState, .ready)
        let called = await stt.wasWarmUpCalled()
        XCTAssertTrue(called)
        XCTAssertTrue(vm.canContinueFromCurrentStep())
    }

    // MARK: - Meeting VAD model prep (VAD-guided live chunking)

    func testEngineWarmUpPreparesMeetingVADModelWhenEnabledAndUncached() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let vadPreparer = MockMeetingVADModelPreparer()
        await vadPreparer.configureCached(false)
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            meetingVADModelPreparer: vadPreparer,
            isMeetingVADLiveChunkingEnabled: { true },
            defaults: defaults
        )
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(160))

        let prepared = await vadPreparer.prepareModelCalled
        XCTAssertTrue(prepared, "VAD model should be fetched on the Parakeet warm-up path when enabled and uncached")
        XCTAssertEqual(vm.engineState, .ready)
    }

    func testEngineWarmUpSkipsMeetingVADModelWhenFlagDisabled() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let vadPreparer = MockMeetingVADModelPreparer()
        await vadPreparer.configureCached(false)
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            meetingVADModelPreparer: vadPreparer,
            isMeetingVADLiveChunkingEnabled: { false },
            defaults: defaults
        )
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(160))

        let prepared = await vadPreparer.prepareModelCalled
        XCTAssertFalse(prepared, "disabled feature must not fetch the VAD model")
        XCTAssertEqual(vm.engineState, .ready)
    }

    func testEngineWarmUpSkipsMeetingVADModelWhenAlreadyCached() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let vadPreparer = MockMeetingVADModelPreparer()
        await vadPreparer.configureCached(true)  // already on disk
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            meetingVADModelPreparer: vadPreparer,
            isMeetingVADLiveChunkingEnabled: { true },
            defaults: defaults
        )
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(160))

        let prepared = await vadPreparer.prepareModelCalled
        XCTAssertFalse(prepared, "already-cached model must not be re-fetched")
        XCTAssertEqual(vm.engineState, .ready)
    }

    func testMeetingVADModelPrepFailureDoesNotFailWarmUp() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let vadPreparer = MockMeetingVADModelPreparer()
        await vadPreparer.configureCached(false)
        await vadPreparer.configurePrepareModel(error: FakeVADPrepError.boom)
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            meetingVADModelPreparer: vadPreparer,
            isMeetingVADLiveChunkingEnabled: { true },
            defaults: defaults
        )
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(160))

        let prepared = await vadPreparer.prepareModelCalled
        XCTAssertTrue(prepared)
        // VAD live chunking is optional — a download failure must not block the
        // speech engine, so warm-up still completes.
        XCTAssertEqual(vm.engineState, .ready)
    }

    func testEngineWarmUpUsesWhisperForCJKPreferredLanguageWhenModelIsCached() async throws {
        let telemetry = OnboardingTelemetrySpy()
        Telemetry.configure(telemetry)
        defer { Telemetry.configure(NoOpTelemetryService()) }

        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            defaults: defaults,
            isWhisperModelDownloaded: { true },
            preferredLanguages: { ["ko-KR"] }
        )
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(vm.whisperRecommendation?.languageCode, "ko")
        XCTAssertEqual(vm.engineState, .ready)
        XCTAssertEqual(SpeechEnginePreference.current(defaults: defaults), .whisper)
        XCTAssertEqual(SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults), "ko")
        let switches = await stt.speechEngineSwitchesSnapshot()
        let warmUpCallCount = await stt.warmUpCallCountSnapshot()
        XCTAssertEqual(switches, [.whisper])
        XCTAssertEqual(warmUpCallCount, 0)

        let settings = telemetry.snapshot().compactMap { event -> TelemetrySettingName? in
            guard case .settingChanged(let setting) = event else { return nil }
            return setting
        }
        XCTAssertEqual(settings, [.whisperDefaultLanguage])
    }

    func testEngineWarmUpPreparesDiarizationModelsOnCJKWhisperPath() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let diarization = MockDiarizationService()
        await diarization.configureCachedModels(false)
        await diarization.configureReady(false)
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            diarizationService: diarization,
            defaults: defaults,
            isWhisperModelDownloaded: { true },
            preferredLanguages: { ["ko-KR"] }
        )
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(160))

        let prepared = await diarization.prepareModelsCalled
        XCTAssertTrue(prepared)
        XCTAssertEqual(vm.engineState, .ready)
    }

    func testEngineWarmUpDownloadsWhisperForCJKPreferredLanguageWhenMissing() async throws {
        let telemetry = OnboardingTelemetrySpy()
        Telemetry.configure(telemetry)
        defer { Telemetry.configure(NoOpTelemetryService()) }

        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let downloadSpy = WhisperDownloadSpy()
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            defaults: defaults,
            isWhisperModelDownloaded: { false },
            downloadWhisperModel: { model, progress in
                try await downloadSpy.download(model: model, onProgress: progress)
            },
            preferredLanguages: { ["ja-JP"] }
        )
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(160))

        XCTAssertEqual(vm.engineState, .ready)
        let downloads = await downloadSpy.snapshot()
        XCTAssertEqual(downloads, [SpeechEnginePreference.defaultWhisperModelVariant])
        XCTAssertEqual(SpeechEnginePreference.current(defaults: defaults), .whisper)
        XCTAssertEqual(SpeechEnginePreference.whisperDefaultLanguage(defaults: defaults), "ja")

        let events = telemetry.snapshot()
        XCTAssertTrue(events.contains {
            if case .modelDownloadStarted(let modelKind, let speechEngine, _) = $0 {
                return modelKind == .whisperSTT && speechEngine == .whisper
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .modelDownloadCompleted(_, let modelKind, let speechEngine, _) = $0 {
                return modelKind == .whisperSTT && speechEngine == .whisper
            }
            return false
        })
    }

    func testEngineWarmUpFailsWhisperPreflightWhenCJKLocaleAndOffline() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            defaults: defaults,
            isNetworkReachable: { false },
            isWhisperModelDownloaded: { false },
            preferredLanguages: { ["zh-Hans-CN"] }
        )
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(120))

        if case .failed(let message) = vm.engineState {
            XCTAssertTrue(message.lowercased().contains("whisper model"))
        } else {
            XCTFail("Expected Whisper preflight failure when offline")
        }
        let switches = await stt.speechEngineSwitchesSnapshot()
        XCTAssertEqual(switches, [])
    }

    func testEngineWarmUpPreparesDiarizationModelsBeforeReady() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let diarization = MockDiarizationService()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            diarizationService: diarization,
            defaults: defaults
        )
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(vm.engineState, .ready)
        let prepared = await diarization.prepareModelsCalled
        XCTAssertTrue(prepared)
    }

    func testEngineWarmUpFailsWhenDiarizationPreparationFails() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let diarization = MockDiarizationService()
        await diarization.configurePrepareModels(error: STTError.modelDownloadFailed)
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            diarizationService: diarization,
            defaults: defaults
        )
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(vm.engineState, .failed(message: STTError.modelDownloadFailed.localizedDescription))
        XCTAssertFalse(vm.canContinueFromCurrentStep())
    }

    func testMarkOnboardingCompletedPersistsToDefaults() {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        XCTAssertFalse(vm.hasCompletedOnboarding)
        _ = vm.markOnboardingCompleted()
        XCTAssertTrue(vm.hasCompletedOnboarding)
    }

    func testEngineWarmUpWithProgressPhases() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        await stt.configureWarmUp(progressPhases: [
            "Downloading speech model... 0%",
            "Downloading speech model (571 MB)... 50%",
            "Loading model into memory...",
        ])
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(vm.engineState, .ready)
        let called = await stt.wasWarmUpCalled()
        XCTAssertTrue(called)
    }

    func testParseProgressFractionFromPercentage() {
        XCTAssertEqual(OnboardingProgressParser.parseProgressFraction(from: "Downloading speech model (571 MB)... 45%"), 0.45)
        XCTAssertEqual(OnboardingProgressParser.parseProgressFraction(from: "Downloading speech model (571 MB)... 0%"), 0.0)
        XCTAssertEqual(OnboardingProgressParser.parseProgressFraction(from: "Downloading speech model (571 MB)... 100%"), 1.0)
        XCTAssertEqual(OnboardingProgressParser.parseProgressFraction(from: "Speech model: Downloading speech model... 60% (3/5)"), 0.6)
    }

    func testParseProgressFractionReturnsNilForNonPercentage() {
        XCTAssertNil(OnboardingProgressParser.parseProgressFraction(from: "Creating Python environment..."))
        XCTAssertNil(OnboardingProgressParser.parseProgressFraction(from: "Loading model into memory..."))
        XCTAssertNil(OnboardingProgressParser.parseProgressFraction(from: "Ready"))
    }

    func testEngineStateWorkingWithProgress() {
        let state = OnboardingViewModel.EngineState.working(message: "Downloading...", progress: 0.5)
        let stateNoProgress = OnboardingViewModel.EngineState.working(message: "Loading...", progress: nil)

        XCTAssertNotEqual(state, stateNoProgress)
        XCTAssertEqual(state, .working(message: "Downloading...", progress: 0.5))
    }

    func testEngineWarmUpFailsTransientSTTFailureWithoutImplicitRetry() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        await stt.configureWarmUpFailuresBeforeSuccess(2)
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(vm.engineState, .failed(message: STTError.engineStartFailed("warm-up failed").localizedDescription))
        let sttCalls = await stt.warmUpCallCount
        XCTAssertEqual(sttCalls, 1)
    }

    func testRetryEngineWarmUpRecoversAfterFailedBackgroundWarmUp() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        await stt.configureWarmUp(error: STTError.modelDownloadFailed)
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(900))

        XCTAssertEqual(vm.engineState, .failed(message: STTError.modelDownloadFailed.localizedDescription))

        await stt.configureWarmUp(error: nil)
        vm.retryEngineWarmUp()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(vm.engineState, .ready)
    }

    func testEngineWarmUpFailsPreflightWhenOfflineOnFirstSetup() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            defaults: defaults,
            isNetworkReachable: { false },
            isSpeechModelCached: { false }
        )
        vm.jump(to: .engine)
        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(120))

        if case .failed(let message) = vm.engineState {
            XCTAssertTrue(message.lowercased().contains("internet connection is required"))
        } else {
            XCTFail("Expected preflight failure when offline")
        }

        let sttCalls = await stt.warmUpCallCount
        XCTAssertEqual(sttCalls, 0)
    }

    func testEngineWarmUpFailsPreflightWhenSpeechCachedButSpeakerModelsMissingAndOffline() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let diarization = MockDiarizationService()
        await diarization.configureCachedModels(false)
        await diarization.configureReady(false)
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            diarizationService: diarization,
            defaults: defaults,
            isNetworkReachable: { false },
            isSpeechModelCached: { true }
        )
        vm.jump(to: .engine)
        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(120))

        if case .failed(let message) = vm.engineState {
            XCTAssertTrue(message.lowercased().contains("speaker models"))
        } else {
            XCTFail("Expected preflight failure when speaker models are missing")
        }

        let sttCalls = await stt.warmUpCallCount
        XCTAssertEqual(sttCalls, 0, "Should fail before STT warm-up when speaker models are missing")
    }

    func testEngineWarmUpSkipsPreflightWhenSpeechAndSpeakerModelsAreCachedOffline() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let diarization = MockDiarizationService()
        await diarization.configureCachedModels(true)
        await diarization.configureReady(false)
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            diarizationService: diarization,
            defaults: defaults,
            isNetworkReachable: { false },
            isSpeechModelCached: { true }
        )
        vm.jump(to: .engine)
        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(vm.engineState, .ready)
        let sttCalls = await stt.warmUpCallCount
        XCTAssertEqual(sttCalls, 1, "Should proceed to STT warm-up when all required assets are cached")
    }

    func testEngineWarmUpFailsPreflightWhenDiskTooLowOnFirstSetup() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            defaults: defaults,
            availableDiskBytes: { 1_024 * 1_024 * 1_024 }, // 1 GB
            isSpeechModelCached: { false }
        )
        vm.jump(to: .engine)
        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(120))

        if case .failed(let message) = vm.engineState {
            XCTAssertTrue(message.lowercased().contains("not enough free disk space"))
        } else {
            XCTFail("Expected preflight failure when disk is low")
        }

        let sttCalls = await stt.warmUpCallCount
        XCTAssertEqual(sttCalls, 0)
    }

    func testEngineWarmUpFailsPreflightWhenRuntimeUnsupported() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            defaults: defaults,
            isRuntimeSupported: { false }
        )
        vm.jump(to: .engine)
        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(120))

        if case .failed(let message) = vm.engineState {
            XCTAssertTrue(message.lowercased().contains("apple silicon"))
        } else {
            XCTFail("Expected preflight failure when runtime unsupported")
        }

        let sttCalls = await stt.warmUpCallCount
        XCTAssertEqual(sttCalls, 0)
    }
}
