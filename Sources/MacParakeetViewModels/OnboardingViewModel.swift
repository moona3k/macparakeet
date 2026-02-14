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
            case .engine: return "Local Models"
            case .done: return "Ready"
            }
        }
    }

    public enum EngineState: Sendable, Equatable {
        case idle
        case working(message: String, progress: Double?)
        case ready
        case failed(message: String)
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
    private let llmService: any LLMServiceProtocol
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var engineGeneration: Int = 0
    private var refreshTask: Task<Void, Never>?
    private static let progressPercentRegex = try! NSRegularExpression(pattern: #"(\d{1,3})(?:\.\d+)?\s*%"#)

    public static let onboardingCompletedKey = "onboarding.completedAtISO"

    public init(
        permissionService: PermissionServiceProtocol,
        sttClient: STTClientProtocol,
        llmService: any LLMServiceProtocol,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.permissionService = permissionService
        self.sttClient = sttClient
        self.llmService = llmService
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
            case .ready:
                return true
            case .idle, .working(_, _), .failed:
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

    public func startEngineWarmUp() {
        guard case .idle = engineState else { return }
        engineGeneration += 1
        let generation = engineGeneration
        isBusy = true
        let message = "Setting up local models (Parakeet + Qwen). This may take a few minutes..."
        engineState = .working(message: message, progress: nil)

        Task {
            do {
                try await sttClient.warmUp { [weak self] progressMessage in
                    Task { @MainActor [weak self] in
                        guard let self, self.engineGeneration == generation else { return }
                        let message = "Speech model: \(progressMessage)"
                        let fraction = Self.parseProgressFraction(from: message)
                        self.engineState = .working(message: message, progress: fraction)
                    }
                }

                await MainActor.run {
                    guard self.engineGeneration == generation else { return }
                    self.engineState = .working(message: "Preparing local AI model (Qwen)...", progress: nil)
                }
                _ = try await llmService.generate(
                    request: LLMRequest(
                        prompt: "Reply with exactly: OK",
                        systemPrompt: "Return exactly one token: OK",
                        options: LLMGenerationOptions(
                            temperature: 0.0,
                            topP: 1.0,
                            maxTokens: 8,
                            timeoutSeconds: nil
                        )
                    )
                )

                await MainActor.run {
                    guard self.engineGeneration == generation else { return }
                    self.engineState = .ready
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    guard self.engineGeneration == generation else { return }
                    self.engineState = .failed(message: error.localizedDescription)
                    self.isBusy = false
                }
            }
        }
    }

    /// Extract a percentage from messages like:
    /// "Downloading speech model... 45%" or "Downloading speech model... 45% (3/7)"
    static func parseProgressFraction(from message: String) -> Double? {
        let range = NSRange(message.startIndex..., in: message)
        guard let match = progressPercentRegex.firstMatch(in: message, options: [], range: range),
              match.numberOfRanges >= 2,
              let numberRange = Range(match.range(at: 1), in: message),
              let percent = Double(message[numberRange]),
              percent >= 0,
              percent <= 100 else {
            return nil
        }

        return percent / 100
    }

    public func retryEngineWarmUp() {
        engineState = .idle
        startEngineWarmUp()
    }
}
