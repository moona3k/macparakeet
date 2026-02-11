import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class OnboardingViewModel {
    public enum Step: Int, CaseIterable, Identifiable, Sendable {
        case welcome
        case microphone
        case accessibility
        case hotkey
        case engine
        case done

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .microphone: return "Microphone"
            case .accessibility: return "Accessibility"
            case .hotkey: return "Hotkey"
            case .engine: return "Speech Engine"
            case .done: return "Ready"
            }
        }
    }

    public enum EngineState: Sendable, Equatable {
        case idle
        case working(message: String)
        case ready
        case failed(message: String)
        case skipped
    }

    public struct Completion: Sendable {
        public let completedAt: Date
    }

    public private(set) var step: Step = .welcome
    public private(set) var micStatus: PermissionStatus = .notDetermined
    public private(set) var accessibilityGranted: Bool = false
    public private(set) var engineState: EngineState = .idle

    public var isBusy: Bool = false

    private let permissionService: PermissionServiceProtocol
    private let sttClient: STTClientProtocol
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var engineGeneration: Int = 0
    private var refreshTask: Task<Void, Never>?

    public static let onboardingCompletedKey = "onboarding.completedAtISO"

    public init(
        permissionService: PermissionServiceProtocol,
        sttClient: STTClientProtocol,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.permissionService = permissionService
        self.sttClient = sttClient
        self.defaults = defaults
        self.now = now
    }

    public var hasCompletedOnboarding: Bool {
        defaults.string(forKey: Self.onboardingCompletedKey) != nil
    }

    public func markOnboardingCompleted() -> Completion {
        let iso = ISO8601DateFormatter().string(from: now())
        defaults.set(iso, forKey: Self.onboardingCompletedKey)
        return Completion(completedAt: now())
    }

    public func resetOnboarding() {
        defaults.removeObject(forKey: Self.onboardingCompletedKey)
        step = .welcome
        engineState = .idle
    }

    public func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            let mic = await permissionService.checkMicrophonePermission()
            let ax = permissionService.checkAccessibilityPermission()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.micStatus = mic
                self.accessibilityGranted = ax
                self.refreshTask = nil
            }
        }
    }

    public func goNext() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        refresh()
    }

    public func goBack() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        step = prev
        refresh()
    }

    public func jump(to target: Step) {
        step = target
        refresh()
    }

    public func canContinueFromCurrentStep() -> Bool {
        switch step {
        case .welcome:
            return true
        case .microphone:
            return micStatus == .granted
        case .accessibility:
            return accessibilityGranted
        case .hotkey:
            return true
        case .engine:
            switch engineState {
            case .ready, .skipped:
                return true
            case .idle, .working, .failed:
                return false
            }
        case .done:
            return true
        }
    }

    // MARK: - Actions

    public func requestMicrophoneAccess() {
        isBusy = true
        Task {
            _ = await permissionService.requestMicrophonePermission()
            let mic = await permissionService.checkMicrophonePermission()
            await MainActor.run {
                self.micStatus = mic
                self.isBusy = false
            }
        }
    }

    public func requestAccessibilityAccess(prompt: Bool = true) {
        isBusy = true
        _ = permissionService.requestAccessibilityPermission(prompt: prompt)
        accessibilityGranted = permissionService.checkAccessibilityPermission()
        isBusy = false
    }

    public func startEngineWarmUp(isFirstRun: Bool) {
        guard case .idle = engineState else { return }
        engineGeneration += 1
        let generation = engineGeneration
        isBusy = true
        let message = isFirstRun
            ? "Setting up local speech engine (first run can take a few minutes)..."
            : "Starting local speech engine..."
        engineState = .working(message: message)

        Task {
            do {
                try await sttClient.warmUp()
                await MainActor.run {
                    guard self.engineGeneration == generation else { return }
                    if case .skipped = self.engineState { return }
                    self.engineState = .ready
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    guard self.engineGeneration == generation else { return }
                    if case .skipped = self.engineState { return }
                    self.engineState = .failed(message: error.localizedDescription)
                    self.isBusy = false
                }
            }
        }
    }

    public func retryEngineWarmUp(isFirstRun: Bool) {
        engineState = .idle
        startEngineWarmUp(isFirstRun: isFirstRun)
    }

    public func skipEngineWarmUp() {
        // Ignore any in-flight warmup completion.
        engineGeneration += 1
        engineState = .skipped
        isBusy = false
    }
}
