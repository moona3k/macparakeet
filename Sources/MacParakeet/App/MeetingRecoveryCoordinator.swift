import AppKit
import Foundation
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class MeetingRecoveryCoordinator {
    private let environmentProvider: () -> AppEnvironment?
    private let settingsViewModel: SettingsViewModel
    private let libraryViewModel: TranscriptionLibraryViewModel
    private let meetingsViewModel: TranscriptionLibraryViewModel
    private let onPresentRecoveredTranscription: (Transcription) -> Void

    init(
        environmentProvider: @escaping () -> AppEnvironment?,
        settingsViewModel: SettingsViewModel,
        libraryViewModel: TranscriptionLibraryViewModel,
        meetingsViewModel: TranscriptionLibraryViewModel,
        onPresentRecoveredTranscription: @escaping (Transcription) -> Void
    ) {
        self.environmentProvider = environmentProvider
        self.settingsViewModel = settingsViewModel
        self.libraryViewModel = libraryViewModel
        self.meetingsViewModel = meetingsViewModel
        self.onPresentRecoveredTranscription = onPresentRecoveredTranscription
    }

    func scheduleLaunchRecoveryScanIfReady(environment env: AppEnvironment) {
        let onboardingDone = UserDefaults.standard.string(forKey: OnboardingViewModel.onboardingCompletedKey) != nil
        guard onboardingDone else { return }

        Task { [weak self] in
            await self?.discoverAndPresentRecoveries(
                recoveryService: env.meetingRecordingRecoveryService,
                source: .launch
            )
        }
    }

    func presentPendingMeetingRecoveryDialog() {
        guard let env = environmentProvider() else { return }

        Task { [weak self] in
            await self?.discoverAndPresentRecoveries(
                recoveryService: env.meetingRecordingRecoveryService,
                source: .settings
            )
        }
    }

    private func discoverAndPresentRecoveries(
        recoveryService: MeetingRecordingRecoveryServicing,
        source: TelemetryMeetingRecoverySource
    ) async {
        do {
            let recoveries = try await recoveryService.discoverPendingRecoveries()
            settingsViewModel.refreshPendingMeetingRecoveries()
            guard !recoveries.isEmpty else { return }
            Telemetry.send(.meetingRecoveryDiscovered(count: recoveries.count, source: source))
            await presentMeetingRecoveryDialog(recoveries, recoveryService: recoveryService, source: source)
        } catch {
            await presentMeetingRecoveryError(error)
        }
    }

    private func presentMeetingRecoveryDialog(
        _ recoveries: [MeetingRecordingLockFile],
        recoveryService: MeetingRecordingRecoveryServicing,
        source: TelemetryMeetingRecoverySource
    ) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "We found \(recoveries.count) interrupted recording\(recoveries.count == 1 ? "" : "s")"
        alert.informativeText = recoveryDialogMessage(for: recoveries)
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Recover Later")
        alert.addButton(withTitle: "Discard")

        let response = await presentAlert(alert)
        switch response {
        case .alertFirstButtonReturn:
            await recoverMeetingRecordings(
                recoveries,
                recoveryService: recoveryService,
                source: source
            )
        case .alertThirdButtonReturn:
            await discardMeetingRecoveries(
                recoveries,
                recoveryService: recoveryService,
                source: source
            )
        default:
            settingsViewModel.refreshPendingMeetingRecoveries()
        }
    }

    private func recoveryDialogMessage(for recoveries: [MeetingRecordingLockFile]) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let sessionLines = recoveries.prefix(5).map { recovery in
            "\(formatter.string(from: recovery.startedAt)) - \(recovery.displayName)"
        }
        let extraCount = max(0, recoveries.count - sessionLines.count)
        let extraLine = extraCount > 0 ? ["and \(extraCount) more"] : []
        return (sessionLines + extraLine).joined(separator: "\n")
            + "\n\nRecovery transcribes the saved audio again and marks the result as recovered."
    }

    private func recoverMeetingRecordings(
        _ recoveries: [MeetingRecordingLockFile],
        recoveryService: MeetingRecordingRecoveryServicing,
        source: TelemetryMeetingRecoverySource
    ) async {
        let startedAt = Date()
        Telemetry.send(.meetingRecoveryStarted(count: recoveries.count, source: source))
        var lastRecoveredIndex = -1
        do {
            var recovered: [Transcription] = []
            for (index, recovery) in recoveries.enumerated() {
                recovered.append(try await recoveryService.recover(recovery))
                lastRecoveredIndex = index
            }
            Telemetry.send(.meetingRecoveryCompleted(
                count: recovered.count,
                durationSeconds: Date().timeIntervalSince(startedAt),
                source: source
            ))
            libraryViewModel.loadTranscriptions()
            meetingsViewModel.loadTranscriptions()
            settingsViewModel.refreshPendingMeetingRecoveries()
            if let first = recovered.first {
                onPresentRecoveredTranscription(first)
            }
        } catch {
            let pendingRecoveries = Array(recoveries.dropFirst(lastRecoveredIndex + 1))
            Telemetry.send(.meetingRecoveryFailed(
                count: pendingRecoveries.count,
                source: source,
                errorType: TelemetryErrorClassifier.classify(error),
                errorDetail: TelemetryErrorClassifier.errorDetail(error)
            ))
            settingsViewModel.refreshPendingMeetingRecoveries()
            await presentMeetingRecoveryError(
                error,
                recoveries: pendingRecoveries,
                recoveryService: recoveryService,
                source: source
            )
        }
    }

    private func discardMeetingRecoveries(
        _ recoveries: [MeetingRecordingLockFile],
        recoveryService: MeetingRecordingRecoveryServicing,
        source: TelemetryMeetingRecoverySource
    ) async {
        do {
            for recovery in recoveries {
                try await recoveryService.discard(recovery)
            }
            Telemetry.send(.meetingRecoveryDiscarded(count: recoveries.count, source: source))
            settingsViewModel.refreshPendingMeetingRecoveries()
        } catch {
            Telemetry.send(.meetingRecoveryFailed(
                count: recoveries.count,
                source: source,
                errorType: TelemetryErrorClassifier.classify(error),
                errorDetail: TelemetryErrorClassifier.errorDetail(error)
            ))
            settingsViewModel.refreshPendingMeetingRecoveries()
            await presentMeetingRecoveryError(error)
        }
    }

    private func presentMeetingRecoveryError(
        _ error: Error,
        recoveries: [MeetingRecordingLockFile] = [],
        recoveryService: MeetingRecordingRecoveryServicing? = nil,
        source: TelemetryMeetingRecoverySource = .launch
    ) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Meeting Recovery Failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if !recoveries.isEmpty, recoveryService != nil {
            alert.addButton(withTitle: "Discard Pending")
        }
        let response = await presentAlert(alert)
        guard response == .alertSecondButtonReturn, let recoveryService else { return }
        await discardMeetingRecoveries(recoveries, recoveryService: recoveryService, source: source)
    }

    private func presentAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)

        if let window = [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }).first(where: \.isVisible) {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
            }
        }

        // Launch recovery can happen before there is a window to host a sheet.
        return alert.runModal()
    }
}
