import AppKit
import SwiftUI
import MacParakeetViewModels

// MARK: - Mouse Tracking (click-aware)

/// NSView overlay that detects mouse hover and clicks for the idle pill.
/// Unlike the dictation overlay's tracker, this one intercepts clicks within the pill region.
private final class IdlePillTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onClicked: (() -> Void)?

    /// Region within the view that is clickable (pill bounds in view coordinates).
    var clickableRect: NSRect = .zero

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if clickableRect.contains(point) {
            onClicked?()
        }
    }

    // Only intercept clicks in the pill region; pass through everywhere else
    override func hitTest(_ point: NSPoint) -> NSView? {
        clickableRect.contains(point) ? self : nil
    }
}

// MARK: - Idle Pill Controller

/// Manages the persistent idle pill panel — always visible when not dictating.
/// Non-activating NSPanel that never steals focus.
@MainActor
final class IdlePillController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<IdlePillView>?
    private var trackingView: IdlePillTrackingView?

    private let viewModel: IdlePillViewModel

    init(viewModel: IdlePillViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        if panel != nil { return }

        let view = IdlePillView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: view)

        let panelWidth: CGFloat = 350
        let panelHeight: CGFloat = 90
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = NSPanel(
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

        // Mouse tracking overlay for hover + click
        let tracker = IdlePillTrackingView(frame: hosting.bounds)
        tracker.autoresizingMask = [.width, .height]
        tracker.onEnter = { [weak self] in
            Task { @MainActor in self?.viewModel.isHovered = true }
        }
        tracker.onExit = { [weak self] in
            Task { @MainActor in self?.viewModel.isHovered = false }
        }
        tracker.onClicked = { [weak self] in
            Task { @MainActor in self?.viewModel.onStartDictation?() }
        }

        // Clickable rect: centered at bottom of panel, generous hit area covering both tooltip and pill
        let pillWidth: CGFloat = 320
        let pillHeight: CGFloat = 80
        let pillX = (panelWidth - pillWidth) / 2
        tracker.clickableRect = NSRect(x: pillX, y: 0, width: pillWidth, height: pillHeight)

        hosting.addSubview(tracker)
        trackingView = tracker

        // Position at bottom-center, just above the Dock
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.origin.y + 12
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.panel = panel
        self.hostingView = hosting
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        trackingView = nil
    }
}
