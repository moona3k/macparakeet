import Foundation
import Observation
import MacParakeetViewModels

/// Decisions for the saved-meeting Notes editor chrome.
///
/// The view keeps layout and controls. These rules decide when that editor can
/// be typed in, when Copy has a payload, and what VoiceOver should promise.
enum SavedMeetingNotesEditorPresentation {
    static let writingPrompt = "Add your thoughts, decisions, and next steps…"
    static let editingHint =
        "Add private context, decisions, or reminders for this meeting. Changes save automatically."
    static let deletedStatus = "Meeting deleted — notes were not saved."
    static let unavailableHint = "Notes cannot be edited right now."

    static func isEditorEnabled(
        meetingID: UUID?,
        displayedMeetingID: UUID,
        saveState: SavedMeetingNotesViewModel.SaveState
    ) -> Bool {
        meetingID == displayedMeetingID && saveState != .deleted
    }

    static func showsWritingPrompt(
        meetingID: UUID?,
        displayedMeetingID: UUID,
        saveState: SavedMeetingNotesViewModel.SaveState,
        draft: String
    ) -> Bool {
        isEditorEnabled(
            meetingID: meetingID,
            displayedMeetingID: displayedMeetingID,
            saveState: saveState
        ) && draft.isEmpty
    }

    /// Copy stays disabled for a blank draft and never reads another meeting's notes.
    /// Whitespace-only text is blank. A draft with visible text is copied unchanged.
    static func copyPayload(
        meetingID: UUID?,
        displayedMeetingID: UUID,
        draft: String
    ) -> String? {
        guard meetingID == displayedMeetingID else { return nil }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return draft
    }

    static func accessibilityHint(
        meetingID: UUID?,
        displayedMeetingID: UUID,
        saveState: SavedMeetingNotesViewModel.SaveState
    ) -> String {
        if meetingID == displayedMeetingID, saveState == .deleted {
            return deletedStatus
        }
        guard
            isEditorEnabled(
                meetingID: meetingID,
                displayedMeetingID: displayedMeetingID,
                saveState: saveState
            )
        else {
            return unavailableHint
        }
        return editingHint
    }
}

/// Brief "Copied" confirmation for the Notes Copy button.
///
/// Editing, switching meetings, or leaving the pane drops the confirmation
/// immediately. A timer that already started cannot clear a later copy.
@MainActor
@Observable
final class SavedMeetingNotesCopyFeedback {
    static let confirmationDuration: Duration = .seconds(1)

    private(set) var isCopied = false

    @ObservationIgnored private var resetTask: Task<Void, Never>?
    private var confirmationToken: UUID?
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

    func noteCopied() {
        let token = UUID()
        confirmationToken = token
        resetTask?.cancel()
        isCopied = true
        resetTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.waitForConfirmation(self.duration)
            guard !Task.isCancelled, self.confirmationToken == token else { return }
            self.isCopied = false
            self.resetTask = nil
            self.confirmationToken = nil
        }
    }

    func reset() {
        resetTask?.cancel()
        resetTask = nil
        confirmationToken = nil
        isCopied = false
    }
}
