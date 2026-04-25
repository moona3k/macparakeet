import AppKit

/// Hosts SwiftUI content and an AppKit overlay as siblings, which avoids
/// mutating `NSHostingView`'s internal view hierarchy.
final class OverlayHostingContainerView: NSView {
    let hostingView: NSView
    let overlayView: NSView

    init(frame: NSRect, hostingView: NSView, overlayView: NSView) {
        self.hostingView = hostingView
        self.overlayView = overlayView
        super.init(frame: frame)

        autoresizesSubviews = true

        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)

        overlayView.frame = bounds
        overlayView.autoresizingMask = [.width, .height]
        addSubview(overlayView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
