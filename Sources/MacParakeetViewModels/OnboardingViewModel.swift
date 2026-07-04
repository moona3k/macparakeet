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
    public typealias WhisperModelDownloader = @Sendable (
        _ model: String,
        _ onProgress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void
    ) async throws -> Void

    public struct WhisperOnboardingRecommendation: Sendable, Equatable {
        public let languageCode: String
        public let languageName: String
    }

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

        public var telemetryName: String {
            switch self {
            case .welcome: return "welcome"
            case .microphone: return "microphone"
            case .accessibility: return "accessibility"
            case .hotkey: return "hotkey"
            case .engine: return "speech_model"
            case .done: return "ready"
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
    public private(set) var whisperRecommendation: WhisperOnboardingRecommendation?

    /// True while a *permission request* is in flight. The Microphone /
    /// Accessibility grant buttons disable on this.
    public var isBusy: Bool = false

    /// True while a speech-model warm-up is in flight. Kept separate from
    /// `isBusy` so the Part B head-start download — which can start at
    /// onboarding open — never disables the permission grant buttons. The engine
    /// step shows its own progress from `engineState`, not this flag.
    /// See plans/active/2026-05-dictation-first-onboarding.md §5.1.
    public private(set) var engineBusy: Bool = false

    private let permissionService: PermissionServiceProtocol
    private let sttClient: STTClientProtocol
    private let speechEngineSwitcher: SpeechEngineSwitching?
    private let diarizationService: DiarizationServiceProtocol?
    private let isRuntimeSupported: @Sendable () -> Bool
    private let availableDiskBytes: @Sendable () -> Int64?
    private let isNetworkReachable: @Sendable () async -> Bool
    private let isSpeechModelCached: @Sendable () -> Bool
    private let isWhisperModelDownloaded: @Sendable () -> Bool
    private let downloadWhisperModel: WhisperModelDownloader
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var startedAt: Date
    private let permissionPollingInterval: Duration
    private let warmUpStallTimeout: Duration
    private var didEmitInitialStep = false
    private var completionForCurrentRun: Completion?
    private var engineGeneration: Int = 0
    private var refreshTask: Task<Void, Never>?
    private var permissionPollingTask: Task<Void, Never>?
    private var warmUpObserverTask: Task<Void, Never>?
    private var warmUpObserverId: UUID?
    private var warmUpObservationToken: UUID?
    private var warmUpStallWatchdogTask: Task<Void, Never>?

    /// How long to wait between warm-up progress events before declaring the
    /// stream stalled. FluidAudio emits progress updates regularly during
    /// download even when bytes-per-second is low, so silence longer than
    /// this strongly suggests a stuck connection or a hung dependency.
    /// Memory: v0.4.22 stranded ~23 users for ~24h with no escape hatch.
    /// `nonisolated` so it can be referenced from the `init` parameter default
    /// (a nonisolated context) without the Swift-5-mode concurrency warning — a
    /// `Sendable` `Duration` constant is safe to read from anywhere (and the
    /// Swift 6 language mode already treats it this way via SE-0434).
    public nonisolated static let warmUpStallTimeout: Duration = .seconds(180)
    private let requiredFirstSetupDiskBytes: Int64 = 7 * 1_024 * 1_024 * 1_024
    private let requiredDiarizationSetupDiskBytes: Int64 = 512 * 1_024 * 1_024
    private let requiredWhisperSetupDiskBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    public nonisolated static let onboardingCompletedKey = "onboarding.completedAtISO"

    public init(
        permissionService: PermissionServiceProtocol,
        sttClient: STTClientProtocol,
        speechEngineSwitcher: SpeechEngineSwitching? = nil,
        diarizationService: DiarizationServiceProtocol? = nil,
        isRuntimeSupported: (@Sendable () -> Bool)? = nil,
        availableDiskBytes: (@Sendable () -> Int64?)? = nil,
        isNetworkReachable: (@Sendable () async -> Bool)? = nil,
        isSpeechModelCached: (@Sendable () -> Bool)? = nil,
        isWhisperModelDownloaded: (@Sendable () -> Bool)? = nil,
        downloadWhisperModel: WhisperModelDownloader? = nil,
        preferredLanguages: (@Sendable () -> [String])? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        permissionPollingInterval: Duration = .seconds(2),
        warmUpStallTimeout: Duration = OnboardingViewModel.warmUpStallTimeout
    ) {
        self.permissionService = permissionService
        self.sttClient = sttClient
        self.speechEngineSwitcher = speechEngineSwitcher ?? (sttClient as? SpeechEngineSwitching)
        self.diarizationService = diarizationService
        self.isRuntimeSupported = isRuntimeSupported ?? { Self.defaultRuntimeSupportedCheck() }
        self.availableDiskBytes = availableDiskBytes ?? { Self.defaultAvailableDiskBytes() }
        self.isNetworkReachable = isNetworkReachable ?? { await Self.defaultNetworkReachabilityCheck() }
        self.isSpeechModelCached = isSpeechModelCached ?? { STTRuntime.isModelCached() }
        self.isWhisperModelDownloaded = isWhisperModelDownloaded ?? {
            WhisperEngine.isModelDownloaded(model: SpeechEnginePreference.whisperModelVariant())
        }
        self.downloadWhisperModel = downloadWhisperModel ?? { model, progress in
            _ = try await WhisperEngine.downloadModel(model: model, onProgress: progress)
        }
        self.defaults = defaults
        self.now = now
        self.startedAt = now()
        self.permissionPollingInterval = permissionPollingInterval
        self.warmUpStallTimeout = warmUpStallTimeout
        self.whisperRecommendation = Self.recommendedWhisperLanguage(
            preferredLanguages: (preferredLanguages ?? { Locale.preferredLanguages })()
        )
    }

    public var hasCompletedOnboarding: Bool {
        defaults.string(forKey: Self.onboardingCompletedKey) != nil
    }

    public func markOnboardingCompleted() -> Completion {
        if let completionForCurrentRun {
            return completionForCurrentRun
        }

        let completedAt = now()
        let iso = ISO8601DateFormatter().string(from: completedAt)
        defaults.set(iso, forKey: Self.onboardingCompletedKey)
        let durationSeconds = completedAt.timeIntervalSince(startedAt)
        sendStepTelemetry(step: .done, action: .completed, at: completedAt)
        Telemetry.send(.onboardingCompleted(durationSeconds: durationSeconds))
        let completion = Completion(completedAt: completedAt)
        completionForCurrentRun = completion
        return completion
    }

    public func markOnboardingShown() {
        guard !didEmitInitialStep else { return }
        didEmitInitialStep = true
        sendStepTelemetry(step: step, action: .viewed)
    }

    public func markOnboardingDismissed() {
        sendStepTelemetry(step: step, action: .dismissed)
    }

    public func resetOnboarding() {
        defaults.removeObject(forKey: Self.onboardingCompletedKey)
        step = .welcome
        engineState = .idle
        startedAt = now()
        didEmitInitialStep = false
        completionForCurrentRun = nil
    }

    public func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            let mic = await permissionService.checkMicrophonePermission()
            let ax = permissionService.checkAccessibilityPermission()
            guard !Task.isCancelled else { return }
            // The class is @MainActor, so this Task already runs on the main
            // actor — assign directly rather than hopping through MainActor.run.
            self.micStatus = mic
            self.accessibilityGranted = ax
            self.refreshTask = nil
        }
    }

    /// Steps the user actually sees in the dictation-first onboarding flow.
    public static var visibleSteps: [Step] {
        [.welcome, .microphone, .accessibility, .hotkey, .engine, .done]
    }

    public func goNext() {
        let visible = Self.visibleSteps
        let currentRaw = step.rawValue
        guard let next = visible.first(where: { $0.rawValue > currentRaw }) else { return }
        step = next
        sendStepTelemetry(step: next, action: .forward)
        refresh()
    }

    public func goBack() {
        let visible = Self.visibleSteps
        let currentRaw = step.rawValue
        guard let prev = visible.last(where: { $0.rawValue < currentRaw }) else { return }
        step = prev
        sendStepTelemetry(step: prev, action: .back)
        refresh()
    }

    public func jump(to target: Step) {
        step = target
        sendStepTelemetry(step: target, action: .jump)
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

    /// Apply a warm-up failure to `engineState`, surfacing the terminal
    /// `.failed` **only** once the user is on the Speech Model step. Part B kicks
    /// the warm-up off at onboarding open, so a failure can land while the user
    /// is still granting permissions — showing a failed card on those steps (or
    /// flashing one the instant the engine step appears) would be wrong. Before
    /// the engine step we reset to `.idle`; the engine step's `.onAppear` then
    /// retries `startEngineWarmUp()` cleanly. Always clears `engineBusy`.
    /// See plans/active/2026-05-dictation-first-onboarding.md §5.3.
    private func applyEngineWarmUpFailure(_ message: String) {
        engineBusy = false
        engineState = (step == .engine) ? .failed(message: message) : .idle
        if step == .engine {
            sendStepTelemetry(step: .engine, action: .engineFailed, engineState: "failed")
        }
    }

    public func startEngineWarmUp() {
        // If already observing or completed, don't restart
        if case .ready = engineState { return }
        // Don't auto-restart from a surfaced failure. Only `retryEngineWarmUp()`
        // (which resets to `.idle` first) restarts. This matters because Part B
        // calls this from two sites (onboarding-open + the engine step's
        // `.onAppear`): if a head-start failure surfaces right as the engine step
        // appears — clearing `warmUpObserverTask` just before `.onAppear` fires —
        // the step would otherwise silently kick off a second attempt instead of
        // showing the user the Retry button.
        if case .failed = engineState { return }
        if warmUpObserverTask != nil { return }

        if let whisperRecommendation {
            startRecommendedWhisperSetup(recommendation: whisperRecommendation)
            return
        }

        engineGeneration += 1
        let generation = engineGeneration
        let observationToken = UUID()
        engineBusy = true
        engineState = .working(message: "Checking setup requirements...", progress: nil)
        warmUpObservationToken = observationToken
        resetWarmUpStallWatchdog(generation: generation, observationToken: observationToken)

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
                self.warmUpStallWatchdogTask?.cancel()
                self.warmUpStallWatchdogTask = nil
                if let observerId {
                    Task { [sttClient] in await sttClient.removeWarmUpObserver(id: observerId) }
                }
            }

            do {
                try await runEnginePreflight()
                guard self.engineGeneration == generation, self.warmUpObservationToken == observationToken else { return }
            } catch {
                guard self.engineGeneration == generation, self.warmUpObservationToken == observationToken else { return }
                self.applyEngineWarmUpFailure(error.localizedDescription)
                clearObservationIfCurrent(nil)
                return
            }

            // Part B head-start: with the early trigger this fires at onboarding
            // open rather than on the Speech Model step. The duration metric
            // (warmUpStartedAt → .ready) still measures real download+load time —
            // the background download runs independent of which step the user is
            // on, so the user's think-time overlaps it rather than inflating it.
            // Note: modelDownloadStarted/modelDownloadFailed are attempt-counts,
            // not session-counts — a transient failure before the engine step is
            // suppressed (reset to .idle) and silently re-attempted there, so one
            // session can emit started×2 / failed×1. modelDownloadCompleted still
            // fires once (only on the successful attempt's .ready). See §5.4.
            let warmUpStartedAt = Date()
            Telemetry.send(.modelDownloadStarted(
                modelKind: .localSpeechStack,
                speechEngine: .parakeet
            ))
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
                // Each event resets the stall-watchdog clock. If this loop
                // doesn't iterate again within `warmUpStallTimeout`, the
                // watchdog transitions to .failed and cancels observation.
                self.resetWarmUpStallWatchdog(generation: generation, observationToken: observationToken)
                switch state {
                case .idle:
                    self.engineState = .working(message: "Preparing...", progress: nil)
                case .working(let message, let progress):
                    self.engineState = .working(message: message, progress: progress)
                case .ready:
                    let durationSeconds = Date().timeIntervalSince(warmUpStartedAt)
                    Telemetry.send(.modelDownloadCompleted(
                        durationSeconds: durationSeconds,
                        modelKind: .localSpeechStack,
                        speechEngine: .parakeet
                    ))
                    do {
                        try await self.prepareDiarizationModelsIfNeeded(generation: generation)
                    } catch is CancellationError {
                        break observationLoop
                    } catch {
                        guard self.engineGeneration == generation, self.warmUpObservationToken == observationToken else { break observationLoop }
                        self.applyEngineWarmUpFailure(error.localizedDescription)
                        break observationLoop
                    }
                    guard self.engineGeneration == generation, self.warmUpObservationToken == observationToken else { break observationLoop }
                    self.engineState = .ready
                    self.engineBusy = false
                    self.sendStepTelemetry(step: .engine, action: .engineReady, engineState: "ready")
                    break observationLoop
                case .failed(let message):
                    Telemetry.send(.modelDownloadFailed(
                        errorType: "BackgroundWarmUpError",
                        errorDetail: message,
                        modelKind: .localSpeechStack,
                        speechEngine: .parakeet
                    ))
                    self.applyEngineWarmUpFailure(message)
                    break observationLoop
                }
            }
        }
        warmUpObserverTask = outerTask
    }

    private func startRecommendedWhisperSetup(recommendation: WhisperOnboardingRecommendation) {
        engineGeneration += 1
        let generation = engineGeneration
        engineBusy = true
        engineState = .working(message: "Checking Whisper setup requirements...", progress: nil)

        let outerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.engineGeneration == generation {
                    self.warmUpObserverTask = nil
                }
            }

            do {
                try await self.runWhisperPreflightIfNeeded()
                guard self.engineGeneration == generation else { return }

                let modelVariant = SpeechEnginePreference.whisperModelVariant(defaults: self.defaults)
                if !self.isWhisperModelDownloaded() {
                    try await self.downloadRecommendedWhisperModel(
                        modelVariant: modelVariant,
                        generation: generation
                    )
                    guard self.engineGeneration == generation else { return }
                }

                SpeechEnginePreference.saveWhisperDefaultLanguage(
                    recommendation.languageCode,
                    defaults: self.defaults
                )
                Telemetry.send(.settingChanged(setting: .whisperDefaultLanguage))

                try await self.activateWhisperEngine(generation: generation)
                guard self.engineGeneration == generation else { return }

                try await self.prepareDiarizationModelsIfNeeded(generation: generation)
                guard self.engineGeneration == generation else { return }

                self.engineState = .ready
                self.engineBusy = false
                self.sendStepTelemetry(step: .engine, action: .engineReady, engineState: "ready")
            } catch is CancellationError {
                guard self.engineGeneration == generation else { return }
                self.engineState = .idle
                self.engineBusy = false
            } catch {
                guard self.engineGeneration == generation else { return }
                self.applyEngineWarmUpFailure(error.localizedDescription)
            }
        }
        warmUpObserverTask = outerTask
    }

    private func downloadRecommendedWhisperModel(
        modelVariant: String,
        generation: Int
    ) async throws {
        let friendly = SpeechEnginePreference.friendlyVariantName(modelVariant)
        let operationContext = Observability.childOperationContext()
        engineState = .working(message: "Downloading Whisper \(friendly)...", progress: nil)
        Telemetry.send(.modelDownloadStarted(
            modelKind: .whisperSTT,
            speechEngine: .whisper,
            engineVariant: modelVariant
        ))

        do {
            try await downloadWhisperModel(modelVariant) { [weak self] completed, total in
                let percent = total > 0 ? Double(completed) / Double(total) : 0
                Task { @MainActor [weak self] in
                    guard let self, self.engineGeneration == generation else { return }
                    let clamped = min(max(percent, 0), 1)
                    self.engineState = .working(
                        message: "Downloading Whisper \(friendly)... \(Int((clamped * 100).rounded()))%",
                        progress: clamped
                    )
                }
            }
            let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
            Telemetry.send(.modelDownloadCompleted(
                durationSeconds: durationSeconds,
                modelKind: .whisperSTT,
                speechEngine: .whisper,
                engineVariant: modelVariant
            ))
            Telemetry.send(.modelOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                action: .download,
                outcome: .success,
                stage: .download,
                modelKind: .whisperSTT,
                speechEngine: .whisper,
                engineVariant: modelVariant,
                durationSeconds: durationSeconds,
                errorType: nil
            ))
        } catch is CancellationError {
            let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
            Telemetry.send(.modelOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                action: .download,
                outcome: .cancelled,
                stage: .download,
                modelKind: .whisperSTT,
                speechEngine: .whisper,
                engineVariant: modelVariant,
                durationSeconds: durationSeconds,
                errorType: "CancellationError"
            ))
            throw CancellationError()
        } catch {
            let durationSeconds = Observability.durationSeconds(since: operationContext.startedAt)
            let errorType = TelemetryErrorClassifier.classify(error)
            Telemetry.send(.modelDownloadFailed(
                errorType: errorType,
                errorDetail: TelemetryErrorClassifier.errorDetail(error),
                modelKind: .whisperSTT,
                speechEngine: .whisper,
                engineVariant: modelVariant
            ))
            Telemetry.send(.modelOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                action: .download,
                outcome: .failure,
                stage: .download,
                modelKind: .whisperSTT,
                speechEngine: .whisper,
                engineVariant: modelVariant,
                durationSeconds: durationSeconds,
                errorType: errorType
            ))
            throw error
        }
    }

    private func activateWhisperEngine(generation: Int) async throws {
        guard let speechEngineSwitcher else {
            SpeechEnginePreference.whisper.save(to: defaults)
            return
        }

        let previousPreference = SpeechEnginePreference.current(defaults: defaults)
        let operationContext = Observability.childOperationContext()
        let switchWasCold = SpeechEnginePreference.isColdSwitch(to: .whisper, defaults: defaults)
        engineState = .working(message: "Preparing Whisper for this Mac...", progress: nil)

        do {
            try await Observability.withOperationContext(operationContext) {
                try await speechEngineSwitcher.setSpeechEngine(.whisper) { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.engineGeneration == generation else { return }
                        self.engineState = .working(message: message, progress: nil)
                    }
                }
                if await sttClient.isReady() == false {
                    try await sttClient.warmUp { [weak self] message in
                        Task { @MainActor [weak self] in
                            guard let self, self.engineGeneration == generation else { return }
                            self.engineState = .working(message: "Whisper: \(message)", progress: nil)
                        }
                    }
                }
            }
            SpeechEnginePreference.whisper.save(to: defaults)
            Telemetry.send(.speechEngineSwitchOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                fromEngine: previousPreference,
                toEngine: .whisper,
                outcome: .success,
                durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                blockedReason: nil,
                errorType: nil,
                wasCold: switchWasCold
            ))
        } catch {
            let errorType = TelemetryErrorClassifier.classify(error)
            Telemetry.send(.speechEngineSwitchOperation(
                operationID: operationContext.operationID,
                operationContext: operationContext,
                fromEngine: previousPreference,
                toEngine: .whisper,
                outcome: error is CancellationError ? .cancelled : .failure,
                durationSeconds: Observability.durationSeconds(since: operationContext.startedAt),
                blockedReason: Self.telemetrySpeechEngineSwitchBlockedReason(for: error),
                errorType: errorType,
                wasCold: switchWasCold
            ))
            throw error
        }
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

    private func cancelWarmUpObservation() {
        warmUpObservationToken = nil
        // Clear `engineBusy` here so it never outlives the observation. The
        // cancelled `warmUpObserverTask`'s `defer { clearObservationIfCurrent }`
        // bails on the now-nil `warmUpObservationToken`, so it never reaches a
        // busy-clearing terminal state — without this line a window close mid
        // warm-up (`stopObservingWarmUp()`) would leak `engineBusy == true`,
        // violating the flag's "true while a warm-up is in flight" contract.
        // Safe for the other callers too: `retryEngineWarmUp()` re-sets it in the
        // immediately-following `startEngineWarmUp()`, and the stall watchdog
        // already cleared it via `applyEngineWarmUpFailure`.
        engineBusy = false
        warmUpStallWatchdogTask?.cancel()
        warmUpStallWatchdogTask = nil
        warmUpObserverTask?.cancel()
        warmUpObserverTask = nil
        if let id = warmUpObserverId {
            Task { [sttClient] in await sttClient.removeWarmUpObserver(id: id) }
        }
        warmUpObserverId = nil
    }

    private func sendStepTelemetry(
        step: Step,
        action: TelemetryOnboardingAction,
        at date: Date? = nil,
        engineState explicitEngineState: String? = nil
    ) {
        let visible = Self.visibleSteps
        let stepIndex = visible.firstIndex(of: step).map { $0 + 1 }
        let engineState = explicitEngineState ?? {
            guard step == .engine else { return nil }
            switch self.engineState {
            case .idle: return "idle"
            case .working: return "working"
            case .ready: return "ready"
            case .failed: return "failed"
            }
        }()
        let elapsedSeconds = (date ?? now()).timeIntervalSince(startedAt)

        Telemetry.send(.onboardingStep(
            step: step.telemetryName,
            action: action,
            elapsedSeconds: elapsedSeconds,
            stepIndex: stepIndex,
            totalSteps: visible.count,
            engineState: engineState
        ))
    }

    /// Schedule (or reschedule) the warm-up stall watchdog. Cancels any
    /// previously-running watchdog. If the new timer expires before another
    /// stream event resets it, transitions `engineState` to `.failed` with a
    /// retry-able message and cancels the warm-up observation.
    /// Generation + observationToken guard so a stale watchdog from a previous
    /// `startEngineWarmUp` call cannot overwrite a newer attempt.
    private func resetWarmUpStallWatchdog(generation: Int, observationToken: UUID) {
        warmUpStallWatchdogTask?.cancel()
        // Capture the (injectable) instance timeout before entering the Task so
        // both the sleep and the log use the configured value, not the static default.
        let stallTimeout = warmUpStallTimeout
        warmUpStallWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: stallTimeout)
            guard !Task.isCancelled, let self else { return }
            guard self.engineGeneration == generation,
                  self.warmUpObservationToken == observationToken else { return }
            // No progress event for `warmUpStallTimeout`. Declare stuck.
            let stallSeconds = Int(stallTimeout.components.seconds)
            let detail = "no warm-up progress for \(stallSeconds)s"
            self.logger.error("warm_up_stall_detected detail=\(detail, privacy: .public)")
            Telemetry.send(.modelDownloadFailed(
                errorType: "WarmUpStalled",
                errorDetail: detail,
                modelKind: .localSpeechStack,
                speechEngine: .parakeet
            ))
            self.applyEngineWarmUpFailure(
                "Setup is taking longer than expected. Check your network connection and tap Retry."
            )
            self.cancelWarmUpObservation()
        }
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

    private func runWhisperPreflightIfNeeded() async throws {
        guard isRuntimeSupported() else {
            throw STTError.engineStartFailed("Local model runtime requires Apple Silicon with Metal support.")
        }

        let whisperDownloaded = isWhisperModelDownloaded()
        let diarizationAssetsReady = await areDiarizationAssetsReadyForOnboarding()
        guard !whisperDownloaded || !diarizationAssetsReady else { return }

        guard let freeBytes = availableDiskBytes() else {
            let requiredDiskBytes = whisperDownloaded ? requiredDiarizationSetupDiskBytes : requiredWhisperSetupDiskBytes
            throw STTError.engineStartFailed(
                "Unable to determine free disk space. Verify at least \(Self.formatGiB(requiredDiskBytes)) is available for multilingual setup, then retry."
            )
        }

        let requiredDiskBytes =
            (whisperDownloaded ? 0 : requiredWhisperSetupDiskBytes)
            + (diarizationAssetsReady ? 0 : requiredDiarizationSetupDiskBytes)
        guard freeBytes >= requiredDiskBytes else {
            throw STTError.engineStartFailed(
                "Not enough free disk space for multilingual setup. Need at least \(Self.formatGiB(requiredDiskBytes)) (available: \(Self.formatGiB(freeBytes)))."
            )
        }

        guard await isNetworkReachable() else {
            let networkRequirement = whisperDownloaded
                ? "Internet connection is required to download speaker models. Check your network and retry."
                : "Internet connection is required to download the Whisper model. Check your network and retry."
            throw STTError.engineStartFailed(
                networkRequirement
            )
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

    public nonisolated static func recommendedWhisperLanguage(
        preferredLanguages: [String]
    ) -> WhisperOnboardingRecommendation? {
        let cjkWhisperLanguageCodes: Set<String> = ["ko", "ja", "zh", "yue"]
        let normalizedLanguages = preferredLanguages.compactMap {
            SpeechEnginePreference.normalizeKnownLanguage($0)
        }
        guard !normalizedLanguages.contains("en") else {
            return nil
        }

        for code in normalizedLanguages where cjkWhisperLanguageCodes.contains(code) {
            return WhisperOnboardingRecommendation(
                languageCode: code,
                languageName: WhisperLanguageCatalog.displayLabel(for: code)
            )
        }
        return nil
    }

    private static func telemetrySpeechEngineSwitchBlockedReason(
        for error: Error
    ) -> TelemetrySpeechEngineSwitchBlockedReason? {
        guard let sttError = error as? STTError else { return nil }
        switch sttError {
        case .engineBusy:
            return .engineBusy
        case .modelDownloadFailed, .modelNotLoaded:
            return .modelNotDownloaded
        case .engineNotRunning,
             .engineStartFailed,
             .transcriptionFailed,
             .timeout,
             .outOfMemory,
             .invalidResponse:
            return nil
        }
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
