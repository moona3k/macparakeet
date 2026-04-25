import Foundation
import MacParakeetCore
import OSLog
#if canImport(Metal)
import Metal
#endif

@MainActor
@Observable
public final class OnboardingViewModel {
    private let logger = Logger(subsystem: "com.macparakeet.viewmodels", category: "OnboardingViewModel")
    public enum Step: Int, CaseIterable, Identifiable, Sendable {
        case welcome
        case microphone
        case accessibility
        case meetingRecording
        case calendar
        case hotkey
        case engine
        case done

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .microphone: return "Microphone"
            case .accessibility: return "Accessibility"
            case .meetingRecording: return "Meeting Recording"
            case .calendar: return "Calendar"
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
    public private(set) var screenRecordingGranted: Bool = false
    public private(set) var meetingRecordingSkipped: Bool
    public private(set) var calendarPermissionGranted: Bool = false
    public private(set) var calendarSkipped: Bool
    public private(set) var showRelaunchHint: Bool = false
    public private(set) var engineState: EngineState = .idle

    public var isBusy: Bool = false

    private let permissionService: PermissionServiceProtocol
    private let sttClient: STTClientProtocol
    private let diarizationService: DiarizationServiceProtocol?
    private let isRuntimeSupported: @Sendable () -> Bool
    private let availableDiskBytes: @Sendable () -> Int64?
    private let isNetworkReachable: @Sendable () async -> Bool
    private let isSpeechModelCached: @Sendable () -> Bool
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let permissionPollingInterval: Duration
    private let relaunchHintDelay: TimeInterval
    private var engineGeneration: Int = 0
    private var refreshTask: Task<Void, Never>?
    private var permissionPollingTask: Task<Void, Never>?
    private var warmUpObserverTask: Task<Void, Never>?
    private var warmUpObserverId: UUID?
    private var warmUpObservationToken: UUID?
    private var screenRecordingGrantRequestedAt: Date?
    private var hasLoadedInitialScreenRecordingState = false
    private var hasEmittedScreenRecordingGranted = false
    private let requiredFirstSetupDiskBytes: Int64 = 7 * 1_024 * 1_024 * 1_024
    private let requiredDiarizationSetupDiskBytes: Int64 = 512 * 1_024 * 1_024

    public static let onboardingCompletedKey = "onboarding.completedAtISO"
    public static let meetingRecordingSkippedKey = "onboarding.meetingRecordingSkipped"
    public static let calendarSkippedKey = "onboarding.calendarSkipped"

    public init(
        permissionService: PermissionServiceProtocol,
        sttClient: STTClientProtocol,
        diarizationService: DiarizationServiceProtocol? = nil,
        isRuntimeSupported: (@Sendable () -> Bool)? = nil,
        availableDiskBytes: (@Sendable () -> Int64?)? = nil,
        isNetworkReachable: (@Sendable () async -> Bool)? = nil,
        isSpeechModelCached: (@Sendable () -> Bool)? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        permissionPollingInterval: Duration = .seconds(2),
        relaunchHintDelay: TimeInterval = 10
    ) {
        self.permissionService = permissionService
        self.sttClient = sttClient
        self.diarizationService = diarizationService
        self.isRuntimeSupported = isRuntimeSupported ?? { Self.defaultRuntimeSupportedCheck() }
        self.availableDiskBytes = availableDiskBytes ?? { Self.defaultAvailableDiskBytes() }
        self.isNetworkReachable = isNetworkReachable ?? { await Self.defaultNetworkReachabilityCheck() }
        self.isSpeechModelCached = isSpeechModelCached ?? { STTRuntime.isModelCached() }
        self.defaults = defaults
        self.now = now
        self.permissionPollingInterval = permissionPollingInterval
        self.relaunchHintDelay = relaunchHintDelay
        self.meetingRecordingSkipped = defaults.bool(forKey: Self.meetingRecordingSkippedKey)
        self.calendarSkipped = defaults.bool(forKey: Self.calendarSkippedKey)
        self.calendarPermissionGranted = CalendarService.shared.permissionStatus == .granted
    }

    public var hasCompletedOnboarding: Bool {
        defaults.string(forKey: Self.onboardingCompletedKey) != nil
    }

    public func markOnboardingCompleted() -> Completion {
        let completedAt = now()
        let iso = ISO8601DateFormatter().string(from: completedAt)
        defaults.set(iso, forKey: Self.onboardingCompletedKey)
        Telemetry.send(.onboardingCompleted(durationSeconds: nil))
        return Completion(completedAt: completedAt)
    }

