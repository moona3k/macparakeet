import AppKit
import SwiftUI

/// Manages the floating dictation overlay panel.
/// Non-activating NSPanel that never steals focus from the active app.
final class DictationOverlayController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<DictationOverlayView>?

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

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        // Position at bottom-center, 40px above screen edge
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.origin.y + 40
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
    enum OverlayState {
        case recording
        case cancelled(timeRemaining: Double)
        case processing
        case success
        case error(String)
    }

    var state: OverlayState = .recording
    var audioLevel: Float = 0.0
    var recordingElapsedSeconds: Int = 0

    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?
    var onUndo: (() -> Void)?
    var onDismiss: (() -> Void)?

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

    var formattedElapsed: String {
        let minutes = recordingElapsedSeconds / 60
        let seconds = recordingElapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
