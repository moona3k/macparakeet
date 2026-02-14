import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    func testMicrophoneStepRequiresGrantedPermission() async throws {
        let perms = MockPermissionService()
        perms.microphonePermission = .notDetermined
        let stt = MockSTTClient()
        let llm = MockLLMService()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")

        let vm = OnboardingViewModel(
            permissionService: perms,
            sttClient: stt,
            llmService: llm,
            defaults: defaults
        )
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
        let llm = MockLLMService()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")

        let vm = OnboardingViewModel(
            permissionService: perms,
            sttClient: stt,
            llmService: llm,
            defaults: defaults
        )
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
        let llm = MockLLMService()
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")

        let vm = OnboardingViewModel(
            permissionService: perms,
            sttClient: stt,
            llmService: llm,
            defaults: defaults
        )
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(vm.engineState, .ready)
        let called = await stt.wasWarmUpCalled()
        XCTAssertTrue(called)
        let requestCount = await llm.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(vm.canContinueFromCurrentStep())
    }

    func testMarkOnboardingCompletedPersistsToDefaults() {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let llm = MockLLMService()
        let suite = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let vm = OnboardingViewModel(
            permissionService: perms,
            sttClient: stt,
            llmService: llm,
            defaults: defaults
        )
        XCTAssertFalse(vm.hasCompletedOnboarding)
        _ = vm.markOnboardingCompleted()
        XCTAssertTrue(vm.hasCompletedOnboarding)
    }

    func testEngineWarmUpWithProgressPhases() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let llm = MockLLMService()
        await stt.configureWarmUp(progressPhases: [
            "Downloading speech model... 0%",
            "Downloading speech model (571 MB)... 50%",
            "Loading model into memory...",
        ])
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

        let vm = OnboardingViewModel(
            permissionService: perms,
            sttClient: stt,
            llmService: llm,
            defaults: defaults
        )
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(vm.engineState, .ready)
        let called = await stt.wasWarmUpCalled()
        XCTAssertTrue(called)
        let requestCount = await llm.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testEngineWarmUpFailsWhenLLMSetupFails() async throws {
        let perms = MockPermissionService()
        let stt = MockSTTClient()
        let llm = MockLLMService()
        await llm.configureError(LLMServiceError.generationFailed("network"))
        let defaults = UserDefaults(suiteName: "com.macparakeet.tests.\(UUID().uuidString)")!

        let vm = OnboardingViewModel(
            permissionService: perms,
            sttClient: stt,
            llmService: llm,
            defaults: defaults
        )
        vm.jump(to: .engine)

        vm.startEngineWarmUp()
        try await Task.sleep(for: .milliseconds(120))

        if case .failed = vm.engineState {
            // expected
        } else {
            XCTFail("Expected failed state when LLM warm-up fails")
        }
        XCTAssertFalse(vm.canContinueFromCurrentStep())
    }

    func testParseProgressFractionFromPercentage() {
        XCTAssertEqual(OnboardingViewModel.parseProgressFraction(from: "Downloading speech model (571 MB)... 45%"), 0.45)
        XCTAssertEqual(OnboardingViewModel.parseProgressFraction(from: "Downloading speech model (571 MB)... 0%"), 0.0)
        XCTAssertEqual(OnboardingViewModel.parseProgressFraction(from: "Downloading speech model (571 MB)... 100%"), 1.0)
        XCTAssertEqual(OnboardingViewModel.parseProgressFraction(from: "Speech model: Downloading speech model... 60% (3/5)"), 0.6)
    }

    func testParseProgressFractionReturnsNilForNonPercentage() {
        XCTAssertNil(OnboardingViewModel.parseProgressFraction(from: "Creating Python environment..."))
        XCTAssertNil(OnboardingViewModel.parseProgressFraction(from: "Loading model into memory..."))
        XCTAssertNil(OnboardingViewModel.parseProgressFraction(from: "Ready"))
    }

    func testEngineStateWorkingWithProgress() {
        let state = OnboardingViewModel.EngineState.working(message: "Downloading...", progress: 0.5)
        let stateNoProgress = OnboardingViewModel.EngineState.working(message: "Loading...", progress: nil)

        XCTAssertNotEqual(state, stateNoProgress)
        XCTAssertEqual(state, .working(message: "Downloading...", progress: 0.5))
    }
}
