import AppKit
import MacParakeetCore

final class MenuBarDropView: NSView {
    var onDrop: ((URL) -> Void)?

    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Pass all mouse events through to the NSStatusBarButton so the
    // system's native menu-opening behavior works unimpeded.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Only draw the drag-highlight glow; the normal icon is rendered
        // by the NSStatusBarButton's .image (template-tinted by the system).
        if isDragging {
            let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            circle.fill()

            let border = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
            NSColor.controlAccentColor.withAlphaComponent(0.5).setStroke()
            border.lineWidth = 1.0
            border.stroke()
        }
    }

    // MARK: - Dragging Destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let canAccept = canAcceptDrop(sender)
        isDragging = canAccept != []
        needsDisplay = true
        return canAccept
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptDrop(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragging = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragging = false
        needsDisplay = true

        guard let url = getFileURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    private func canAcceptDrop(_ draggingInfo: NSDraggingInfo) -> NSDragOperation {
        guard let url = getFileURL(from: draggingInfo) else { return [] }
        let ext = url.pathExtension.lowercased()
        return AudioFileConverter.supportedExtensions.contains(ext) ? .copy : []
    }

    private func getFileURL(from draggingInfo: NSDraggingInfo) -> URL? {
        let pasteboard = draggingInfo.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        return urls.first
    }
}
