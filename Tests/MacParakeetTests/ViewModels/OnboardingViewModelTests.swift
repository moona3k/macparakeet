import XCTest
import os
@testable import MacParakeetCore
@testable import MacParakeetViewModels

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

private final class PollingPermissionService: PermissionServiceProtocol, @unchecked Sendable {
    private let microphoneCheckCount = OSAllocatedUnfairLock(initialState: 0)

    var checkMicrophonePermissionCallCount: Int {
        microphoneCheckCount.withLock { $0 }
    }

    func checkMicrophonePermission() async -> PermissionStatus {
        microphoneCheckCount.withLock { $0 += 1 }
        return .granted
    }

    func requestMicrophonePermission() async -> Bool {
        true
    }

    func checkScreenRecordingPermission() -> Bool {
        true
    }

    func requestScreenRecordingPermission() -> Bool {
        true
    }

    func openMicrophoneSettings() {}

    func openScreenRecordingSettings() {}

    func checkAccessibilityPermission() -> Bool {
        true
    }

    func requestAccessibilityPermission(prompt _: Bool) -> Bool {
        true
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
        warmUpStallTimeout: Duration = OnboardingViewModel.warmUpStallTimeout
    ) -> OnboardingViewModel {
        OnboardingViewModel(
            permissionService: permissionService,
            sttClient: sttClient,
            speechEngineSwitcher: speechEngineSwitcher,
            diarizationService: diarizationService,
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
            warmUpStallTimeout: warmUpStallTimeout
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

    func testStepOrdering() {
        XCTAssertEqual(
            OnboardingViewModel.Step.allCases,
            [.welcome, .microphone, .accessibility, .hotkey, .engine, .done]
        )
    }

    // MARK: - Six-step dictation-first flow

    func testVisibleStepsIsCanonicalSixStepList() {
        XCTAssertEqual(
            OnboardingViewModel.visibleSteps,
            [.welcome, .microphone, .accessibility, .hotkey, .engine, .done]
        )
    }

    func testGoNextWalksSixSteps() async throws {
        let perms = MockPermissionService()
        perms.microphonePermission = .granted
        perms.accessibilityPermission = true
        let stt = MockSTTClient()
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        XCTAssertEqual(vm.step, .welcome)

        vm.goNext()
        XCTAssertEqual(vm.step, .microphone)

        vm.goNext()
        XCTAssertEqual(vm.step, .accessibility)

        vm.goNext()
        XCTAssertEqual(vm.step, .hotkey)

        vm.goNext()
        XCTAssertEqual(vm.step, .engine)

        XCTAssertFalse(vm.canContinueFromCurrentStep())
    }

    func testGoBackWalksSixSteps() {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        vm.jump(to: .done)

        vm.goBack()
        XCTAssertEqual(vm.step, .engine)

        vm.goBack()
        XCTAssertEqual(vm.step, .hotkey)

        vm.goBack()
        XCTAssertEqual(vm.step, .accessibility)

        vm.goBack()
        XCTAssertEqual(vm.step, .microphone)

        vm.goBack()
        XCTAssertEqual(vm.step, .welcome)

        vm.goBack()
        XCTAssertEqual(vm.step, .welcome)
    }

    func testCanContinueForEachStep() {
        let perms = MockPermissionService()
        perms.microphonePermission = .granted
        perms.accessibilityPermission = true
        let stt = MockSTTClient()
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)

        vm.jump(to: .welcome)
        XCTAssertTrue(vm.canContinueFromCurrentStep(), "welcome should always allow continue")

        vm.jump(to: .hotkey)
        XCTAssertTrue(vm.canContinueFromCurrentStep(), "hotkey should always allow continue")

        vm.jump(to: .done)
        XCTAssertTrue(vm.canContinueFromCurrentStep(), "done should always allow continue")

        vm.jump(to: .engine)
        XCTAssertFalse(vm.canContinueFromCurrentStep(), "engine requires ready state")
    }

    func testExistingUsersDoNotReOnboard() {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("2026-01-01T00:00:00Z", forKey: OnboardingViewModel.onboardingCompletedKey)

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        XCTAssertTrue(vm.hasCompletedOnboarding)
    }

    func testNoMeetingRecordingOrCalendarStepsInFlow() {
        let steps = OnboardingViewModel.visibleSteps
        let allCases = OnboardingViewModel.Step.allCases

        XCTAssertEqual(steps, allCases)
        XCTAssertEqual(steps.count, 6)
    }

    func testWhisperOnboardingRecommendationDetectsCJKPreferredLanguages() {
        XCTAssertEqual(
            OnboardingViewModel.recommendedWhisperLanguage(preferredLanguages: ["ko-KR"])?.languageCode,
            "ko"
        )
        XCTAssertEqual(
            OnboardingViewModel.recommendedWhisperLanguage(preferredLanguages: ["ja-JP"])?.languageCode,
            "ja"
        )
        XCTAssertEqual(
            OnboardingViewModel.recommendedWhisperLanguage(preferredLanguages: ["zh-Hant-HK"])?.languageCode,
            "zh"
        )
        XCTAssertEqual(
            OnboardingViewModel.recommendedWhisperLanguage(preferredLanguages: ["zh-Hans-CN", "ja-JP"])?.languageCode,
            "zh"
        )
        XCTAssertEqual(
            OnboardingViewModel.recommendedWhisperLanguage(preferredLanguages: ["ja-JP", "zh-Hans-CN"])?.languageCode,
            "ja"
        )
        XCTAssertNil(OnboardingViewModel.recommendedWhisperLanguage(preferredLanguages: ["en-US", "fr-FR"]))
    }

    func testWhisperOnboardingRecommendationKeepsParakeetWhenEnglishIsPreferred() {
        XCTAssertNil(OnboardingViewModel.recommendedWhisperLanguage(preferredLanguages: ["en-US", "ja-JP"]))
        XCTAssertNil(OnboardingViewModel.recommendedWhisperLanguage(preferredLanguages: ["ja-JP", "en-US"]))
        XCTAssertNil(OnboardingViewModel.recommendedWhisperLanguage(preferredLanguages: ["zh-Hans-CN", "en-GB"]))
    }

    func testPermissionPollingLifecycleStopsAfterCancellation() async throws {
        let perms = PollingPermissionService()
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
            perms.checkMicrophonePermissionCallCount > 1
        }
        let beforeStopCount = perms.checkMicrophonePermissionCallCount
        XCTAssertGreaterThan(beforeStopCount, 1)

        vm.stopPermissionPolling()
        let atStopCount = perms.checkMicrophonePermissionCallCount
        try await Task.sleep(for: .milliseconds(100))
        let firstSettledCount = perms.checkMicrophonePermissionCallCount
        try await Task.sleep(for: .milliseconds(100))
        let secondSettledCount = perms.checkMicrophonePermissionCallCount

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

    /// The warm-up stall watchdog is the only escape hatch for a first-run user
    /// whose model download silently stalls (memory: v0.4.22 stranded ~23 users
    /// for ~24h). When the progress stream goes quiet past `warmUpStallTimeout`,
    /// the watchdog must surface a retry-able `.failed` and clear `isBusy`.
    func testEngineWarmUpStallTimeoutTransitionsToFailed() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        await stt.configureWarmUpHangIndefinitely()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            defaults: defaults,
            warmUpStallTimeout: .milliseconds(200)
        )
        vm.jump(to: .engine)
        vm.startEngineWarmUp()

