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
    private weak var pillView: MeetingRecordingAppKitPillView?
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
        self.pillView = view

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
        pillView = nil
    }

    /// Forwards the coordinator's fast (~30 fps) audio level to the pill so the
    /// rosette glow tracks speech live. No-op once the pill is hidden.
    func updateLiveAudioLevel(_ level: Float) {
        pillView?.updateLiveAudioLevel(level)
    }

    /// Push a view-model state change to the pill immediately, so the
    /// recording → completing → transcribing → completed faces switch on the
    /// transition rather than on the pill's next 1 s tick. No-op once hidden.
    func refreshState() {
        pillView?.refresh()
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
    /// 1 s ticker for the elapsed-time badge. A `@MainActor` `Task` rather than a
    /// `Timer` so (a) its body runs in-isolation (no nonisolated `@Sendable`
    /// hop to call `updateFromViewModel`) and (b) `Task` is `Sendable`, so the
    /// nonisolated `deinit` can cancel it — both Swift 6 language-mode clean.
    private var tickTask: Task<Void, Never>?
    private var completionCallbackScheduled = false
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var renderedState: MeetingRecordingPillViewModel.PillState?
    private var renderedHover: Bool?
    private var renderedReduceMotion: Bool?
    /// The recording capsule is tall to host the rosette + stem; the stem-less
    /// states (transcribing/completed) shrink it to a circle that hugs the
    /// compact mark — matching the prior SwiftUI pill's separate `iconPill`. The
    /// circle keeps the capsule's top edge and rises from the bottom, so the
    /// collapse reads as the stem being absorbed into the head.
    private var compactContainer = false
    private let pillWidth: CGFloat = 54
    private let pillTallHeight: CGFloat = 86

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
        // Drives the per-second elapsed badge text. State *transitions* are
        // pushed promptly by the coordinator via `refresh()` (see
        // `MeetingRecordingPillController.refreshState()`), so the stop →
        // collapse → spinner → checkmark sequence reacts immediately instead of
        // waiting up to a poll interval.
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                self?.updateFromViewModel()
            }
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
        tickTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func reduceMotionDidChange() {
        updateFromViewModel()
    }

    /// Pull the latest view-model state immediately (pushed by the coordinator
    /// on a state transition, so animations don't wait for the 1 s timer).
    func refresh() {
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
        // The icon + pause-bars are positioned from the *tall* rect so the mark
        // (rosette head / spinner / checkmark) stays put across states — only
        // the black surface shrinks to a circle for the stem-less states.
        let tallRect = containerRect(compact: false)
        backgroundLayer.path = backgroundPath(compact: compactContainer)
        iconView.frame = CGRect(x: tallRect.midX - 15, y: tallRect.midY - 37, width: 30, height: 74)
        pauseLayer.frame = CGRect(x: tallRect.midX - 5, y: tallRect.midY - 5.5, width: 10, height: 11)
    }

    /// The capsule rect for a given state. Both shapes share the same top edge
    /// (`midY − tallHeight/2`); the compact circle just stops at `pillWidth`
    /// tall, so the bottom rises toward the head.
    private func containerRect(compact: Bool) -> CGRect {
        let top = bounds.midY - pillTallHeight / 2
        let height = compact ? pillWidth : pillTallHeight
        return CGRect(x: bounds.maxX - 74, y: top, width: pillWidth, height: height)
    }

    private func backgroundPath(compact: Bool) -> CGPath {
        // cornerRadius = pillWidth/2 → stadium when tall, perfect circle when compact.
        CGPath(
            roundedRect: containerRect(compact: compact),
            cornerWidth: pillWidth / 2,
            cornerHeight: pillWidth / 2,
            transform: nil
        )
    }

    /// Switch the capsule between tall and circular. When `animated` (the
    /// stop → collapse transition), the path interpolates from its current
    /// presentation so the capsule visibly absorbs the stem as the flower
    /// collapses; otherwise it snaps (recording re-entry, fresh layout).
    private func applyContainer(compact: Bool, animated: Bool) {
        compactContainer = compact
        let newPath = backgroundPath(compact: compact)
        if animated {
            let resize = CABasicAnimation(keyPath: "path")
            resize.fromValue = backgroundLayer.presentation()?.path ?? backgroundLayer.path
            resize.toValue = newPath
            resize.duration = reduceMotion ? 0.4 : 0.85
            resize.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            backgroundLayer.add(resize, forKey: "containerResize")
        }
        backgroundLayer.path = newPath
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

    /// Live audio level pushed from the coordinator's fast (~30 fps) glow
    /// channel. Drives only the rosette glow opacity (CALayer) — never an
    /// `@Observable` write — so the "internal light" tracks speech without the
    /// per-tick SwiftUI relayout that the 1 s state poll would cause.
    func updateLiveAudioLevel(_ level: Float) {
        iconView.setLiveGlow(level: level)
    }

    private func updateFromViewModel() {
        let state = viewModel.state
        let reduceMotion = self.reduceMotion

        // The elapsed time ticks every second even when state is unchanged
        // (e.g. silence), so refresh the hover badge before the render-skip.
        updateTimeBadge()

        if renderedState == state, renderedReduceMotion == reduceMotion {
            updateBackgroundIfNeeded()
            return
        }

        renderedState = state
        renderedReduceMotion = reduceMotion

        switch state {
        case .recording:
            pauseLayer.isHidden = true
            iconView.alphaValue = 1.0
            applyContainer(compact: false, animated: false)
            // Glow is driven live by updateLiveAudioLevel; this sets the
            // resting base + starts the rosette rotation.
            iconView.update(isAnimating: !reduceMotion, audioLevel: 0)
        case .paused:
            pauseLayer.isHidden = false
            iconView.alphaValue = 0.45
            applyContainer(compact: false, animated: false)
            iconView.update(isAnimating: false, audioLevel: 0)
        case .completing:
            pauseLayer.isHidden = true
            iconView.alphaValue = 1.0
            // Shrink the capsule to a circle in sync with the collapsing flower.
            applyContainer(compact: true, animated: true)
            playCompletionIfNeeded(reduceMotion: reduceMotion)
        case .transcribing:
            pauseLayer.isHidden = true
            iconView.alphaValue = 1.0
            applyContainer(compact: true, animated: false)
            iconView.showSpinner(animated: !reduceMotion)
        case .completed:
            pauseLayer.isHidden = true
            iconView.alphaValue = 1.0
            applyContainer(compact: true, animated: false)
            iconView.showCheckmark(animated: !reduceMotion)
        case .idle, .error:
            pauseLayer.isHidden = true
            iconView.alphaValue = 1.0
            applyContainer(compact: false, animated: false)
            iconView.update(isAnimating: false, audioLevel: 0)
        }
        updateBackgroundIfNeeded()
    }

    /// The merkaba collapse plays once; its completion (~1 s, or a quick fade
    /// under Reduce Motion) advances the flow to the spinner/checkmark.
    private func playCompletionIfNeeded(reduceMotion: Bool) {
        guard !completionCallbackScheduled else { return }
        completionCallbackScheduled = true
        iconView.playCompletion(reduceMotion: reduceMotion) { [weak self] in
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
