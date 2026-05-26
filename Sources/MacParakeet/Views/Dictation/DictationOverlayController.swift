import AppKit
import MacParakeetCore
import SwiftUI

// MARK: - Mouse Tracking

/// NSView overlay that detects mouse hover and position via NSTrackingArea with `.activeAlways`.
/// Required because `.help()`, `.onHover`, and standard tracking options
/// all fail on non-activating NSPanel. See CLAUDE.md Known Pitfalls.
final class MouseTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    var shouldReceiveMouseDown: ((NSPoint) -> Bool)?
    var onClick: ((NSPoint) -> Void)?

    private var mouseDownPoint: NSPoint?

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
        onEnter?()
        onMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { onExit?() }

    override func mouseMoved(with event: NSEvent) {
        onMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        let upPoint = convert(event.locationInWindow, from: nil)
        if let downPoint = mouseDownPoint,
           shouldReceiveMouseDown?(downPoint) == true,
           shouldReceiveMouseDown?(upPoint) == true {
            onClick?(upPoint)
        }
        mouseDownPoint = nil
    }

    // Only intercept clicks in the visible control regions; pass through everywhere else.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        return shouldReceiveMouseDown?(localPoint) == true ? self : nil
    }
}

// MARK: - Keyless Non-Activating Panel

final class DictationOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum DictationOverlayControlHitTarget: Equatable {
    case cancel
    case stop
}

struct DictationOverlayControlHitTesting {
    static let pillWidth: CGFloat = 210
    static let controlZoneWidth: CGFloat = 45
    static let controlRowBottomPadding: CGFloat = 8
    static let controlRowHeight: CGFloat = 36
    static let controlRowHitSlop: CGFloat = 6

    static func target(
        at point: NSPoint,
        in bounds: NSRect,
        overlayState: DictationOverlayViewModel.OverlayState,
        recordingMode: FnKeyStateMachine.RecordingMode,
        requiresVisibleControlRow: Bool = false
    ) -> DictationOverlayControlHitTarget? {
        guard bounds.width >= pillWidth else {
            return nil
        }

        guard case .recording = overlayState,
              recordingMode == .persistent else {
            return nil
        }

        if requiresVisibleControlRow {
            let controlBottom = bounds.minY + controlRowBottomPadding - controlRowHitSlop
            let controlTop = bounds.minY + controlRowBottomPadding + controlRowHeight + controlRowHitSlop
            guard point.y >= controlBottom && point.y <= controlTop else {
                return nil
            }
        }

        let pillLeft = (bounds.width - pillWidth) / 2
        let pillRight = pillLeft + pillWidth
        let x = point.x

        if x >= pillLeft && x < pillLeft + controlZoneWidth {
            return .cancel
        }
        if x > pillRight - controlZoneWidth && x <= pillRight {
            return .stop
        }
        return nil
    }
}

@MainActor
protocol DictationOverlayControlling: AnyObject {
    func show()
    func hide()
    func resignKeyWindow()
}

// MARK: - Overlay Controller

/// Manages the floating dictation overlay panel.
/// Non-activating NSPanel that never steals focus from the active app.
@MainActor
final class DictationOverlayController: DictationOverlayControlling {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<DictationOverlayView>?
    private var trackingView: MouseTrackingView?

    private let overlayViewModel: DictationOverlayViewModel

    init(viewModel: DictationOverlayViewModel) {
        self.overlayViewModel = viewModel
    }

