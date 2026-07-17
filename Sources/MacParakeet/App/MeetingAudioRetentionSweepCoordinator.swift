import Foundation
import MacParakeetCore
import OSLog

@MainActor
final class MeetingAudioRetentionSweepCoordinator {
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let minimumSweepInterval: TimeInterval
    private let logger = Logger(
        subsystem: "com.macparakeet.app",
        category: "MeetingAudioRetention"
    )

    private var sweepTask: Task<Void, Never>?
    private var launchRecoveryTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        minimumSweepInterval: TimeInterval = 24 * 60 * 60
    ) {
        self.defaults = defaults
        self.now = now
        self.minimumSweepInterval = minimumSweepInterval
    }

    deinit {
        sweepTask?.cancel()
    }

    func scheduleLaunchSweep(
        environment env: AppEnvironment,
        after recoveryTask: Task<Void, Never>?
    ) {
        scheduleLaunchSweep(
            repository: env.transcriptionRepo,
            retention: env.runtimePreferences.meetingAudioRetention,
            after: recoveryTask
        )
    }

    func scheduleForegroundSweepIfDue(environment env: AppEnvironment) {
        scheduleForegroundSweepIfDue(
            repository: env.transcriptionRepo,
            retention: env.runtimePreferences.meetingAudioRetention
        )
    }

    func schedulePreferenceChangeSweep(environment env: AppEnvironment) {
        schedulePreferenceChangeSweep(
            repository: env.transcriptionRepo,
            retention: env.runtimePreferences.meetingAudioRetention
        )
    }

    func scheduleLaunchSweep(
        repository: TranscriptionRepositoryProtocol,
        retention: MeetingAudioRetention,
        after recoveryTask: Task<Void, Never>?
    ) {
        launchRecoveryTask = recoveryTask
        scheduleSweep(repository: repository, retention: retention, force: false, after: recoveryTask)
    }

    func scheduleForegroundSweepIfDue(
        repository: TranscriptionRepositoryProtocol,
        retention: MeetingAudioRetention
    ) {
        scheduleSweep(repository: repository, retention: retention, force: false, after: launchRecoveryTask)
    }

    func schedulePreferenceChangeSweep(
        repository: TranscriptionRepositoryProtocol,
        retention: MeetingAudioRetention
    ) {
        scheduleSweep(repository: repository, retention: retention, force: true, after: launchRecoveryTask)
    }

    private func scheduleSweep(
        repository: TranscriptionRepositoryProtocol,
        retention: MeetingAudioRetention,
        force: Bool,
        after recoveryTask: Task<Void, Never>? = nil
    ) {
        guard retention.automaticallyDeletesAudio else {
            if force {
                sweepTask?.cancel()
                sweepTask = nil
            }
            return
        }
        guard force || recoveryTask != nil || shouldRunSweep(now: now()) else { return }

        sweepTask?.cancel()
        let nowProvider = now
        sweepTask = Task.detached(priority: .utility) { [weak self, repository, retention, nowProvider, recoveryTask] in
            if let recoveryTask {
                await recoveryTask.value
                await self?.clearLaunchRecoveryTask()
            }
            guard !Task.isCancelled else { return }

            let sweepNow = nowProvider()
            if !force {
                guard await self?.shouldRunSweep(now: sweepNow) == true else { return }
            }
            guard !Task.isCancelled else { return }

            do {
                let result = try MeetingAudioRetentionSweeper(repository: repository)
                    .sweep(retention: retention, now: sweepNow)
                await self?.markSweepCompleted(at: sweepNow)
                await self?.logSweepResult(result)
            } catch {
                await self?.logSweepFailure(error)
            }
        }
    }

    private func shouldRunSweep(now: Date) -> Bool {
        guard let lastSweepAt = defaults.object(
            forKey: UserDefaultsAppRuntimePreferences.lastMeetingAudioRetentionSweepAtKey
        ) as? Date else {
            return true
        }
        return now.timeIntervalSince(lastSweepAt) >= minimumSweepInterval
    }

    private func markSweepCompleted(at date: Date) {
        defaults.set(date, forKey: UserDefaultsAppRuntimePreferences.lastMeetingAudioRetentionSweepAtKey)
    }

    private func clearLaunchRecoveryTask() {
        launchRecoveryTask = nil
    }

    private func logSweepResult(_ result: MeetingAudioRetentionSweepResult) {
        // .notice persists to the unified log store (.info is memory-only);
        // sweeps delete user audio, so they must be reconstructable later.
        logger.notice(
            "meeting_audio_retention_sweep_completed evaluated=\(result.evaluatedCount, privacy: .public) eligible=\(result.eligibleCount, privacy: .public) detached=\(result.detachedCount, privacy: .public) locked=\(result.skippedLockedCount, privacy: .public) unmanaged=\(result.skippedUnmanagedCount, privacy: .public) failed=\(result.failedCount, privacy: .public)"
        )
    }

    private func logSweepFailure(_ error: Error) {
        logger.warning(
            "meeting_audio_retention_sweep_failed error=\(error.localizedDescription, privacy: .private)"
        )
    }
}
