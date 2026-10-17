import AppKit
import MacParakeetViewModels
import SwiftUI

/// Always-on-top caption window for a meeting recording. It floats over other
/// apps without taking keyboard focus, so the user can keep working in the
/// call or video it is captioning.
@MainActor
final class MeetingCaptionWindowController {
    var onCloseRequested: (() -> Void)?

    private var panel: NSPanel?
    private var windowDelegate: MeetingCaptionWindowDelegate?
    private let viewModel: MeetingRecordingPanelViewModel

    init(viewModel: MeetingRecordingPanelViewModel) {
        self.viewModel = viewModel
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func show() {
        if panel == nil {
            createPanel()
        }
        // Order front without activating: captions must not pull focus.
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func close() {
        panel?.delegate = nil
        panel?.close()
        panel = nil
        windowDelegate = nil
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 260),
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
        panel.minSize = NSSize(width: 420, height: 140)
        panel.setFrameAutosaveName("MeetingCaptionWindow")
        panel.contentView = NSHostingView(
            rootView: MeetingCaptionView(viewModel: viewModel) { [weak self] in
                self?.onCloseRequested?()
            })

        // First use: bottom centre of the screen, like subtitles.
        if panel.frame.origin == .zero, let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 60))
        }

        let delegate = MeetingCaptionWindowDelegate { [weak self] in
            self?.onCloseRequested?()
        }
        panel.delegate = delegate

        self.panel = panel
        self.windowDelegate = delegate
    }
}

private final class MeetingCaptionWindowDelegate: NSObject, NSWindowDelegate {
    private let onCloseRequested: () -> Void

    init(onCloseRequested: @escaping () -> Void) {
        self.onCloseRequested = onCloseRequested
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequested()
        return false
    }
}
