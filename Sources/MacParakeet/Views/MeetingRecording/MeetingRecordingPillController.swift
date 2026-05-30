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

    private var activePillRect: NSRect {
        let height = min(bounds.height, 86)
        return NSRect(
            x: bounds.minX,
            y: bounds.midY - height / 2,
            width: bounds.width,
            height: height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        activePillRect.contains(point) ? super.hitTest(point) : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard activePillRect.contains(point) else { return }
        onRightClick?(event)
    }
}

/// Menu delegate that handles context menu item actions via target-action.
private class PillMenuDelegate: NSObject {
    let onStop: () -> Void
    let onOpen: () -> Void
    let onCancel: () -> Void
    let onPauseToggle: () -> Void

    init(
        onStop: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onPauseToggle: @escaping () -> Void
    ) {
        self.onStop = onStop
        self.onOpen = onOpen
        self.onCancel = onCancel
        self.onPauseToggle = onPauseToggle
    }

    @objc func menuAction(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "stop": onStop()
        case "open": onOpen()
        case "cancel": onCancel()
        case "pauseToggle": onPauseToggle()
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
    var onPauseToggle: (() -> Void)?

    init(viewModel: MeetingRecordingPillViewModel) {
        self.pillViewModel = viewModel
    }

    func show() {
        if let panel {
            panel.orderFront(nil)
            return
        }

        let view = MeetingRecordingAppKitPillView(
            viewModel: pillViewModel,
            onTap: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.onClick?()
                }
            }
        )

        let panelWidth: CGFloat = 118
        let panelHeight: CGFloat = 150

        // Content view with right-click support
        let contentView = PillContentView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        contentView.autoresizingMask = [.width, .height]
        contentView.onRightClick = { [weak self] event in
            self?.showContextMenu(with: event)
        }

        view.frame = contentView.bounds
        view.autoresizingMask = [.width, .height]
        contentView.addSubview(view)

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
            let x = frame.maxX - panelWidth
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
            },
            onPauseToggle: { [weak self] in
                Task { @MainActor [weak self] in self?.onPauseToggle?() }
            }
        )

        // Listening / Paused header — organic language matching the flower
        // metaphor; reflects the live state so the menu reads honestly when
        // opened mid-pause. Keeping the leaf symbol across both states
        // preserves the brand vocabulary (`leaf` / `leaf.fill` for active /
        // completing); a paused recording is still "the leaf, dormant".
        let isPaused = pillViewModel.isPaused
        let elapsed = pillViewModel.formattedElapsed
        let headerTitle = isPaused ? "Paused — \(elapsed)" : "Listening — \(elapsed)"
        let headerSymbol = "leaf"
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        if let headerImage = NSImage(systemSymbolName: headerSymbol, accessibilityDescription: nil) {
            headerItem.image = headerImage.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            headerItem.image?.isTemplate = true
        }
        menu.addItem(headerItem)

        menu.addItem(.separator())

        // Pause / Resume — issue #235. Sits above End & Transcribe so the
        // flow is "pause → think → resume" without leaving the menu.
        if pillViewModel.canTogglePause {
            let pauseItem = NSMenuItem(
                title: isPaused ? "Resume Recording" : "Pause Recording",
                action: #selector(PillMenuDelegate.menuAction(_:)),
                keyEquivalent: ""
            )
            pauseItem.representedObject = "pauseToggle"
            pauseItem.target = delegate
            if let pauseImage = NSImage(systemSymbolName: isPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil) {
                pauseItem.image = pauseImage.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
                pauseItem.image?.isTemplate = true
            }
            menu.addItem(pauseItem)
        }

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

private final class MeetingRecordingAppKitPillView: NSView {
    private let viewModel: MeetingRecordingPillViewModel
    private let onTap: () -> Void
    private let iconView = MerkabaPillIconView()
    private let backgroundLayer = CAShapeLayer()
    private let pauseLayer = CALayer()
    // Hover-revealed elapsed-time badge (red/amber dot + timer) above the
    // capsule — restores the prior SwiftUI pill's hover affordance that the
    // CALayer migration dropped.
    private let timeBadgeLayer = CAShapeLayer()
    private let timeDotLayer = CAShapeLayer()
    private let timeTextLayer = CATextLayer()
    private let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private var updateTimer: Timer?
    private var completionCallbackScheduled = false
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var renderedState: MeetingRecordingPillViewModel.PillState?
    private var renderedAudioLevel: Float = -1
    private var renderedHover: Bool?
    private var renderedReduceMotion: Bool?