        // Generous margin over the 200ms watchdog to keep CI deterministic.
        try await Task.sleep(for: .seconds(2))

        guard case .failed(let message) = vm.engineState else {
            return XCTFail("expected .failed after stall, got \(vm.engineState)")
        }
        XCTAssertTrue(
            message.contains("longer than expected"),
            "stall message should prompt a network check + retry, got: \(message)"
        )
        XCTAssertFalse(vm.isBusy, "isBusy must clear so the Retry button is actionable")
        XCTAssertFalse(vm.canContinueFromCurrentStep(), "a stalled engine must not gate open")
    }

    /// The watchdog must not false-positive on a healthy warm-up: even with a
    /// short timeout window, a stream that reaches `.ready` quickly re-arms the
    /// watchdog on every event and finishes before it can fire.
    func testEngineWarmUpDoesNotStallOnHealthyWarmUpWithShortTimeout() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            defaults: defaults,
            warmUpStallTimeout: .milliseconds(500)
        )
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(vm.engineState, .ready)
        let called = await stt.wasWarmUpCalled()
        XCTAssertTrue(called)
        XCTAssertTrue(vm.canContinueFromCurrentStep())
    }

    func testEngineWarmUpDownloadRemainsOnPath() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        vm.jump(to: .engine)
        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(vm.engineState, .ready)
        let called = await stt.wasWarmUpCalled()
        XCTAssertTrue(called, "Speech model warm-up must still occur on the 6-step path")

        // Once the engine is ready, the final .engine -> .done transition must
        // complete the 6-step flow end-to-end (the last goNext() in the path).
        XCTAssertTrue(vm.canContinueFromCurrentStep(), "engine should allow continue once ready")
        vm.goNext()
        XCTAssertEqual(vm.step, .done, "the .engine -> .done transition completes the 6-step flow")
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
