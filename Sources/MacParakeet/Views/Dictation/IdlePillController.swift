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
    /// Rects for the expanded pill + tooltip (stays hovered while interacting).
    /// Side edges use two rects, so the empty space beside the tooltip
    /// passes clicks through to the app below.
    var expandedPillRects: [NSRect] = []

    private var isInsidePill = false
    private var isExpanded = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
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
        let activeRects = isExpanded ? expandedPillRects : [collapsedPillRect]

        if activeRects.contains(where: { $0.contains(point) }) {
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
        let activeRects = isExpanded ? expandedPillRects : [collapsedPillRect]
        if activeRects.contains(where: { $0.contains(point) }) {
            onClicked?()
        }
    }

    // Only intercept clicks in the visible pill region; pass through everywhere else.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let activeRects = isExpanded ? expandedPillRects : [collapsedPillRect]
        return activeRects.contains(where: { $0.contains(point) }) ? self : nil
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

    /// Left/Right put the tooltip beside a vertical pill, so they need a
    /// wider, taller panel than Bottom/Top.
    private static func panelSize(for placement: DictationOverlayPlacement) -> CGSize {
        placement.isVertical ? CGSize(width: 400, height: 170) : CGSize(width: 350, height: 90)
    }

    init(viewModel: IdlePillViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        if panel != nil { return }

        let view = IdlePillView(viewModel: viewModel)
        // No `.tint(...)` — pill is fully custom-drawn (no .borderedProminent /
        // Toggle / ProgressView), and `hostingView: NSHostingView<IdlePillView>`
        // is typed against the bare view.
        let hosting = NSHostingView(rootView: view)

        let panelSize = Self.panelSize(for: DictationOverlayPlacement.current())
        hosting.frame = NSRect(origin: .zero, size: panelSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
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
        self.panel = panel
        self.hostingView = hosting
        reposition()

        panel.orderFront(nil)
    }

    func reposition() {
        guard let panel, let trackingView else { return }
        let placement = DictationOverlayPlacement.current()
        viewModel.placement = placement

        // Hover zones hug the anchored edge: the nub (48×10 + targeting slack)
        // collapsed, and the pill + tooltip once expanded.
        let panelSize = Self.panelSize(for: placement)
        func edgeRect(length: CGFloat, depth: CGFloat) -> NSRect {
            DictationOverlayLayout.edgeRect(length: length, depth: depth, panelSize: panelSize, placement: placement)
        }
        trackingView.collapsedPillRect = edgeRect(length: 60, depth: 24)
        // Side edges: an 8pt inset + 30pt pill + 6pt gap column along the
        // edge, plus a band as tall as the tooltip reaching across the panel.
        if placement.isVertical {
            trackingView.expandedPillRects = [
                edgeRect(length: 160, depth: 48),
                edgeRect(length: 48, depth: panelSize.width),
            ]
        } else {
            trackingView.expandedPillRects = [edgeRect(length: 320, depth: 80)]
        }

        panel.moveToDictationOverlayPosition(placement: placement, size: panelSize)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        trackingView = nil
    }
}