    /// System Settings → Accessibility → Display → Reduce Motion. The pill
    /// still shows (and tracks recording state via color/timer), it just stops
    /// spinning the rosette for vestibular-sensitive users — matching the
    /// `reduceMotion` gate the prior SwiftUI pill and every other animated
    /// surface honor.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override var isFlipped: Bool { true }

    init(viewModel: MeetingRecordingPillViewModel, onTap: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onTap = onTap
        super.init(frame: .zero)
        wantsLayer = true
        setupLayers()
        updateFromViewModel()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateFromViewModel()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reduceMotionDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        updateTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func reduceMotionDidChange() {
        updateFromViewModel()
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        timeTextLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackground()
        updateTimeBadge()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
        updateTimeBadge()
    }

    override func mouseDown(with event: NSEvent) {
        onTap()
    }

    private func setupLayers() {
        guard let layer else { return }
        layer.masksToBounds = false
        backgroundLayer.fillColor = NSColor.black.withAlphaComponent(0.88).cgColor
        backgroundLayer.strokeColor = NSColor.white.withAlphaComponent(0.08).cgColor
        backgroundLayer.lineWidth = 0.5
        layer.addSublayer(backgroundLayer)

        iconView.configure(showStem: true)
        addSubview(iconView)

        let leftBar = pauseBar()
        let rightBar = pauseBar()
        leftBar.frame.origin.x = 0
        rightBar.frame.origin.x = 7
        pauseLayer.addSublayer(leftBar)
        pauseLayer.addSublayer(rightBar)
        pauseLayer.isHidden = true
        layer.addSublayer(pauseLayer)

        setupTimeBadge(in: layer)
    }

    private func setupTimeBadge(in root: CALayer) {
        let scale = window?.backingScaleFactor ?? 2
        timeBadgeLayer.fillColor = NSColor.black.withAlphaComponent(0.72).cgColor
        timeBadgeLayer.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        timeBadgeLayer.lineWidth = 0.5
        timeBadgeLayer.shadowColor = NSColor.black.cgColor
        timeBadgeLayer.shadowOpacity = 0.25
        timeBadgeLayer.shadowRadius = 6
        timeBadgeLayer.shadowOffset = CGSize(width: 0, height: -2)
        timeBadgeLayer.opacity = 0

        timeDotLayer.fillColor = NSColor.systemRed.cgColor

        timeTextLayer.font = badgeFont
        timeTextLayer.fontSize = badgeFont.pointSize
        timeTextLayer.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        timeTextLayer.alignmentMode = .left
        timeTextLayer.contentsScale = scale
        timeTextLayer.isWrapped = false

        timeBadgeLayer.addSublayer(timeDotLayer)
        timeBadgeLayer.addSublayer(timeTextLayer)
        root.addSublayer(timeBadgeLayer)
    }

    private func pauseBar() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer.cornerRadius = 1.5
        layer.frame = CGRect(x: 0, y: 0, width: 3, height: 11)
        return layer
    }

    private func layoutLayers() {
        // Compact capsule that hugs the rosette + stem with even breathing room
        // (was 54x106, which left ~20pt of dead space above and below the
        // flower). Centered on the panel's midY so the icon and pause-bars stay
        // put regardless of the capsule height — only the black surface shrinks.
        let pillWidth: CGFloat = 54
        let pillHeight: CGFloat = 86
        let pillRect = CGRect(
            x: bounds.maxX - 74,
            y: bounds.midY - pillHeight / 2,
            width: pillWidth,
            height: pillHeight
        )
        backgroundLayer.path = CGPath(
            roundedRect: pillRect,
            cornerWidth: pillWidth / 2,
            cornerHeight: pillWidth / 2,
            transform: nil
        )
        iconView.frame = CGRect(x: pillRect.midX - 15, y: pillRect.midY - 37, width: 30, height: 74)
        pauseLayer.frame = CGRect(x: pillRect.midX - 5, y: pillRect.midY - 5.5, width: 10, height: 11)
    }

