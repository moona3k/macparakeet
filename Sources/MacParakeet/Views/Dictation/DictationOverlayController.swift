import AppKit
import MacParakeetCore
import SwiftUI

// MARK: - Mouse Tracking

/// NSView overlay that detects mouse hover and position via NSTrackingArea with `.activeAlways`.
/// Required because `.help()`, `.onHover`, and standard tracking options
/// all fail on non-activating NSPanel. See CLAUDE.md Known Pitfalls.
private final class MouseTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onMoved: ((NSPoint) -> Void)?

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

    // Pass all clicks through to SwiftUI content below
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Clickable Non-Activating Panel

/// NSPanel subclass that allows SwiftUI buttons to receive clicks while
/// remaining non-activating (won't steal focus on `orderFront`).
/// Without `canBecomeKey = true`, buttons inside a `.nonactivatingPanel`
/// are unresponsive because the panel never becomes key window.
private final class ClickablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Overlay Controller

/// Manages the floating dictation overlay panel.
/// Non-activating NSPanel that never steals focus from the active app.
final class DictationOverlayController {
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
        let hosting = NSHostingView(rootView: view)

        // Start with generous size — SwiftUI content sizes itself, panel background is clear
        let panelWidth: CGFloat = 300
        let panelHeight: CGFloat = 160
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = ClickablePanel(
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
        tracker.onMoved = { [weak self] point in
            self?.updateHoverTooltip(at: point, in: hosting.bounds)
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

    /// Resign key window so CGEvent paste targets the user's app, not the overlay panel.
    /// Call this before any simulated Cmd+V when the overlay was clicked (e.g. Undo, Stop button).
    func resignKeyWindow() {
        panel?.resignKey()
    }

    /// Determine which element the cursor is over and update the tooltip.
    /// The pill is centered in the panel. Left zone = cancel, right zone = stop.
    private func updateHoverTooltip(at point: NSPoint, in bounds: NSRect) {
        guard case .recording = overlayViewModel.state,
              overlayViewModel.recordingMode == .persistent else {
            // No hover tooltips in hold-to-talk, ready, cancelled, processing, success, noSpeech, or error states
            overlayViewModel.hoverTooltip = nil
            return
        }

        let panelWidth = bounds.width
        let pillWidth: CGFloat = 210 // approximate pill content width
        let pillLeft = (panelWidth - pillWidth) / 2
        let pillRight = pillLeft + pillWidth

        let x = point.x
        if x >= pillLeft && x < pillLeft + 45 {
            overlayViewModel.hoverTooltip = "Cancel (Esc)"
        } else if x > pillRight - 45 && x <= pillRight {
            if overlayViewModel.sessionKind == .command {
                overlayViewModel.hoverTooltip = "Stop & apply (Fn+Control)"
            } else {
                overlayViewModel.hoverTooltip = "Stop & paste (\(HotkeyTrigger.current.displayName))"
            }
        } else {
            overlayViewModel.hoverTooltip = nil
        }
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
        case success
        case noSpeech
        case error(String)
    }

    var state: OverlayState = .recording
    var sessionKind: SessionKind = .dictation
    var recordingMode: FnKeyStateMachine.RecordingMode = .persistent
    var audioLevel: Float = 0.0
    var recordingElapsedSeconds: Int = 0
    var isHovered: Bool = false
    var hoverTooltip: String?
    var commandPromptText: String = "Speak your command..."
    var commandSelectedText: String = ""

    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?
    var onUndo: (() -> Void)?
    var onDismiss: (() -> Void)?

    /// Cancel countdown value (separate from state enum to avoid view reconstruction jank).
    var cancelTimeRemaining: Double = 5.0

    /// No-speech progress bar: starts at 1.0, animates to 0.0 over 3 seconds.
    var noSpeechProgress: CGFloat = 1.0

    private var timerTask: Task<Void, Never>?

    func startTimer() {
        recordingElapsedSeconds = 0
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                self?.recordingElapsedSeconds += 1
            }
        }
    }

    func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Resume timer without resetting elapsed time (used after undo cancel)
    func resumeTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                self?.recordingElapsedSeconds += 1
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
            if sessionKind == .command { return "commandRecording" }
            return recordingMode == .holdToTalk ? "holdToTalk" : "recording"
        case .cancelled: return "cancelled"
        case .processing:
            return sessionKind == .command ? "commandProcessing" : "processing"
        case .success: return "success"
        case .noSpeech:
            return sessionKind == .command ? "commandNoSpeech" : "noSpeech"
        case .error: return "error"
        }
    }
}
