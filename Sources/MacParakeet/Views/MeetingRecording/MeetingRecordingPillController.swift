import AppKit
import MacParakeetViewModels
import SwiftUI

private final class MeetingRecordingClickablePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Custom content view that forwards right-click for context menu.
private class PillContentView: NSView {
    var onRightClick: ((NSEvent) -> Void)?

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {}

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}

/// Menu delegate that handles context menu item actions via target-action.
private class PillMenuDelegate: NSObject {
    let onStop: () -> Void
    let onOpen: () -> Void
    let onCancel: () -> Void

    init(onStop: @escaping () -> Void, onOpen: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onStop = onStop
        self.onOpen = onOpen
        self.onCancel = onCancel
    }

    @objc func menuAction(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "stop": onStop()
        case "open": onOpen()
        case "cancel": onCancel()
        default: break
        }
    }
}

@MainActor
final class MeetingRecordingPillController {
    private var panel: NSPanel?
    private let pillViewModel: MeetingRecordingPillViewModel
    var onClick: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var onOpenApp: (() -> Void)?
    var onCancelRecording: (() -> Void)?

    init(viewModel: MeetingRecordingPillViewModel) {
        self.pillViewModel = viewModel
    }

    func show() {
        if let panel {
            panel.orderFront(nil)
            return
        }

        let view = MeetingRecordingPillView(
            viewModel: pillViewModel,
            onTap: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.onClick?()
                }
            }
        )
        let hosting = NSHostingView(rootView: view)

        let panelWidth: CGFloat = 240
        let panelHeight: CGFloat = 150
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hosting.autoresizingMask = [.width, .height]

        // Content view with right-click support
        let contentView = PillContentView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        contentView.autoresizingMask = [.width, .height]
        contentView.onRightClick = { [weak self] event in
            self?.showContextMenu(with: event)
        }

        hosting.frame = contentView.bounds
        contentView.addSubview(hosting)

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
        panel.isMovableByWindowBackground = true
        panel.contentView = contentView

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.maxX - panelWidth - 12
            let y = frame.midY - panelHeight / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Context Menu

    private func showContextMenu(with event: NSEvent) {
        guard let contentView = panel?.contentView else { return }

        let menu = NSMenu()

        let delegate = PillMenuDelegate(
            onStop: { [weak self] in
                Task { @MainActor [weak self] in self?.onStopRecording?() }
            },
            onOpen: { [weak self] in
                Task { @MainActor [weak self] in self?.onOpenApp?() }
            },
            onCancel: { [weak self] in
                Task { @MainActor [weak self] in self?.onCancelRecording?() }
            }
        )

        // Listening header — organic language matching the flower metaphor
        let elapsed = pillViewModel.formattedElapsed
        let headerItem = NSMenuItem(title: "Listening — \(elapsed)", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        if let headerImage = NSImage(systemSymbolName: "leaf", accessibilityDescription: nil) {
            headerItem.image = headerImage.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            headerItem.image?.isTemplate = true
        }
        menu.addItem(headerItem)

        menu.addItem(.separator())

        // End & Transcribe — the flower completes its cycle
        let stopItem = NSMenuItem(title: "End & Transcribe", action: #selector(PillMenuDelegate.menuAction(_:)), keyEquivalent: "")
        stopItem.representedObject = "stop"
        stopItem.target = delegate
        if let stopImage = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil) {
            stopItem.image = stopImage.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            stopItem.image?.isTemplate = true
        }
        menu.addItem(stopItem)

        let openItem = NSMenuItem(title: "Open MacParakeet", action: #selector(PillMenuDelegate.menuAction(_:)), keyEquivalent: "")
        openItem.representedObject = "open"
        openItem.target = delegate
        if let openImage = NSImage(systemSymbolName: "bird", accessibilityDescription: nil) {
            openItem.image = openImage.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            openItem.image?.isTemplate = true
        }
        menu.addItem(openItem)

        menu.addItem(.separator())

        // Discard — destructive, red
        let cancelItem = NSMenuItem(title: "Discard Recording", action: #selector(PillMenuDelegate.menuAction(_:)), keyEquivalent: "")
        cancelItem.representedObject = "cancel"
        cancelItem.target = delegate
        cancelItem.attributedTitle = NSAttributedString(
            string: "Discard Recording",
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        if let cancelImage = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                .applying(.init(paletteColors: [.systemRed]))
            cancelItem.image = cancelImage.withSymbolConfiguration(config)
        }
        menu.addItem(cancelItem)

        // Keep delegate alive while menu is open
        objc_setAssociatedObject(menu, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        NSMenu.popUpContextMenu(menu, with: event, for: contentView)
    }
}