    /// Hover-revealed elapsed-time badge: red dot (amber when paused) + the live
    /// timer, in a dark capsule centered above the pill. Shown only while
    /// hovering an active recording; the timer text refreshes each second.
    private func updateTimeBadge() {
        let state = viewModel.state
        let active: Bool
        switch state {
        case .recording, .paused:
            active = isHovered && viewModel.elapsedSeconds > 0
        default:
            active = false
        }

        guard active else {
            if timeBadgeLayer.opacity != 0 {
                timeBadgeLayer.opacity = 0
            }
            return
        }

        let text = viewModel.formattedElapsed
        let isPaused = (state == .paused)

        // Disable implicit animations for the per-second text/relayout so the
        // digits update crisply; the fade-in is driven separately by opacity.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        timeDotLayer.fillColor = (isPaused ? NSColor.systemOrange : NSColor.systemRed).cgColor
        if (timeTextLayer.string as? String) != text {
            timeTextLayer.string = text
        }
        layoutTimeBadge(text: text)
        CATransaction.commit()

        if timeBadgeLayer.opacity != 1 {
            timeBadgeLayer.opacity = 1
        }
    }

    private func layoutTimeBadge(text: String) {
        let textSize = (text as NSString).size(withAttributes: [.font: badgeFont])
        let dot: CGFloat = 5
        let gap: CGFloat = 5
        let hPad: CGFloat = 10
        let vPad: CGFloat = 5
        let badgeH = ceil(textSize.height) + vPad * 2
        let badgeW = dot + gap + ceil(textSize.width) + hPad * 2

        let capsuleMidX = bounds.maxX - 74 + 27
        let capsuleTop = bounds.midY - 43
        let badgeX = capsuleMidX - badgeW / 2
        let badgeY = capsuleTop - badgeH - 4

        timeBadgeLayer.frame = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)
        timeBadgeLayer.path = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: badgeW, height: badgeH),
            cornerWidth: badgeH / 2,
            cornerHeight: badgeH / 2,
            transform: nil
        )

        let centerY = badgeH / 2
        timeDotLayer.frame = CGRect(x: hPad, y: centerY - dot / 2, width: dot, height: dot)
        timeDotLayer.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: dot, height: dot), transform: nil)
        timeTextLayer.frame = CGRect(
            x: hPad + dot + gap,
            y: centerY - ceil(textSize.height) / 2,
            width: ceil(textSize.width) + 1,
            height: ceil(textSize.height)
        )
    }

    private func updateFromViewModel() {
        let state = viewModel.state
        let reduceMotion = self.reduceMotion
        let audioLevel: Float
        switch state {
        case .recording:
            audioLevel = max(viewModel.micLevel, viewModel.systemLevel)
        default:
            audioLevel = 0
        }

        // The elapsed time ticks every second even when state/audioLevel are
        // unchanged (e.g. silence), so refresh the hover badge before the
        // render-skip fast path.
        updateTimeBadge()

        if renderedState == state, renderedAudioLevel == audioLevel, renderedReduceMotion == reduceMotion {
            updateBackgroundIfNeeded()
            return
        }

        renderedState = state
        renderedAudioLevel = audioLevel
        renderedReduceMotion = reduceMotion

        switch viewModel.state {
        case .recording:
            pauseLayer.isHidden = true
            iconView.alphaValue = 1.0
            iconView.update(isAnimating: !reduceMotion, audioLevel: audioLevel)
        case .paused:
            pauseLayer.isHidden = false
            iconView.alphaValue = 0.45
            iconView.update(isAnimating: false, audioLevel: 0)
        case .completing:
            pauseLayer.isHidden = true
            iconView.alphaValue = 1.0
            iconView.update(isAnimating: !reduceMotion, audioLevel: 0)
            scheduleCompletionCallbackIfNeeded()
        default:
            pauseLayer.isHidden = true
            iconView.alphaValue = 1.0
            iconView.update(isAnimating: false, audioLevel: 0)
        }
        updateBackgroundIfNeeded()
    }

    private func scheduleCompletionCallbackIfNeeded() {
        guard !completionCallbackScheduled else { return }
        completionCallbackScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.viewModel.onCompletionAnimationFinished?()
        }
    }

    private func updateBackground() {
        renderedHover = nil
        updateBackgroundIfNeeded()
    }

    private func updateBackgroundIfNeeded() {
        guard renderedHover != isHovered else { return }
        renderedHover = isHovered
        backgroundLayer.fillColor = NSColor.black.withAlphaComponent(isHovered ? 0.90 : 0.88).cgColor
        backgroundLayer.strokeColor = NSColor.white.withAlphaComponent(isHovered ? 0.15 : 0.08).cgColor
    }
}
