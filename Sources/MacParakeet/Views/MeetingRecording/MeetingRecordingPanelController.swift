import AppKit
import MacParakeetViewModels
import SwiftUI

private final class MeetingRecordingPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class MeetingRecordingPanelController {
    var onCloseRequested: (() -> Void)?

    private var panel: NSPanel?
    private var windowDelegate: MeetingRecordingPanelWindowDelegate?
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

        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        let panel = MeetingRecordingPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Meeting Recording"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 320)
        panel.setFrameAutosaveName("MeetingRecordingPanel")
        panel.contentView = NSHostingView(rootView: MeetingRecordingPanelView(viewModel: viewModel).tint(DesignSystem.Colors.accent))

        if panel.frame.origin == .zero, let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.maxX - panel.frame.width - 24
            let y = frame.minY + 96
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let delegate = MeetingRecordingPanelWindowDelegate { [weak self] in
            self?.onCloseRequested?()
        }
        panel.delegate = delegate

        self.panel = panel
        self.windowDelegate = delegate
    }
}

private final class MeetingRecordingPanelWindowDelegate: NSObject, NSWindowDelegate {
    private let onCloseRequested: () -> Void

    init(onCloseRequested: @escaping () -> Void) {
        self.onCloseRequested = onCloseRequested
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequested()
        return false
    }
}
