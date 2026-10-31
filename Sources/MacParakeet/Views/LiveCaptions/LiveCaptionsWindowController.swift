import AppKit
import MacParakeetViewModels
import SwiftUI

/// Always-on-top window for Live Captions. Closing it stops the session, so
/// audio is never streamed while the window is out of sight.
@MainActor
final class LiveCaptionsWindowController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let viewModel: LiveCaptionsViewModel

    init(viewModel: LiveCaptionsViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        if panel == nil {
            createPanel()
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 320),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Live Captions"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 560, height: 180)
        panel.setFrameAutosaveName("LiveCaptionsWindow")
        panel.contentView = NSHostingView(rootView: LiveCaptionsView(viewModel: viewModel))
        panel.delegate = self

        if panel.frame.origin == .zero, let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 60))
        }
        self.panel = panel
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.stop()
    }
}
