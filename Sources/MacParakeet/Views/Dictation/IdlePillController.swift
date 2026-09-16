import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

// MARK: - Mouse Tracking (click-aware)

/// NSView overlay that detects mouse hover and clicks for the idle pill.
/// Uses mouseMoved to precisely track whether the cursor is over the pill region,
/// not the entire panel. The hover rect changes based on expanded state.
private final class IdlePillTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onClicked: (() -> Void)?

    /// Small rect for the collapsed pill (hover trigger zone).
    var collapsedPillRect: NSRect = .zero
    /// Larger rect for the expanded pill + tooltip (stays hovered while interacting).
    var expandedPillRect: NSRect = .zero

    private var isInsidePill = false
    private var isExpanded = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self
            ))
    }

    override func mouseEntered(with event: NSEvent) {
        // Panel entered — start tracking position
    }

    override func mouseExited(with event: NSEvent) {
        // Left the panel entirely — always exit hover
        if isInsidePill {
            isInsidePill = false
            isExpanded = false
            onExit?()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let activeRect = isExpanded ? expandedPillRect : collapsedPillRect

        if activeRect.contains(point) {
            if !isInsidePill {
                isInsidePill = true
                isExpanded = true
                onEnter?()
            }
        } else {
            if isInsidePill {
                isInsidePill = false
                isExpanded = false
                onExit?()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let activeRect = isExpanded ? expandedPillRect : collapsedPillRect
        if activeRect.contains(point) {
            onClicked?()
        }
    }

    // Only intercept clicks in the visible pill region; pass through everywhere else.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let activeRect = isExpanded ? expandedPillRect : collapsedPillRect
        return activeRect.contains(point) ? self : nil
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

        viewModel.anchorsToTop = DictationOverlayPlacement.current().anchorsToTop
        let view = IdlePillView(viewModel: viewModel)
        // No `.tint(...)` — pill is fully custom-drawn (no .borderedProminent /
        // Toggle / ProgressView), and `hostingView: NSHostingView<IdlePillView>`
        // is typed against the bare view.
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

        hosting.addSubview(tracker)
        trackingView = tracker
        applyPlacement(to: tracker, panelWidth: panelWidth, panelHeight: panelHeight)
        position(panel, width: panelWidth, height: panelHeight)

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

    func reposition() {
        guard let panel, let hostingView else { return }
        applyPlacement(
            to: trackingView,
            panelWidth: hostingView.frame.width,
            panelHeight: hostingView.frame.height
        )
        position(panel, width: hostingView.frame.width, height: hostingView.frame.height)
    }

    private func applyPlacement(
        to tracker: IdlePillTrackingView?,
        panelWidth: CGFloat,
        panelHeight: CGFloat
    ) {
        let placement = DictationOverlayPlacement.current()
        viewModel.anchorsToTop = placement.anchorsToTop
        guard let tracker else { return }

        let collapsedW: CGFloat = 60
        let collapsedH: CGFloat = 24
        let collapsedX = (panelWidth - collapsedW) / 2
        let expandedW: CGFloat = 320
        let expandedH: CGFloat = 80
        let expandedX = (panelWidth - expandedW) / 2
        let collapsedY: CGFloat = placement.anchorsToTop ? panelHeight - collapsedH : 0
        let expandedY: CGFloat = placement.anchorsToTop ? panelHeight - expandedH : 0
        tracker.collapsedPillRect = NSRect(x: collapsedX, y: collapsedY, width: collapsedW, height: collapsedH)
        tracker.expandedPillRect = NSRect(x: expandedX, y: expandedY, width: expandedW, height: expandedH)
    }

    private func position(_ panel: NSPanel, width: CGFloat, height: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let origin = DictationOverlayLayout.origin(
            in: screen.visibleFrame,
            panelSize: CGSize(width: width, height: height),
            placement: DictationOverlayPlacement.current()
        )
        panel.setFrameOrigin(origin)
    }
}
