import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    private func makeViewModel(
        permissionService: PermissionServiceProtocol,
        sttClient: STTClientProtocol,
        diarizationService: DiarizationServiceProtocol? = nil,
        defaults: UserDefaults,
        isRuntimeSupported: @escaping @Sendable () -> Bool = { true },
        availableDiskBytes: @escaping @Sendable () -> Int64? = { 20 * 1_024 * 1_024 * 1_024 },
        isNetworkReachable: @escaping @Sendable () async -> Bool = { true },
        isSpeechModelCached: @escaping @Sendable () -> Bool = { false }
    ) -> OnboardingViewModel {
        OnboardingViewModel(
            permissionService: permissionService,
            sttClient: sttClient,
            diarizationService: diarizationService,
            isRuntimeSupported: isRuntimeSupported,
            availableDiskBytes: availableDiskBytes,
            isNetworkReachable: isNetworkReachable,
            isSpeechModelCached: isSpeechModelCached,
            defaults: defaults
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

    func testEngineWarmUpRetriesTransientSTTFailure() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        await stt.configureWarmUpFailuresBeforeSuccess(2)
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

        let vm = makeViewModel(permissionService: perms, sttClient: stt, defaults: defaults)
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(1_100))

        XCTAssertEqual(vm.engineState, .ready)
        let sttCalls = await stt.warmUpCallCount
        XCTAssertEqual(sttCalls, 3)
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

    func testEngineWarmUpSkipsPreflightWhenSpeechCachedEvenIfOnboardingIncompleteAndOffline() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

        let vm = makeViewModel(
            permissionService: perms,
            sttClient: stt,
            defaults: defaults,
            isNetworkReachable: { false },
            isSpeechModelCached: { true }
        )
        vm.jump(to: .engine)
        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(120))

        // Model is cached — should skip preflight and proceed to warm-up,
        // even if onboarding hasn't completed and we're offline.
        let sttCalls = await stt.warmUpCallCount
        XCTAssertEqual(sttCalls, 1, "Should proceed to STT warm-up when model is cached")
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