    func show() {
        if panel != nil { return }

        let view = DictationOverlayView(viewModel: overlayViewModel)
        // No `.tint(...)` here — the overlay's controls are all custom-drawn,
        // so cascading the brand accent has no visible effect, and the typed
        // property `hostingView: NSHostingView<DictationOverlayView>` would
        // need widening to accept a `ModifiedContent<...>` payload.
        let hosting = NSHostingView(rootView: view)

        // Start with generous size — SwiftUI content sizes itself, panel background is clear
        let panelWidth: CGFloat = 300
        let panelHeight: CGFloat = 160
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = DictationOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI handles shadows; system shadow creates visible outline
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        // Mouse tracking overlay for hover tooltips
        let tracker = MouseTrackingView(frame: hosting.bounds)
        tracker.autoresizingMask = [.width, .height]
        tracker.onEnter = { [weak self] in self?.overlayViewModel.isHovered = true }
        tracker.onExit = { [weak self] in
            self?.overlayViewModel.isHovered = false
            self?.overlayViewModel.hoverTooltip = nil
        }
        tracker.onMoved = { [weak self, weak tracker] point in
            guard let tracker else { return }
            self?.updateHoverTooltip(at: point, in: tracker.bounds)
        }
        tracker.shouldReceiveMouseDown = { [weak self, weak tracker] point in
            guard let self, let tracker else { return false }
            return self.clickHitTarget(at: point, in: tracker.bounds) != nil
        }
        tracker.onClick = { [weak self, weak tracker] point in
            guard let self, let tracker else { return }
            switch self.clickHitTarget(at: point, in: tracker.bounds) {
            case .cancel:
                self.overlayViewModel.onCancel?()
            case .stop:
                self.overlayViewModel.onStop?()
            case nil:
                break
            }
        }
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

    /// Compatibility hook for paste flows that defensively clear overlay key state.
    /// DictationOverlayPanel is keyless, so this is normally a no-op.
    func resignKeyWindow() {
        panel?.resignKey()
    }

    /// Determine which element the cursor is over and update the tooltip.
    /// The pill is centered in the panel. Left zone = cancel, right zone = stop.
    private func updateHoverTooltip(at point: NSPoint, in bounds: NSRect) {
        switch controlHitTarget(at: point, in: bounds) {
        case .cancel:
            overlayViewModel.hoverTooltip = "Cancel (Esc)"
        case .stop:
            if overlayViewModel.sessionKind == .command {
                overlayViewModel.hoverTooltip = "Stop & apply (Fn+Control)"
            } else {
                let trigger = HotkeyTrigger.current
                overlayViewModel.hoverTooltip = trigger.isDisabled
                    ? "Stop & paste"
                    : "Stop & paste (\(trigger.displayName))"
            }
        case nil:
            overlayViewModel.hoverTooltip = nil
        }
    }

    private func controlHitTarget(at point: NSPoint, in bounds: NSRect) -> DictationOverlayControlHitTarget? {
        DictationOverlayControlHitTesting.target(
            at: point,
            in: bounds,
            overlayState: overlayViewModel.state,
            recordingMode: overlayViewModel.recordingMode
        )
    }

    private func clickHitTarget(at point: NSPoint, in bounds: NSRect) -> DictationOverlayControlHitTarget? {
        DictationOverlayControlHitTesting.target(
            at: point,
            in: bounds,
            overlayState: overlayViewModel.state,
            recordingMode: overlayViewModel.recordingMode,
            requiresVisibleControlRow: true
        )
    }

    func updateSize(width: CGFloat) {
        guard let panel else { return }
        var frame = panel.frame
        let oldWidth = frame.width
        frame.size.width = width
        frame.origin.x += (oldWidth - width) / 2
        panel.setFrame(frame, display: true, animate: true)
    }
}

/// ViewModel for the dictation overlay
@MainActor
@Observable
final class DictationOverlayViewModel {
    enum SessionKind {
        case dictation
        case command
    }

    enum OverlayState {
        case ready
        case recording
        case cancelled(timeRemaining: Double)
        case processing
        /// Post-STT LLM refinement beat. Visually distinct from `.processing`
        /// so users can see their transcript is being polished by the AI
        /// formatter before the checkmark lands. Only entered when the
        /// formatter is enabled and actually about to run.
        case formatting
        case success
        case noSpeech
        case error(String)
    }

    enum ProcessingLoadCaption: Equatable {
        case preparing
        case preparingExtended
        case failed
    }

    var state: OverlayState = .recording
    var sessionKind: SessionKind = .dictation
    var recordingMode: FnKeyStateMachine.RecordingMode = .persistent
    var audioLevel: Float = 0.0
    var recordingElapsedSeconds: Int = 0
    var isHovered: Bool = false
    var hoverTooltip: String?
    var processingMessage: String?
    var busyProcessingMessage: String?
    var processingLoadCaption: ProcessingLoadCaption?
    var commandPromptText: String = "Speak your command..."
    var commandSelectedText: String = ""

    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?
    var onUndo: (() -> Void)?
    var onDismiss: (() -> Void)?

    /// Cancel countdown value (separate from state enum to avoid view reconstruction jank).
    var cancelTimeRemaining: Double = 5.0

    private var timerTask: Task<Void, Never>?
    private var busyMessageTask: Task<Void, Never>?

    var visibleProcessingMessage: String? {
        busyProcessingMessage ?? processingMessage
    }

    func startTimer() {
        recordingElapsedSeconds = 0
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                self.recordingElapsedSeconds += 1
            }
        }
    }

    func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    func showBusyProcessingHint() {
        busyProcessingMessage = "Still transcribing..."
        busyMessageTask?.cancel()
        busyMessageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            self?.busyProcessingMessage = nil
        }
    }

    /// Resume timer without resetting elapsed time (used after undo cancel)
    func resumeTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                self.recordingElapsedSeconds += 1
            }
        }
    }

    var formattedElapsed: String {
        let minutes = recordingElapsedSeconds / 60
        let seconds = recordingElapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var commandSelectedCharacterCount: Int {
        commandSelectedText.count
    }

    var commandSelectedPreview: String {
        let compact = commandSelectedText.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 50 { return compact }
        return String(compact.prefix(47)) + "..."
    }

    /// Stable key for animating pill size transitions between states
    var pillStateKey: String {
        switch state {
        case .ready: return "ready"
        case .recording:
            if sessionKind == .command {
                return recordingMode == .holdToTalk ? "commandHoldToTalk" : "commandRecording"
            }
            return recordingMode == .holdToTalk ? "holdToTalk" : "recording"
        case .cancelled: return "cancelled"
        case .processing:
            let messageSuffix = visibleProcessingMessage == nil ? "" : "Message"
            return sessionKind == .command ? "commandProcessing\(messageSuffix)" : "processing\(messageSuffix)"
        case .formatting:
            return sessionKind == .command ? "commandFormatting" : "formatting"
        case .success: return "success"
        case .noSpeech:
            return sessionKind == .command ? "commandNoSpeech" : "noSpeech"
        case .error: return "error"
        }
    }
}
