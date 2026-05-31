import AppKit
import MacParakeetCore

final class MenuBarDropView: NSView {
    var onDrop: (([URL]) -> Void)?

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

        // Hand off every dropped URL (files and folders); the ViewModel expands
        // folders and decides single vs. batch. Empty/unsupported drops are
        // filtered downstream, so accept the drop as long as we got any URLs.
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func canAcceptDrop(_ draggingInfo: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(from: draggingInfo)
        // Accept if at least one dragged item is a supported file or a folder
        // (a folder may contain supported files, expanded after the drop).
        let acceptable = urls.contains { url in
            AudioFileConverter.supportedExtensions.contains(url.pathExtension.lowercased())
                || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        return acceptable ? .copy : []
    }

    private func fileURLs(from draggingInfo: NSDraggingInfo) -> [URL] {
        let pasteboard = draggingInfo.draggingPasteboard
        return pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
    }
}
