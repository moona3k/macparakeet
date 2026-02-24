import Foundation
import MacParakeetCore
#if canImport(Metal)
import Metal
#endif

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
            case .engine: return "Speech Model"
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
    private let isRuntimeSupported: @Sendable () -> Bool
    private let availableDiskBytes: @Sendable () -> Int64?
    private let isNetworkReachable: @Sendable () async -> Bool
    private let isSpeechModelCached: @Sendable () -> Bool
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var engineGeneration: Int = 0
    private var refreshTask: Task<Void, Never>?
    private static let progressPercentRegex = try! NSRegularExpression(pattern: #"(\d{1,3})(?:\.\d+)?\s*%"#)
    private let engineWarmUpAttempts = 3
    private let requiredFirstSetupDiskBytes: Int64 = 7 * 1_024 * 1_024 * 1_024

    public static let onboardingCompletedKey = "onboarding.completedAtISO"

    public init(
        permissionService: PermissionServiceProtocol,
        sttClient: STTClientProtocol,
        isRuntimeSupported: (@Sendable () -> Bool)? = nil,
        availableDiskBytes: (@Sendable () -> Int64?)? = nil,
        isNetworkReachable: (@Sendable () async -> Bool)? = nil,
        isSpeechModelCached: (@Sendable () -> Bool)? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.permissionService = permissionService
        self.sttClient = sttClient
        self.isRuntimeSupported = isRuntimeSupported ?? { Self.defaultRuntimeSupportedCheck() }
        self.availableDiskBytes = availableDiskBytes ?? { Self.defaultAvailableDiskBytes() }
        self.isNetworkReachable = isNetworkReachable ?? { await Self.defaultNetworkReachabilityCheck() }
        self.isSpeechModelCached = isSpeechModelCached ?? { STTClient.isModelCached() }
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
        let message = "Checking setup requirements..."
        engineState = .working(message: message, progress: nil)

        Task {
            do {
                try await runEnginePreflight()
                guard self.engineGeneration == generation else { throw CancellationError() }

                await MainActor.run {
                    guard self.engineGeneration == generation else { return }
                    self.engineState = .working(
                        message: "Setting up speech model (Parakeet). This may take a few minutes...",
                        progress: nil
                    )
                }

                try await runWithRetry(maxAttempts: engineWarmUpAttempts, onRetry: { [weak self] attempt in
                    guard let self, self.engineGeneration == generation else { return }
                    self.engineState = .working(
                        message: "Retrying speech model setup (attempt \(attempt)/\(self.engineWarmUpAttempts))...",
                        progress: nil
                    )
                }) {
                    guard self.engineGeneration == generation else { throw CancellationError() }

                    try await self.sttClient.warmUp { [weak self] progressMessage in
                        Task { @MainActor [weak self] in
                            guard let self, self.engineGeneration == generation else { return }
                            let message = "Speech model: \(progressMessage)"
                            let fraction = Self.parseProgressFraction(from: message)
                            self.engineState = .working(message: message, progress: fraction)
                        }
                    }
                }

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

    private func runWithRetry(
        maxAttempts: Int,
        onRetry: @escaping (_ attempt: Int) -> Void,
        operation: @escaping () async throws -> Void
    ) async throws {
        precondition(maxAttempts >= 1, "maxAttempts must be >= 1")

        var backoffNs: UInt64 = 250_000_000
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                try await operation()
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts else { break }
                let nextAttempt = attempt + 1
                onRetry(nextAttempt)
                try await Task.sleep(nanoseconds: backoffNs)
                backoffNs *= 2
            }
        }

        throw lastError ?? STTError.engineStartFailed("Local model warm-up failed.")
    }

    private func runEnginePreflight() async throws {
        guard isRuntimeSupported() else {
            throw STTError.engineStartFailed("Local model runtime requires Apple Silicon with Metal support.")
        }

        // Only gate on network/disk if the model still needs downloading.
        // If the model is already cached, skip preflight regardless of onboarding state
        // (e.g. user reset onboarding while offline — no download needed).
        guard !isSpeechModelCached() else { return }

        guard let freeBytes = availableDiskBytes() else {
            throw STTError.engineStartFailed("Unable to determine free disk space. Verify at least \(Self.formatGiB(requiredFirstSetupDiskBytes)) is available, then retry.")
        }

        guard freeBytes >= requiredFirstSetupDiskBytes else {
            throw STTError.engineStartFailed(
                "Not enough free disk space for first-time model setup. Need at least \(Self.formatGiB(requiredFirstSetupDiskBytes)) (available: \(Self.formatGiB(freeBytes)))."
            )
        }

        guard await isNetworkReachable() else {
            throw STTError.engineStartFailed("Internet connection is required for first-time model download. Check your network and retry.")
        }
    }

    private nonisolated static func formatGiB(_ bytes: Int64) -> String {
        let gib = Double(bytes) / 1_073_741_824.0
        return String(format: "%.1f GB", gib)
    }

    private nonisolated static func defaultAvailableDiskBytes() -> Int64? {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let n = attrs[.systemFreeSize] as? NSNumber {
                return n.int64Value
            }
            if let v = attrs[.systemFreeSize] as? Int64 {
                return v
            }
            if let v = attrs[.systemFreeSize] as? UInt64 {
                return Int64(clamping: v)
            }
            return nil
        } catch {
            return nil
        }
    }

    private nonisolated static func defaultNetworkReachabilityCheck() async -> Bool {
        guard let url = URL(string: "https://huggingface.co") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return true }
            return (200...399).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private nonisolated static func defaultRuntimeSupportedCheck() -> Bool {
        #if arch(x86_64)
        return false
        #else
        #if canImport(Metal)
        return MTLCreateSystemDefaultDevice() != nil
        #else
        return true
        #endif
        #endif
    }
}
