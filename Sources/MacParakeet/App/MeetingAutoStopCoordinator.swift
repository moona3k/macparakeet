import AppKit
import MacParakeetCore
import MacParakeetViewModels
import OSLog

/// ADR-023 app-layer owner. It observes meeting-end signals only while a
/// recording is active and the opt-in setting is enabled, runs grace clocks,
/// shows the veto countdown, then asks the meeting flow to run its normal stop.
@MainActor
final class MeetingAutoStopCoordinator {
    typealias StopReason = MeetingAutoStopPolicy.StopReason

    private let settingsViewModel: SettingsViewModel
    private let isRecordingActive: @MainActor () -> Bool
    private let isPaused: @MainActor () async -> Bool
    private let runningMeetingAppsProvider: @MainActor () -> Set<String>
    private let audioLevelsProvider: @MainActor () async -> MeetingAudioLevels
    private let onAutoStopConfirmed: @MainActor (StopReason) -> Bool
    private let showCountdown: @MainActor (_ reason: StopReason, _ onOutcome: @escaping (MeetingCountdownToastOutcome) -> Void) -> Void
    private let closeCountdown: @MainActor () -> Void
    private let featureEnabled: Bool
    private let config: MeetingAutoStopPolicy.Config
    private let pollInterval: TimeInterval
    private let silenceLevelThreshold: Float
    private let logger = Logger(subsystem: "com.macparakeet", category: "MeetingAutoStop")

    private var context: MeetingAutoStopPolicy.MeetingContext?
    private var silenceStartedAt: Date?
    private var signalFirstSeenAt: [StopReason: Date] = [:]
    private var vetoedReasons: Set<StopReason> = []
    private var countdownReason: StopReason?
    private var isEvaluating = false
    private var observationGeneration = 0

    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var appTerminationObserver: NSObjectProtocol?
    nonisolated(unsafe) private var signalTimer: Timer?

