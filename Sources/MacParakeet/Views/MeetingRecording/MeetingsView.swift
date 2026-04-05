import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

struct MeetingsView: View {
    @Bindable var viewModel: TranscriptionLibraryViewModel
    let onStartMeeting: () -> Void
    let onSelectTranscription: (Transcription) -> Void

    var body: some View {
        TranscriptionLibraryView(
            viewModel: viewModel,
            title: "Meetings",
            showsFilterBar: false,
            primaryActionTitle: "Record Meeting",
            onPrimaryAction: onStartMeeting,
            emptyTitle: "No meetings recorded yet",
            emptyMessage: "Record a meeting to save it here with the rest of your transcript tools."
        ) { transcription in
            onSelectTranscription(transcription)
        }
    }
}
