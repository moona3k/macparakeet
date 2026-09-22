import Foundation
import Observation
import MacParakeetViewModels

/// Transient feedback for the saved-meeting Notes footer.
///
/// The editor's save state is durable enough to follow a meeting between detail
/// views. This presentation state intentionally is not: a check only confirms
/// a save that completes while this Notes pane is visible.
@MainActor
@Observable
final class SavedMeetingNotesSaveStatusPresentation {
    static let confirmationDuration: Duration = .seconds(2)

    private(set) var showsSaveConfirmation = false

    @ObservationIgnored private var confirmationTask: Task<Void, Never>?
    private var confirmationToken: UUID?
    private var observedMeetingID: UUID?
    private var observedSaveState: SavedMeetingNotesViewModel.SaveState?
    private let duration: Duration
    private let waitForConfirmation: (Duration) async throws -> Void

    init() {
        duration = Self.confirmationDuration
        waitForConfirmation = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    }

    init(
        duration: Duration,
        waitForConfirmation: @escaping (Duration) async throws -> Void
    ) {
        self.duration = duration
        self.waitForConfirmation = waitForConfirmation
    }

    /// Starts a new visible Notes-pane session. A cached editor's current state
    /// is only a baseline; it never earns a new saved confirmation on entry.
    func beginPresentation(
        meetingID: UUID?,
        displayedMeetingID: UUID,
        saveState: SavedMeetingNotesViewModel.SaveState
    ) {
        clearConfirmation()
        guard meetingID == displayedMeetingID else {
            observedMeetingID = nil
            observedSaveState = nil
            return
        }
        observedMeetingID = meetingID
        observedSaveState = saveState
    }

    /// Records an editor state transition only when it belongs to the pane that
    /// established this presentation session. This avoids a replacement editor
    /// turning an old `.saving` state into a visible checkmark.
    func observeSaveStateChange(
        from previousState: SavedMeetingNotesViewModel.SaveState,
        to saveState: SavedMeetingNotesViewModel.SaveState,
        meetingID: UUID?,
        displayedMeetingID: UUID
    ) {
        guard
            meetingID == displayedMeetingID,
            observedMeetingID == meetingID,
            observedSaveState == previousState
        else {
            beginPresentation(
                meetingID: meetingID,
                displayedMeetingID: displayedMeetingID,
                saveState: saveState
            )
            return
        }

        observedSaveState = saveState
        guard previousState == .saving, saveState == .saved else {
            if saveState != .saved {
                clearConfirmation()
            }
            return
        }

        showConfirmation()
    }

    func endPresentation() {
        clearConfirmation()
        observedMeetingID = nil
        observedSaveState = nil
    }

    private func showConfirmation() {
        let token = UUID()
        confirmationToken = token
        confirmationTask?.cancel()
        showsSaveConfirmation = true
        confirmationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.waitForConfirmation(self.duration)
            guard !Task.isCancelled, self.confirmationToken == token else { return }
            self.showsSaveConfirmation = false
            self.confirmationTask = nil
            self.confirmationToken = nil
        }
    }

    private func clearConfirmation() {
        confirmationTask?.cancel()
        confirmationTask = nil
        confirmationToken = nil
        showsSaveConfirmation = false
    }
}
