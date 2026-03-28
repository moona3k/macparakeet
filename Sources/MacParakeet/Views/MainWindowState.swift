import Foundation

@MainActor
@Observable
final class MainWindowState {
    var selectedItem: SidebarItem = .transcribe
    var showingProgressDetail = false

    /// The sidebar item the user was on before navigating into a transcription detail.
    /// Used by the back button to return to the originating page (e.g. Library).
    var previousItem: SidebarItem?

    /// Navigate to the Transcribe tab to show a transcription detail,
    /// remembering where the user came from so back returns there.
    func navigateToTranscription(from current: SidebarItem? = nil) {
        let origin = current ?? selectedItem
        // Only save if we're navigating away from a different tab
        if origin != .transcribe {
            previousItem = origin
        } else {
            previousItem = nil
        }
        selectedItem = .transcribe
    }

    /// Return to the previous sidebar item (if any) after pressing back.
    func navigateBack() {
        if let prev = previousItem {
            selectedItem = prev
            previousItem = nil
        }
        // If no previousItem, we were already on Transcribe — just clear the transcription
    }
}

