import Foundation
import MacParakeetCore
import MacParakeetViewModels

/// Applies the two meetings-tab end-of-meeting settings to a finished meeting
/// transcript: persist and refresh it, then either open the app on it or leave
/// the user where they are with an optional chime/banner.
///
/// This lives outside `AppEnvironmentConfigurer` so the ordering invariant is
/// testable without building a whole `AppEnvironment`. The invariant: the quiet
/// path must save and refresh the transcript *without selecting* it. Selection
/// sets `TranscriptionViewModel.currentTranscription`, which a mounted
/// `MainWindowView` observes and answers by switching the sidebar to Library.
/// Selecting first and consulting `openAppAfterMeetingEnd` afterwards cannot be
/// undone, so a finished meeting would yank a foregrounded user off their
/// current tab even with automatic opening turned off.
///
/// The decision itself is the pure, unit-tested
/// `TranscriptionCompletionNotifier.meetingEndPresentation`; this type only
/// sequences the side effects around it.
@MainActor
struct MeetingCompletionRouter {
    /// Save the completed transcription and refresh the transcript surface.
    /// The `Bool` is `selectTranscription` — see the type documentation for why
    /// it must not be hardcoded to `true`.
    let presentCompleted: @MainActor (Transcription, Bool) -> Void
    let reloadLibrary: @MainActor () -> Void
    let refreshRecentMeetings: @MainActor () -> Void
    let navigateToTranscription: @MainActor () -> Void
    let openMainWindow: @MainActor () -> Void
    let presentSignal: @MainActor (TranscriptionCompletionNotifier.Content) -> Void

    /// Route a finished meeting transcript.
    ///
    /// `canPresent` is the recording queue's own guard: a transcript that
    /// drains while another meeting is already recording is saved silently no
    /// matter what the settings say, because interrupting a live meeting is
    /// worse than a delayed hand-off. The live path passes `true`.
    func handle(
        _ transcription: Transcription,
        openAppEnabled: Bool,
        notifyEnabled: Bool,
        canPresent: Bool
    ) {
        let text = transcription.cleanTranscript ?? transcription.rawTranscript ?? ""
        let presentation = TranscriptionCompletionNotifier.meetingEndPresentation(
            openAppEnabled: openAppEnabled,
            notifyEnabled: notifyEnabled,
            meetingTitle: transcription.effectiveDisplayTitle,
            wordCount: text.split(whereSeparator: { $0.isWhitespace }).count
        )

        presentCompleted(transcription, canPresent && presentation.selectsTranscription)
        reloadLibrary()
        refreshRecentMeetings()

        guard canPresent else { return }
        switch presentation {
        case .openApp:
            navigateToTranscription()
            openMainWindow()
        case .quietSignal(let content):
            presentSignal(content)
        case .silent:
            break
        }
    }
}
