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
    private let isMeetingFlowBusy: @MainActor () -> Bool
    private let runningNativeProcessIDsProvider: @MainActor () -> [String: Set<Int32>]
    private let isDictationActive: @MainActor () -> Bool
    private let isStartSuppressed: @MainActor () -> Bool
    private let onRecordingConfirmed: @MainActor () -> Int?
    private let showPrompt: PromptPresenter
    private let closePrompt: @MainActor () -> Void
    private let setRecordingAvailable: @MainActor (Bool) -> Void
    private let featureEnabled: Bool
    private let pollInterval: TimeInterval
    private let stablePollInterval: TimeInterval
    private let nowProvider: @MainActor () -> Date
    private var policy: MeetingActivityPromptPolicy
    private var presentedID: String?
    private var presentationToken: UUID?
    private var pendingRecordID: String?
    private var requestedRecordingCandidateID: String?
    private var nativeProcessIDs: [String: Set<Int32>] = [:]
    private var lastEvaluationAt: Date?
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
        isMeetingFlowBusy: (@MainActor () -> Bool)? = nil,
        runningNativeProcessIDsProvider: @escaping @MainActor () -> [String: Set<Int32>] = {
            NSWorkspace.shared.runningApplications.reduce(into: [:]) { result, application in
                guard let bundleID = application.bundleIdentifier,
                    let descriptor = MeetingAppRegistry.descriptor(forBundleID: bundleID),
                    descriptor.trustTier != .browser
                else { return }
                result[bundleID, default: []].insert(application.processIdentifier)
            }
        },
        isDictationActive: @escaping @MainActor () -> Bool = { false },
        isStartSuppressed: @escaping @MainActor () -> Bool = { false },
        onRecordingConfirmed: @escaping @MainActor () -> Int?,
        showPrompt: PromptPresenter? = nil,
        closePrompt: (@MainActor () -> Void)? = nil,
        setRecordingAvailable: (@MainActor (Bool) -> Void)? = nil,
        featureEnabled: Bool = AppFeatures.meetingActivityDetectionEnabled,
        policy: MeetingActivityPromptPolicy = MeetingActivityPromptPolicy(),
        pollInterval: TimeInterval = 1,
        stablePollInterval: TimeInterval = 2,
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
        self.isMeetingFlowBusy = isMeetingFlowBusy ?? isRecordingActive
        self.runningNativeProcessIDsProvider = runningNativeProcessIDsProvider
        self.isDictationActive = isDictationActive
        self.isStartSuppressed = isStartSuppressed
        self.onRecordingConfirmed = onRecordingConfirmed
        let controller = MeetingActivityPromptController()
        self.showPrompt =
            showPrompt ?? { candidate, outcome in
                controller.show(displayName: candidate.displayName, onOutcome: outcome)
            }
        self.closePrompt = closePrompt ?? { controller.close() }
        self.setRecordingAvailable = setRecordingAvailable ?? { controller.setRecordingAvailable($0) }
        self.featureEnabled = featureEnabled
        self.policy = policy
        self.pollInterval = pollInterval
        self.stablePollInterval = max(pollInterval, stablePollInterval)
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

    /// Hide the offer before quit can enter a nested modal loop. A cancelled
    /// quit keeps the call policy and any previously accepted request intact.
    func dismissPromptForQuit() { dismissPanel() }

    /// Clear attribution before any async metadata read. A failed/cancelled
    /// activity start may be followed immediately by an unrelated manual start.
    /// Deferred clicks remain pending until capture succeeds or their call ends.
    func recordingFlowDidReturnToIdle() {
        requestedRecordingCandidateID = nil
        scheduleEvaluation()
    }

    /// Capture success is an event, not a busy-state poll: a recording can start
    /// and stop between scans, and permission/failed-start states consume nothing.
    func recordingDidBegin() {
        policy.recordingDidBegin(candidateID: requestedRecordingCandidateID)
        pendingRecordID = nil
        requestedRecordingCandidateID = nil
        dismissPanel()
        scheduleEvaluation()
    }

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
                Task { @MainActor [weak self] in self?.scheduleEvaluation(isPeriodic: true) }
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
        requestedRecordingCandidateID = nil
        nativeProcessIDs = [:]
        lastEvaluationAt = nil
        dismissPanel()
    }

    private func scheduleEvaluation(isPeriodic: Bool = false) {
        guard collecting, evaluationTask == nil else { return }
        // A muted browser join has no CoreAudio edge. Keep a bounded scan even
        // in stable/dismissed states, at a slower cadence than dwell/retry work.
        if isPeriodic, !policy.needsRefresh, pendingRecordID == nil,
            let lastEvaluationAt, nowProvider().timeIntervalSince(lastEvaluationAt) < stablePollInterval
        {
            return
        }
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
        lastEvaluationAt = now
        let browserObservation = await meetingURLProvider()
        guard !Task.isCancelled, collecting, settingsViewModel.meetingActivityDetectionMode != .off,
            self.generation == generation
        else { return }
        // Read again after Accessibility I/O: a call may have ended meanwhile.
        let audio = audioCollector.snapshot()
        let runningNativeProcessIDs = runningNativeProcessIDsProvider()
        let exitedNativeIDs = Set(
            nativeProcessIDs.compactMap { bundleID, pids in
                pids.isDisjoint(with: runningNativeProcessIDs[bundleID] ?? []) ? "app:\(bundleID)" : nil
            })
        // Microphone loss is ambiguous (mute/reconnect versus a new call).
        // Preserve continuity while any previously observed instance survives.
        // Complete process replacement is a confirmed native session boundary.
        policy.resetSessions(for: exitedNativeIDs)
        if let pendingRecordID, exitedNativeIDs.contains(pendingRecordID) {
            self.pendingRecordID = nil
        }
        nativeProcessIDs = runningNativeProcessIDs
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
        let meetingBusy = isMeetingFlowBusy()
        let busy = meetingBusy || isDictationActive() || isStartSuppressed()
        if !meetingBusy { requestedRecordingCandidateID = nil }
        let offer =
            policy.update(
                candidates: candidates, now: now, canPrompt: !busy, isRecording: isRecordingActive(),
                preservedBrowserBundleIDs: browserObservation.runningBrowserBundleIDs
            )
            ?? policy.currentPrompt
        if let pendingRecordID {
            if policy.activeCandidate(id: pendingRecordID) == nil {
                self.pendingRecordID = nil
            } else if busy {
                dismissPanel()
                return
            } else {
                dismissPanel()
                // The start callback may synchronously report capture success.
                // Make the attribution available before invoking it.
                requestedRecordingCandidateID = pendingRecordID
                if onRecordingConfirmed() != nil {
                    self.pendingRecordID = nil
                    return
                }
                requestedRecordingCandidateID = nil
                if isMeetingFlowBusy() {
                    // A racing start owns the flow; retain this user request
                    // until it either captures (event consumes it) or goes idle.
                    return
                }
                // A rejection with no busy owner is not a reason to silently
                // retry forever. Restore the offer for another explicit click.
                self.pendingRecordID = nil
            }
        }
        guard !busy, let offer else { dismissPanel(); return }
        if offer.id == presentedID {
            setRecordingAvailable(policy.activeCandidate(id: offer.id) != nil)
            return
        }
        dismissPanel()
        presentedID = offer.id
        let token = UUID()
        presentationToken = token
        showPrompt(offer) { [weak self] outcome in
            self?.handleOutcome(outcome, candidateID: offer.id, token: token)
        }
        setRecordingAvailable(policy.activeCandidate(id: offer.id) != nil)
    }

    private func handleOutcome(_ outcome: MeetingActivityPromptOutcome, candidateID: String, token: UUID) {
        guard collecting, settingsViewModel.meetingActivityDetectionMode != .off,
            presentationToken == token, presentedID == candidateID
        else { return }
        guard !isStartSuppressed() else { dismissPanel(); return }
        switch outcome {
        case .declined:
            dismissPanel()
            policy.dismiss(id: candidateID)
        case .accepted:
            guard policy.activeCandidate(id: candidateID) != nil else {
                setRecordingAvailable(false)
                return
            }
            dismissPanel()
            // Revalidate against current audio/URL metadata before starting. A
            // busy recorder, dictation or lifecycle gate leaves an accepted click
            // pending for this call.
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

    func testHook_periodicTick() async {
        scheduleEvaluation(isPeriodic: true)
        await evaluationTask?.value
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
