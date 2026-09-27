import Foundation
import MacParakeetCore
import MacParakeetViewModels

@MainActor
@Observable
final class MainWindowState {
    private let askWorkspaceAvailable: Bool
    private var navigationRevision: UInt64 = 0
    private var latestTranscriptionOpen: UUID?

    var selectedItem: SidebarItem = .transcribe {
        didSet {
            if selectedItem == .ask, !askWorkspaceAvailable {
                selectedItem = .library
            }
            if selectedItem != oldValue {
                navigationRevision &+= 1
            }
        }
    }

    var requestedSettingsTab: SettingsTab?
    var requestedSettingsAnchor: String?
    var requestedSettingsTabRevision = 0
    var showingProgressDetail = false

    init(askWorkspaceAvailable: Bool = AppFeatures.isAskWorkspaceAvailable()) {
        self.askWorkspaceAvailable = askWorkspaceAvailable
    }

    func navigateToSettings(tab: SettingsTab? = nil, anchor: String? = nil) {
        requestedSettingsTab = tab
        requestedSettingsAnchor = anchor
        if tab != nil || anchor != nil {
            requestedSettingsTabRevision += 1
        }
        selectedItem = .settings
    }

    func navigate(to item: SidebarItem) {
        selectedItem = item
    }

    func navigateToAsk() {
        selectedItem = .ask
    }

    /// Capture the user's intent before scheduling the load. Library and
    /// Meetings share this boundary so a newer open, selection, or navigation
    /// invalidates an older fetch, including leaving and returning to a tab.
    @discardableResult
    func openTranscription(
        from tab: SidebarItem,
        in viewModel: TranscriptionViewModel,
        load: @escaping @MainActor () async -> Transcription?
    ) -> Task<Bool, Never> {
        let requestID = UUID()
        latestTranscriptionOpen = requestID
        let navigation = navigationRevision
        let selection = viewModel.currentTranscriptionRevision
        return Task {
            let isCurrent = {
                !Task.isCancelled
                    && self.latestTranscriptionOpen == requestID
                    && self.navigationRevision == navigation
                    && self.selectedItem == tab
                    && viewModel.currentTranscriptionRevision == selection
            }
            guard isCurrent(), let stored = await load(), isCurrent()
            else { return false }
            viewModel.currentTranscription = stored
            navigateToTranscription(from: tab)
            return true
        }
    }

    func startNewTranscription() {
        selectedItem = .transcribe
        showingProgressDetail = false
    }

    func beginCreatingTransform() {
        editingTransform = nil
        isCreatingTransform = true
        selectedItem = .transforms
    }

    func consumeRequestedSettingsTab() {
        requestedSettingsTab = nil
        requestedSettingsAnchor = nil
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
