import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Manages a lightweight floating panel for video URL input (Spotlight-style).
/// Unlike DictationOverlayController which uses `.nonactivatingPanel`,
/// this panel needs keyboard focus for the text field, so it uses
/// `canBecomeKey = true` with `canBecomeMain = false`.
///
/// Lifecycle: AppDelegate owns this controller for the app's lifetime via `lazy var`.
/// Cleanup happens in `hide()` — no `deinit` needed (and `deinit` is nonisolated
/// in Swift 6 `@MainActor` classes, so AppKit calls there would be unsafe).
@MainActor
final class YouTubeInputPanelController {
    private var panel: NSPanel?
    private var resignObserver: NSObjectProtocol?

    private let transcriptionViewModel: TranscriptionViewModel

    init(transcriptionViewModel: TranscriptionViewModel) {
        self.transcriptionViewModel = transcriptionViewModel
    }

    func show() {
        if panel != nil { return }

        // Auto-paste: if clipboard has a valid YouTube or X URL, use it as initial value
        var initialURL = ""
        if let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           YouTubeURLValidator.isYouTubeURL(clip) || XURLValidator.isXURL(clip) {
            initialURL = clip
        }

        let view = YouTubeInputPanelView(
            viewModel: transcriptionViewModel,
            initialURL: initialURL,
            onTranscribe: { [weak self] url in
                guard let self else { return }
                // Push the panel's local draft into the VM right before transcribing
                self.transcriptionViewModel.urlInput = url
                self.transcriptionViewModel.transcribeURL()
                self.hide()
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )

        let hosting = NSHostingView(rootView: view)
        // Extra padding around the 460pt SwiftUI card for shadow clearance
        let panelWidth: CGFloat = 540
        let panelHeight: CGFloat = 280
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI handles shadow
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        // Center horizontally, upper third vertically (Spotlight-style).
        // Fall back to the first screen when there is no main screen (a rare
        // transition state) so the panel never lands at the bottom-left origin.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.origin.y + screenFrame.height * 0.65 - panelHeight / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel

        // This panel is summoned by a global hotkey, typically while another
        // app is frontmost. The cooperative `NSApp.activate()` is routinely
        // declined for a background app responding to a CGEvent tap, so the
        // panel gets ordered into our own window list but is never raised above
        // the active app — it only appears once the user manually focuses
        // MacParakeet. Force activation so the panel reliably comes forward,
        // matching the file-transcription flow in `MenuBarCoordinator`.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        installResignObserver()
    }

    func hide() {
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Private

    /// Dismiss when the panel loses key status — covers click-outside (any app),
    /// Cmd+Tab, Mission Control, and all other focus-loss scenarios.
    private func installResignObserver() {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }
}

// MARK: - Panel Subclass

/// NSPanel that accepts keyboard focus (for text field) but won't become main window.
/// Overrides `cancelOperation` to dismiss on Escape — more reliable than SwiftUI's
/// `.onKeyPress(.escape)` when the AppKit field editor is first responder.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
