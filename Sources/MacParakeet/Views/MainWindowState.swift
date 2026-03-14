import Foundation

@MainActor
@Observable
final class MainWindowState {
    var selectedItem: SidebarItem = .transcribe
    var showingProgressDetail = false
}