    public func resetOnboarding() {
        defaults.removeObject(forKey: Self.onboardingCompletedKey)
        defaults.removeObject(forKey: Self.meetingRecordingSkippedKey)
        defaults.removeObject(forKey: Self.calendarSkippedKey)
        step = .welcome
        engineState = .idle
        meetingRecordingSkipped = false
        calendarSkipped = false
        // Re-resolve from the live calendar permission so a previously-
        // granted user re-entering onboarding sees the correct "completed"
        // state, not the stale value carried over from VM init.
        calendarPermissionGranted = CalendarService.shared.permissionStatus == .granted
        clearMeetingRecordingPendingState()
    }

    public func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            let mic = await permissionService.checkMicrophonePermission()
            let ax = permissionService.checkAccessibilityPermission()
            let screenRecording = permissionService.checkScreenRecordingPermission()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                let previousScreenRecordingGranted = self.screenRecordingGranted
                self.micStatus = mic
                self.accessibilityGranted = ax
                self.screenRecordingGranted = screenRecording
                if self.hasLoadedInitialScreenRecordingState,
                   !previousScreenRecordingGranted,
                   screenRecording,
                   !self.hasEmittedScreenRecordingGranted {
                    self.hasEmittedScreenRecordingGranted = true
                    Telemetry.send(.permissionGranted(permission: .screenRecording))
                }
                self.hasLoadedInitialScreenRecordingState = true
                self.updateMeetingRecordingRelaunchHint(now: self.now())
                self.refreshTask = nil
            }
        }
    }

    /// Steps the user actually sees. Hidden steps (gated by `AppFeatures`) are
    /// filtered out so next/back/jump all walk the visible list — no flicker or
    /// silent no-ops when flags are off.
    public static var visibleSteps: [Step] {
        Step.allCases.filter { step in
            switch step {
            case .meetingRecording, .calendar:
                return AppFeatures.meetingRecordingEnabled
            default:
                return true
            }
        }
    }

    public func goNext() {
        let visible = Self.visibleSteps
        let currentRaw = step.rawValue
        guard let next = visible.first(where: { $0.rawValue > currentRaw }) else { return }
        if step == .meetingRecording {
            clearMeetingRecordingPendingState()
        }
        step = next
        Telemetry.send(.onboardingStep(step: next.title.lowercased()))
        refresh()
    }

    public func goBack() {
        let visible = Self.visibleSteps
        let currentRaw = step.rawValue
        guard let prev = visible.last(where: { $0.rawValue < currentRaw }) else { return }
        if step == .meetingRecording {
            clearMeetingRecordingPendingState()
        }
        step = prev
        refresh()
    }

    public func jump(to target: Step) {
        if step == .meetingRecording, target != .meetingRecording {
            clearMeetingRecordingPendingState()
        }
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
        case .meetingRecording:
            return true
        case .calendar:
            return true
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
        Telemetry.send(.permissionPrompted(permission: .microphone))
        Task {
            _ = await permissionService.requestMicrophonePermission()
            let mic = await permissionService.checkMicrophonePermission()
            await MainActor.run {
                self.micStatus = mic
                self.isBusy = false
                if mic == .granted {
                    Telemetry.send(.permissionGranted(permission: .microphone))
                } else {
                    Telemetry.send(.permissionDenied(permission: .microphone))
                }
            }
        }
    }

    public func requestAccessibilityAccess(prompt: Bool = true) {
        isBusy = true
        Telemetry.send(.permissionPrompted(permission: .accessibility))
        _ = permissionService.requestAccessibilityPermission(prompt: prompt)
        accessibilityGranted = permissionService.checkAccessibilityPermission()
        isBusy = false
        // Only emit granted — accessibility check is synchronous and returns false
        // immediately after prompting (user hasn't clicked yet in System Settings).
        // Emitting permissionDenied here would fire for nearly every new user.
        if accessibilityGranted {
            Telemetry.send(.permissionGranted(permission: .accessibility))
        }
    }

    public func requestScreenRecordingAccess() {
        Telemetry.send(.permissionPrompted(permission: .screenRecording))
        screenRecordingGrantRequestedAt = now()
        showRelaunchHint = false
        _ = permissionService.requestScreenRecordingPermission()
        refresh()
    }

    public func skipMeetingRecordingStep() {
        meetingRecordingSkipped = true
        defaults.set(true, forKey: Self.meetingRecordingSkippedKey)
        clearMeetingRecordingPendingState()
        goNext()
    }

    /// Trigger the EventKit permission prompt. On grant, default the user
    /// into `.notify` mode so the feature works out of the box and request
    /// notification authorization in the same flow — without it, macOS
    /// silently drops every reminder we post and the user concludes the
    /// feature is broken. We write directly to UserDefaults + post the
    /// shared notification so a running `MeetingAutoStartCoordinator`
    /// re-evaluates immediately.
    public func requestCalendarAccess() {
        isBusy = true
        Telemetry.send(.permissionPrompted(permission: .calendar))
        Task {
            let granted = await CalendarService.shared.requestPermission()
            if granted {
                await CalendarNotificationAuthorization.requestIfNeeded()
            }
            await MainActor.run {
                self.isBusy = false
                self.calendarPermissionGranted = granted
                if granted {
                    Telemetry.send(.permissionGranted(permission: .calendar))
                    self.applyCalendarMode(.notify)
                } else {
                    Telemetry.send(.permissionDenied(permission: .calendar))
                }
            }
        }
    }

    /// Skip the calendar onboarding step. Persists `.off` mode explicitly so
    /// the SettingsViewModel default doesn't silently flip back to enabled
    /// later. Symmetric to `skipMeetingRecordingStep()`.
    public func skipCalendarStep() {
        calendarSkipped = true
        defaults.set(true, forKey: Self.calendarSkippedKey)
        applyCalendarMode(.off)
        goNext()
    }

    private func applyCalendarMode(_ mode: CalendarAutoStartMode) {
        defaults.set(mode.rawValue, forKey: CalendarAutoStartPreferences.modeKey)
        NotificationCenter.default.post(name: .macParakeetCalendarSettingsDidChange, object: nil)
    }

    public func openScreenRecordingSystemSettings() {
        permissionService.openScreenRecordingSettings()
    }

    public func startPermissionPolling() {
        guard permissionPollingTask == nil else { return }
        refresh()
        permissionPollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.permissionPollingInterval)
                guard !Task.isCancelled else { break }
                self.refresh()
            }
        }
    }

    public func stopPermissionPolling() {
        permissionPollingTask?.cancel()
        permissionPollingTask = nil
    }

    public func startEngineWarmUp() {
        // If already observing or completed, don't restart
        if case .ready = engineState { return }
        if warmUpObserverTask != nil { return }

        engineGeneration += 1
        let generation = engineGeneration
        let observationToken = UUID()
        isBusy = true
        engineState = .working(message: "Checking setup requirements...", progress: nil)
        warmUpObservationToken = observationToken

        // Assign the outer Task immediately so re-entrant calls hit the
        // `warmUpObserverTask != nil` guard. Without this, the two `await`
        // actor hops below leave a window where a second call can proceed.
        let outerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let clearObservationIfCurrent = { [weak self] (observerId: UUID?) in
                guard let self, self.warmUpObservationToken == observationToken else { return }
                self.warmUpObserverTask = nil
                self.warmUpObserverId = nil
                self.warmUpObservationToken = nil
                if let observerId {
                    Task { [sttClient] in await sttClient.removeWarmUpObserver(id: observerId) }
                }
            }

            do {
                try await runEnginePreflight()
                guard self.engineGeneration == generation, self.warmUpObservationToken == observationToken else { return }
            } catch {
                guard self.engineGeneration == generation, self.warmUpObservationToken == observationToken else { return }
                self.engineState = .failed(message: error.localizedDescription)
                self.isBusy = false
                clearObservationIfCurrent(nil)
                return
            }

            let warmUpStartedAt = Date()
            Telemetry.send(.modelDownloadStarted)
            await sttClient.backgroundWarmUp()
            guard self.engineGeneration == generation, self.warmUpObservationToken == observationToken else { return }

            // Subscribe to progress updates
            let (observerId, stream) = await sttClient.observeWarmUpProgress()
            guard self.engineGeneration == generation, self.warmUpObservationToken == observationToken else {
                await sttClient.removeWarmUpObserver(id: observerId)
                return
            }

            self.warmUpObserverId = observerId
            defer { clearObservationIfCurrent(observerId) }

            observationLoop: for await state in stream {
                guard self.engineGeneration == generation, self.warmUpObservationToken == observationToken else { break }
                switch state {
                case .idle:
                    self.engineState = .working(message: "Preparing...", progress: nil)
                case .working(let message, let progress):
                    self.engineState = .working(message: message, progress: progress)
                case .ready:
                    let durationSeconds = Date().timeIntervalSince(warmUpStartedAt)
                    Telemetry.send(.modelDownloadCompleted(durationSeconds: durationSeconds))
                    do {
                        try await self.prepareDiarizationModelsIfNeeded(generation: generation)
                    } catch is CancellationError {
                        break observationLoop
                    } catch {
                        guard self.engineGeneration == generation, self.warmUpObservationToken == observationToken else { break observationLoop }
                        self.engineState = .failed(message: error.localizedDescription)
                        self.isBusy = false
                        break observationLoop
                    }
                    guard self.engineGeneration == generation, self.warmUpObservationToken == observationToken else { break observationLoop }
                    self.engineState = .ready
                    self.isBusy = false
                    break observationLoop
                case .failed(let message):
                    Telemetry.send(.modelDownloadFailed(errorType: "BackgroundWarmUpError", errorDetail: message))
                    self.engineState = .failed(message: message)
                    self.isBusy = false
                    break observationLoop
                }
            }
        }
        warmUpObserverTask = outerTask
    }

    private func prepareDiarizationModelsIfNeeded(generation: Int) async throws {
        guard let diarizationService else { return }
        guard await diarizationService.isReady() == false else { return }

        engineState = .working(message: "Speaker models: downloading...", progress: nil)
        do {
            try await diarizationService.prepareModels(onProgress: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.engineGeneration == generation else { return }
                    self.engineState = .working(message: "Speaker models: \(message)", progress: nil)
                }
            })
        } catch {
            logger.error("diarization_model_prep_failed error=\(error.localizedDescription, privacy: .public)")
            Telemetry.send(.errorOccurred(
                domain: "diarization",
                code: "model_prep_failed",
                description: TelemetryErrorClassifier.errorDetail(error)
            ))
            throw error
        }
    }


    public func retryEngineWarmUp() {
        cancelWarmUpObservation()
        engineState = .idle
        startEngineWarmUp()
    }

    /// Stop observing warm-up progress (e.g., when the window closes).
    /// Does NOT cancel the shared background download.
    public func stopObservingWarmUp() {
        cancelWarmUpObservation()
        stopPermissionPolling()
    }

    private func clearMeetingRecordingPendingState() {
        screenRecordingGrantRequestedAt = nil
        showRelaunchHint = false
    }

    private func updateMeetingRecordingRelaunchHint(now currentTime: Date) {
        guard !screenRecordingGranted else {
            clearMeetingRecordingPendingState()
            return
        }

        guard step == .meetingRecording, let requestTime = screenRecordingGrantRequestedAt else {
            showRelaunchHint = false
            return
        }

        showRelaunchHint = currentTime.timeIntervalSince(requestTime) >= relaunchHintDelay
    }

    private func cancelWarmUpObservation() {
        warmUpObservationToken = nil
        warmUpObserverTask?.cancel()
        warmUpObserverTask = nil
        if let id = warmUpObserverId {
            Task { [sttClient] in await sttClient.removeWarmUpObserver(id: id) }
        }
        warmUpObserverId = nil
    }

    private func runEnginePreflight() async throws {
        guard isRuntimeSupported() else {
            throw STTError.engineStartFailed("Local model runtime requires Apple Silicon with Metal support.")
        }

        let speechModelCached = isSpeechModelCached()
        let diarizationAssetsReady = await areDiarizationAssetsReadyForOnboarding()

        guard !speechModelCached || !diarizationAssetsReady else { return }

        let (requiredDiskBytes, setupLabel, networkRequirement) =
            if speechModelCached {
                (
                    requiredDiarizationSetupDiskBytes,
                    "speaker-model setup",
                    "Internet connection is required to download speaker models. Check your network and retry."
                )
            } else {
                (
                    requiredFirstSetupDiskBytes,
                    "first-time speech model setup",
                    "Internet connection is required for first-time model download. Check your network and retry."
                )
            }

        guard let freeBytes = availableDiskBytes() else {
            throw STTError.engineStartFailed(
                "Unable to determine free disk space. Verify at least \(Self.formatGiB(requiredDiskBytes)) is available for \(setupLabel), then retry."
            )
        }

        guard freeBytes >= requiredDiskBytes else {
            throw STTError.engineStartFailed(
                "Not enough free disk space for \(setupLabel). Need at least \(Self.formatGiB(requiredDiskBytes)) (available: \(Self.formatGiB(freeBytes)))."
            )
        }

        guard await isNetworkReachable() else {
            throw STTError.engineStartFailed(networkRequirement)
        }
    }

    private func areDiarizationAssetsReadyForOnboarding() async -> Bool {
        guard let diarizationService else { return true }
        return await diarizationService.hasCachedModels()
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
