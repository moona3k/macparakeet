import AppKit
import MacParakeetCore
import MacParakeetViewModels

protocol AudioProcessActivityCollecting: AnyObject {
    func start(handler: @escaping @Sendable (ProcessAudioSnapshot) -> Void)
    func stop()
    func snapshot() -> ProcessAudioSnapshot
}

extension AudioProcessActivityCollector: AudioProcessActivityCollecting {}

enum MeetingActivityPromptOutcome: Sendable {
    case accepted
    case declined
}

/// Owns metadata observation and the nonactivating recording offer. Polling is
/// intentional: neither a stable microphone nor a stable URL emits a new event
/// when the candidate's dwell time elapses.
@MainActor
final class MeetingActivityDetectionCoordinator {
    typealias PromptPresenter =
        @MainActor (
            MeetingPromptCandidate,
            @escaping @MainActor (MeetingActivityPromptOutcome) -> Void
        ) -> Void

    private let settingsViewModel: SettingsViewModel
    private let audioCollector: any AudioProcessActivityCollecting
    private let meetingURLProvider: @Sendable () async -> BrowserMeetingObservation
    private let isRecordingActive: @MainActor () -> Bool
    private let isDictationActive: @MainActor () -> Bool
    private let onRecordingConfirmed: @MainActor () -> Int?
    private let showPrompt: PromptPresenter
    private let closePrompt: @MainActor () -> Void
    private let featureEnabled: Bool
    private let pollInterval: TimeInterval
    private let nowProvider: @MainActor () -> Date
    private var policy: MeetingActivityPromptPolicy
    private var presentedID: String?
    private var presentationToken: UUID?
    private var pendingRecordID: String?
    private var started = false
    private var collecting = false
    private var generation = 0
    private var evaluationTask: Task<Void, Never>?
    nonisolated(unsafe) private var settingsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var timer: Timer?

    init(
        settingsViewModel: SettingsViewModel,
        audioCollector: any AudioProcessActivityCollecting = AudioProcessActivityCollector(),
        meetingURLProvider: (@Sendable () async -> BrowserMeetingObservation)? = nil,
        isRecordingActive: @escaping @MainActor () -> Bool,
        isDictationActive: @escaping @MainActor () -> Bool = { false },
        onRecordingConfirmed: @escaping @MainActor () -> Int?,
        showPrompt: PromptPresenter? = nil,
        closePrompt: (@MainActor () -> Void)? = nil,
        featureEnabled: Bool = AppFeatures.meetingActivityDetectionEnabled,
        policy: MeetingActivityPromptPolicy = MeetingActivityPromptPolicy(),
        pollInterval: TimeInterval = 1,
        nowProvider: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.settingsViewModel = settingsViewModel
        self.audioCollector = audioCollector
        let browserCollector = BrowserMeetingURLCollector()
        self.meetingURLProvider =
            meetingURLProvider ?? {
                await browserCollector.snapshotDetailed()
            }
        self.isRecordingActive = isRecordingActive
        self.isDictationActive = isDictationActive
        self.onRecordingConfirmed = onRecordingConfirmed
        let controller = MeetingActivityPromptController()
        self.showPrompt =
            showPrompt ?? { candidate, outcome in
                controller.show(displayName: candidate.displayName, onOutcome: outcome)
            }
        self.closePrompt = closePrompt ?? { controller.close() }
        self.featureEnabled = featureEnabled
        self.policy = policy
        self.pollInterval = pollInterval
        self.nowProvider = nowProvider
    }