    init(
        settingsViewModel: SettingsViewModel,
        isRecordingActive: @escaping @MainActor () -> Bool,
        isPaused: @escaping @MainActor () async -> Bool,
        runningMeetingAppsProvider: @escaping @MainActor () -> Set<String> = {
            Set(NSWorkspace.shared.runningApplications.compactMap { app in
                guard let bundleID = app.bundleIdentifier,
                      MeetingAppRegistry.isRecognizedNativeApp(bundleID: bundleID) else {
                    return nil
                }
                return bundleID
            })
        },
        audioLevelsProvider: @escaping @MainActor () async -> MeetingAudioLevels,
        onAutoStopConfirmed: @escaping @MainActor (StopReason) -> Bool,
        toastController: MeetingCountdownToastController? = nil,
        showCountdown: (@MainActor (_ reason: StopReason, _ onOutcome: @escaping (MeetingCountdownToastOutcome) -> Void) -> Void)? = nil,
        closeCountdown: (@MainActor () -> Void)? = nil,
        featureEnabled: Bool = AppFeatures.meetingAutoStopEnabled,
        config: MeetingAutoStopPolicy.Config = .default,
        countdownDuration: TimeInterval = 15,
        pollInterval: TimeInterval = 1,
        silenceLevelThreshold: Float = 0.02
    ) {
        self.settingsViewModel = settingsViewModel
        self.isRecordingActive = isRecordingActive
        self.isPaused = isPaused
        self.runningMeetingAppsProvider = runningMeetingAppsProvider
        self.audioLevelsProvider = audioLevelsProvider
        self.onAutoStopConfirmed = onAutoStopConfirmed
        let toastController = toastController ?? MeetingCountdownToastController()
        self.showCountdown = showCountdown ?? { reason, onOutcome in
            toastController.showAutoStop(
                title: Self.countdownTitle(for: reason),
                duration: countdownDuration,
                onOutcome: onOutcome
            )
        }
        self.closeCountdown = closeCountdown ?? {
            toastController.close()
        }
        self.featureEnabled = featureEnabled
        self.config = config
        self.pollInterval = pollInterval
        self.silenceLevelThreshold = silenceLevelThreshold
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
        }
        signalTimer?.invalidate()
    }

    func start() {
        guard featureEnabled, AppFeatures.meetingRecordingEnabled else { return }
        registerSettingsObserver()
        refreshSignalObservation(now: Date())
        logger.info("Meeting auto-stop coordinator started")
    }

    func stop() {
        stopSignalObservation(clearSession: true)
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        logger.info("Meeting auto-stop coordinator stopped")
    }

    func recordingDidStart(now: Date = Date()) {
        refreshSignalObservation(now: now)
    }

    func recordingDidEnd() {
        stopSignalObservation(clearSession: true)
    }

    // MARK: - Observers

    private func registerSettingsObserver() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetMeetingAutoStopDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSignalObservation(now: Date())
            }
        }
    }

    private func registerAppTerminationObserver() {
        guard appTerminationObserver == nil else { return }
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  MeetingAppRegistry.isRecognizedNativeApp(bundleID: bundleID) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.context?.observedMeetingAppBundleIDs.insert(bundleID)
                await self?.evaluate(now: Date())
            }
        }
    }

    private func refreshSignalObservation(now: Date) {
        guard shouldObserveSignals else {
            stopSignalObservation(clearSession: true)
            return
        }

        if context == nil {
            startSignalObservation(now: now)
        } else if signalTimer == nil || appTerminationObserver == nil {
            startSignalInfrastructure()
        }
    }

    private func startSignalObservation(now: Date) {
        observationGeneration &+= 1
        let running = runningMeetingAppsProvider()
        context = MeetingAutoStopPolicy.MeetingContext(
            observedMeetingAppBundleIDs: running,
            startedAt: now
        )
        silenceStartedAt = nil
        signalFirstSeenAt = [:]
        vetoedReasons = []
        countdownReason = nil
        startSignalInfrastructure()
        Task { @MainActor [weak self] in await self?.evaluate(now: now) }
    }

    private func startSignalInfrastructure() {
        registerAppTerminationObserver()
        guard signalTimer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.evaluate(now: Date()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        signalTimer = timer
    }

    private func stopSignalObservation(clearSession: Bool) {
        observationGeneration &+= 1
        signalTimer?.invalidate()
        signalTimer = nil
        if let appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
            self.appTerminationObserver = nil
        }
        closeCountdown()
        countdownReason = nil
        silenceStartedAt = nil
        signalFirstSeenAt = [:]
        if clearSession {
            context = nil
            vetoedReasons = []
        }
    }

    // MARK: - Evaluation

    private func evaluate(now: Date) async {
        // App notifications update `context` before calling this, so a dropped
        // overlapping evaluation is picked up by the next timer tick without
        // stacking async audio-level reads on the main actor.
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }

        guard let decision = await currentDecision(now: now) else { return }
        handle(decision: decision, now: now)
    }

    private func currentDecision(now: Date) async -> MeetingAutoStopPolicy.Decision? {
        let generation = observationGeneration
        guard var activeContext = context else { return nil }
        guard shouldObserveSignals else {
            stopSignalObservation(clearSession: true)
            return nil
        }

        let running = runningMeetingAppsProvider()
        activeContext.observedMeetingAppBundleIDs.formUnion(running)
        context = activeContext

        let paused = await isPaused()
        let levels = await audioLevelsProvider()
        guard isCurrentObservation(generation) else { return nil }
        let continuousSilenceSeconds = updateSilenceDuration(
            now: now,
            levels: levels,
            isPaused: paused
        )

        let decision = MeetingAutoStopPolicy.evaluate(
            context: activeContext,
            observation: MeetingAutoStopPolicy.Observation(
                now: now,
                isRecording: true,
                isPaused: paused,
                runningMeetingAppBundleIDs: running,
                continuousSilenceSeconds: continuousSilenceSeconds
            ),
            config: config
        )
        return decision
    }

    private var shouldObserveSignals: Bool {
        featureEnabled && settingsViewModel.meetingAutoStopEnabled && isRecordingActive()
    }

    private func isCurrentObservation(_ generation: Int) -> Bool {
        guard generation == observationGeneration else { return false }
        guard shouldObserveSignals else {
            stopSignalObservation(clearSession: true)
            return false
        }
        return context != nil
    }

    private func updateSilenceDuration(
        now: Date,
        levels: MeetingAudioLevels,
        isPaused: Bool
    ) -> TimeInterval {
        guard !isPaused,
              levels.microphone <= silenceLevelThreshold,
              levels.system <= silenceLevelThreshold else {
            silenceStartedAt = nil
            return 0
        }

        guard let startedAt = silenceStartedAt else {
            silenceStartedAt = now
            return 0
        }

        return max(0, now.timeIntervalSince(startedAt))
    }

    private func handle(decision: MeetingAutoStopPolicy.Decision, now: Date) {
        switch decision {
        case .keepRecording:
            signalFirstSeenAt = [:]
            if countdownReason != nil {
                closeCountdown()
                countdownReason = nil
            }

        case .proposeStop(let reason):
            guard !vetoedReasons.contains(reason) else {
                suppressSignal(for: reason)
                return
            }
            guard graceElapsed(for: reason, now: now) else { return }
            guard countdownReason != reason else { return }
            if countdownReason != nil {
                closeCountdown()
            }
            countdownReason = reason
            Telemetry.send(.meetingAutoStopProposed(reason: reason.telemetryReason))
            showCountdown(reason) { [weak self] outcome in
                self?.handleCountdownOutcome(outcome, reason: reason)
            }
        }
    }

    private func graceElapsed(for reason: StopReason, now: Date) -> Bool {
        let grace: TimeInterval = switch reason {
        case .meetingAppClosed:
            config.appQuitGraceSeconds
        case .prolongedSilence:
            0
        }
        guard grace > 0 else { return true }
        guard let firstSeenAt = signalFirstSeenAt[reason] else {
            signalFirstSeenAt[reason] = now
            return false
        }
        return now.timeIntervalSince(firstSeenAt) >= grace
    }

    private func handleCountdownOutcome(_ outcome: MeetingCountdownToastOutcome, reason: StopReason) {
        guard countdownReason == reason else { return }
        countdownReason = nil

        switch outcome {
        case .completed, .primedEarly:
            guard shouldObserveSignals else {
                return
            }
            let generation = observationGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let decision = await self.currentDecision(now: Date()),
                      self.isCurrentObservation(generation),
                      case .proposeStop(let currentReason) = decision,
                      currentReason == reason else {
                    self.signalFirstSeenAt = [:]
                    return
                }
                if self.onAutoStopConfirmed(reason) {
                    Telemetry.send(.meetingAutoStopConfirmed(reason: reason.telemetryReason))
                    self.stopSignalObservation(clearSession: true)
                } else if !self.isRecordingActive() {
                    self.stopSignalObservation(clearSession: true)
                }
            }
        case .userDismissed:
            vetoedReasons.insert(reason)
            suppressSignal(for: reason)
            Telemetry.send(.meetingAutoStopVetoed(reason: reason.telemetryReason))
        case .programmaticClose:
            return
        }
    }

    private func suppressSignal(for reason: StopReason) {
        signalFirstSeenAt.removeValue(forKey: reason)
        switch reason {
        case .meetingAppClosed(let bundleID):
            context?.observedMeetingAppBundleIDs.remove(bundleID)
        case .prolongedSilence:
            break
        }
    }

    private static func countdownTitle(for reason: StopReason) -> String {
        switch reason {
        case .meetingAppClosed:
            return "Meeting app closed"
        case .prolongedSilence:
            return "This meeting looks finished"
        }
    }
}

extension MeetingAutoStopCoordinator {
    var testHook_isSignalObservationActive: Bool {
        signalTimer != nil || appTerminationObserver != nil
    }

    var testHook_context: MeetingAutoStopPolicy.MeetingContext? {
        context
    }

    var testHook_countdownReason: StopReason? {
        countdownReason
    }

    var testHook_vetoedReasons: Set<StopReason> {
        vetoedReasons
    }

    func testHook_forceEvaluate(now: Date) async {
        await evaluate(now: now)
    }

    func testHook_handleCountdownOutcome(_ outcome: MeetingCountdownToastOutcome, reason: StopReason) {
        handleCountdownOutcome(outcome, reason: reason)
    }

    func testHook_recordAppTerminated(bundleID: String, now: Date = Date()) async {
        guard MeetingAppRegistry.isRecognizedNativeApp(bundleID: bundleID) else { return }
        context?.observedMeetingAppBundleIDs.insert(bundleID)
        await evaluate(now: now)
    }
}
