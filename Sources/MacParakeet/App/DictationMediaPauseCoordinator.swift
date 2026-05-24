import Foundation
import MacParakeetCore
import MacParakeetViewModels
import OSLog

@MainActor
protocol DictationMediaPauseCoordinating: AnyObject {
    func pauseBeforeDictationCapture() async
    func resumeAfterDictationCapture() async
    func resumeForTermination()
}

@MainActor
final class DictationMediaPauseCoordinator: DictationMediaPauseCoordinating {
    private static let logger = Logger(subsystem: "com.macparakeet.app", category: "DictationMediaPause")
    // Covers the two MediaRemote callback windows in SystemMediaController.resume.
    private static let terminationResumeTimeout: TimeInterval = 1.8

    private let settingsViewModel: SettingsViewModel
    private let mediaController: any SystemMediaControlling
    private let isMeetingRecordingActive: () -> Bool

    private var activeToken: MediaPauseToken?
    private var generation = 0

    init(
        settingsViewModel: SettingsViewModel,
        mediaController: any SystemMediaControlling,
        isMeetingRecordingActive: @escaping () -> Bool
    ) {
        self.settingsViewModel = settingsViewModel
        self.mediaController = mediaController
        self.isMeetingRecordingActive = isMeetingRecordingActive
    }

    func pauseBeforeDictationCapture() async {
        generation += 1
        let pauseGeneration = generation

        guard activeToken == nil else { return }

        guard settingsViewModel.pauseMediaDuringDictation else {
            Self.logger.notice("media_pause_skipped reason=disabled")
            return
        }

        guard !isMeetingRecordingActive() else {
            Self.logger.notice("media_pause_skipped reason=meeting_active")
            return
        }

        guard let token = await mediaController.pauseIfPlaying() else { return }

        guard generation == pauseGeneration else {
            await mediaController.resume(token)
            return
        }

        activeToken = token
    }

    func resumeAfterDictationCapture() async {
        generation += 1
        guard let token = activeToken else { return }
        activeToken = nil
        await mediaController.resume(token)
    }

    func resumeForTermination() {
        generation += 1
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
    func pauseBeforeDictationCapture() async {}
    func resumeAfterDictationCapture() async {}
    func resumeForTermination() {}
}
