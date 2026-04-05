import AppKit
import MacParakeetViewModels
import SwiftUI

private final class MeetingRecordingClickablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MeetingRecordingPillController {
    private var panel: NSPanel?
    private let pillViewModel: MeetingRecordingPillViewModel

    init(viewModel: MeetingRecordingPillViewModel) {
        self.pillViewModel = viewModel
    }

    func show() {
        if panel != nil { return }

        let view = MeetingRecordingPillView(viewModel: pillViewModel)
        let hosting = NSHostingView(rootView: view)

        let panelWidth: CGFloat = 360
        let panelHeight: CGFloat = 120
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = MeetingRecordingClickablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.midX - panelWidth / 2
            let y = frame.origin.y + 12
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
