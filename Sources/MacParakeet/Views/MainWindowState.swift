import Foundation
import MacParakeetCore
import MacParakeetViewModels

@MainActor
@Observable
final class MainWindowState {
    var selectedItem: SidebarItem = .transcribe
    var requestedSettingsTab: SettingsTab?
    var requestedSettingsTabRevision = 0
    var showingProgressDetail = false

    func navigateToSettings(tab: SettingsTab? = nil) {
        requestedSettingsTab = tab
        if tab != nil {
            requestedSettingsTabRevision += 1
        }
        selectedItem = .settings
    }

    func consumeRequestedSettingsTab() {
        requestedSettingsTab = nil
    }

    /// Transforms tab — pending sheet state (ADR-022). When non-nil the
    /// editor sheet appears for that Transform.
    var editingTransform: Prompt?
    /// True when the Create-your-own sheet should be presented.
    var isCreatingTransform: Bool = false

    /// Switch the sidebar to Library so the transcription detail surfaces in
    /// its natural home. The Transcribe tab is the capture surface (YouTube,
    /// file, meeting); once a transcription exists, it lives in Library.
    /// The `from:` parameter is retained for call-site readability.
    func navigateToTranscription(from current: SidebarItem? = nil) {
        _ = current
        selectedItem = .library
    }
}

extension Notification.Name {
    /// Posted after a Transforms save/delete/reset so the
    /// `TransformsCoordinator` can reload bindings into the hotkey
    /// registry.
    static let transformsBindingsChanged = Notification.Name("com.macparakeet.transforms.bindingsChanged")
    /// Posted after a successful Transform is saved to local history so the
    /// Transforms tab can refresh if it is visible.
    static let transformHistoryChanged = Notification.Name("com.macparakeet.transforms.historyChanged")
}