    deinit {
        timer?.invalidate()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    func start() {
        guard featureEnabled, AppFeatures.meetingRecordingEnabled, !started else { return }
        started = true
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetMeetingActivitySettingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshObservation() }
        }
        refreshObservation()
    }

    func stop() {
        started = false
        stopObservation()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
    }

    func recordingStateDidChange() { scheduleEvaluation() }

    private func refreshObservation() {
        guard started, settingsViewModel.meetingActivityDetectionMode != .off else {
            stopObservation()
            return
        }
        guard !collecting else { scheduleEvaluation(); return }
        collecting = true
        audioCollector.start { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleEvaluation() }
        }
        if pollInterval > 0 {
            let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleEvaluation() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        scheduleEvaluation()
    }

    private func stopObservation() {
        generation += 1
        evaluationTask?.cancel()
        evaluationTask = nil
        timer?.invalidate()
        timer = nil
        if collecting { audioCollector.stop() }
        collecting = false
        policy = MeetingActivityPromptPolicy()
        pendingRecordID = nil
        dismissPanel()
    }

    private func scheduleEvaluation() {
        guard collecting, evaluationTask == nil else { return }
        let generation = generation
        evaluationTask = Task { [weak self] in
            guard let self else { return }
            await self.evaluate(now: self.nowProvider(), generation: generation)
            if self.generation == generation { self.evaluationTask = nil }
        }
    }

    private func evaluate(now: Date, generation: Int) async {
        guard collecting, settingsViewModel.meetingActivityDetectionMode != .off,
            self.generation == generation
        else { return }
        let browserObservation = await meetingURLProvider()
        guard !Task.isCancelled, collecting, settingsViewModel.meetingActivityDetectionMode != .off,
            self.generation == generation
        else { return }
        // Read again after Accessibility I/O: a call may have ended meanwhile.
        let audio = audioCollector.snapshot()
        // Both room URLs and pre-join controls must come from this snapshot.
        // Cached browser state cannot authorize recording or veto a later join.
        let confirmedInCallIDs = Set(
            browserObservation.inCallURLs.flatMap { bundleID, urls in
                urls.compactMap {
                    MeetingPromptCandidateResolver.browserCandidate(bundleID: bundleID, meetingURL: $0)?.id
                }
            })
        let explicitlyEndedIDs = Set(
            browserObservation.preJoinURLs.flatMap { bundleID, urls in
                urls.compactMap {
                    MeetingPromptCandidateResolver.browserCandidate(bundleID: bundleID, meetingURL: $0)?.id
                }
            })
        policy.resetSessions(for: explicitlyEndedIDs.subtracting(confirmedInCallIDs))
        let candidates = MeetingPromptCandidateResolver.resolve(
            audio: audio,
            meetingURLsByBundleID: browserObservation.urls,
            confirmedInCallURLsByBundleID: browserObservation.inCallURLs,
            excludedPreJoinURLsByBundleID: browserObservation.preJoinURLs
        )
        let busy = isRecordingActive() || isDictationActive()
        let offer =
            policy.update(
                candidates: candidates, now: now, canPrompt: !busy, isRecording: isRecordingActive(),
                preservedBrowserBundleIDs: browserObservation.runningBrowserBundleIDs
            )
            ?? policy.currentPrompt
        if let pendingRecordID {
            guard policy.activeCandidate(id: pendingRecordID) != nil else {
                self.pendingRecordID = nil
                dismissPanel()
                return
            }
            dismissPanel()
            if !busy, onRecordingConfirmed() != nil {
                policy.dismiss(id: pendingRecordID)
                self.pendingRecordID = nil
            }
            return
        }
        guard !busy, let offer else { dismissPanel(); return }
        guard offer.id != presentedID else { return }
        dismissPanel()
        presentedID = offer.id
        let token = UUID()
        presentationToken = token
        showPrompt(offer) { [weak self] outcome in
            self?.handleOutcome(outcome, candidateID: offer.id, token: token)
        }
    }

    private func handleOutcome(_ outcome: MeetingActivityPromptOutcome, candidateID: String, token: UUID) {
        guard collecting, settingsViewModel.meetingActivityDetectionMode != .off,
            presentationToken == token, presentedID == candidateID,
            policy.activeCandidate(id: candidateID) != nil
        else { return }
        dismissPanel()
        switch outcome {
        case .declined:
            policy.dismiss(id: candidateID)
        case .accepted:
            // Revalidate against current audio/URL metadata before starting. A
            // busy recorder or dictation leaves the click pending for this call.
            pendingRecordID = candidateID
            scheduleEvaluation()
        }
    }

    private func dismissPanel() {
        guard presentedID != nil else { return }
        presentedID = nil
        presentationToken = nil
        closePrompt()
    }

    func testHook_waitForScheduledEvaluation() async { await evaluationTask?.value }

    func testHook_evaluate(now: Date) async {
        await evaluationTask?.value
        await evaluate(now: now, generation: generation)
    }
    var testHook_isCollecting: Bool { collecting }
    var testHook_presentedID: String? { presentedID }
    var testHook_pendingRecordID: String? { pendingRecordID }
}
