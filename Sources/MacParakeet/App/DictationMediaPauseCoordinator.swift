import Foundation
import MacParakeetCore
import MacParakeetViewModels
import OSLog

@MainActor
protocol DictationMediaPauseCoordinating: AnyObject {
    func requestPauseBeforeDictationCapture()
    func resumeAfterDictationCapture() async
    func resumeForTermination()
}

@MainActor
final class DictationMediaPauseCoordinator: DictationMediaPauseCoordinating {
    private static let logger = Logger(subsystem: "com.macparakeet.app", category: "DictationMediaPause")
    // Covers the helper snapshot and MediaRemote command windows during termination.
    private static let terminationResumeTimeout: TimeInterval = 2.8

    private let settingsViewModel: SettingsViewModel
    private let mediaController: any SystemMediaControlling
    private let isMeetingRecordingActive: () -> Bool

    private var activeToken: MediaPauseToken?
    private var generation = 0
    /// In-flight media-pause round-trip. Tracked so it never gates capture
    /// start, and so tests can deterministically await the IPC. `private(set)`
    /// keeps it readable from `@testable` tests without external mutation.
    private(set) var pauseTask: Task<Void, Never>?

    init(
        settingsViewModel: SettingsViewModel,
        mediaController: any SystemMediaControlling,
        isMeetingRecordingActive: @escaping () -> Bool
    ) {
        self.settingsViewModel = settingsViewModel
        self.mediaController = mediaController
        self.isMeetingRecordingActive = isMeetingRecordingActive
    }

    /// Kick off media pause without blocking the caller.
    ///
    /// The generation claim and the cheap, synchronous guards run on the
    /// current MainActor turn, so a subsequent `resumeAfterDictationCapture()`
    /// (which also bumps `generation` synchronously) is always correctly
    /// ordered against this request: if capture ends before the pause IPC
    /// settles, the in-flight task sees the generation change and resumes the
    /// token it acquired instead of leaving media stuck paused.
    ///
    /// Only the now-playing snapshot + pause command — an out-of-process
    /// round-trip that previously front-loaded hundreds of milliseconds onto
    /// every dictation press and clipped the first words — runs in the
    /// detached child task, concurrently with audio capture start.
    func requestPauseBeforeDictationCapture() {
        generation += 1
        let pauseGeneration = generation

        // Abandon any still-in-flight pause from a previous request. The
        // generation bump above already invalidates it; cancelling also lets
        // it short-circuit before spawning the round-trip if it hasn't started.
        pauseTask?.cancel()
        pauseTask = nil

        guard activeToken == nil else { return }

        guard settingsViewModel.pauseMediaDuringDictation else {
            Self.logger.notice("media_pause_skipped reason=disabled")
            return
        }

        guard !isMeetingRecordingActive() else {
            Self.logger.notice("media_pause_skipped reason=meeting_active")
            return
        }

        pauseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Capture already ended before this task even ran — skip the
            // round-trip entirely; nothing was paused, so nothing to resume.
            guard !Task.isCancelled else { return }
            guard let token = await self.mediaController.pauseIfPlaying() else { return }
            // Capture ended (cancel/resume bumped generation, or this task was
            // cancelled) while the round-trip was in flight: release the token
            // instead of arming a pause nobody will resume. The generation
            // check is the authoritative guard; the cancellation check is a
            // best-effort fast path.
            guard !Task.isCancelled, self.generation == pauseGeneration else {
                await self.mediaController.resume(token)
                return
            }
            self.activeToken = token
        }
    }

    func resumeAfterDictationCapture() async {
        generation += 1
        pauseTask?.cancel()
        guard let token = activeToken else { return }
        activeToken = nil
        await mediaController.resume(token)
    }

    func resumeForTermination() {
        generation += 1
        pauseTask?.cancel()
        guard let token = activeToken else { return }
        activeToken = nil
        let mediaController = mediaController
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await mediaController.resume(token)
            done.signal()
        }
        _ = done.wait(timeout: .now() + Self.terminationResumeTimeout)
    }
}

@MainActor
final class NoOpDictationMediaPauseCoordinator: DictationMediaPauseCoordinating {
    func requestPauseBeforeDictationCapture() {}
    func resumeAfterDictationCapture() async {}
    func resumeForTermination() {}
}
