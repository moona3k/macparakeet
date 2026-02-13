import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(
        permissionService: PermissionServiceProtocol,
        sttClient: STTClientProtocol,
        onFinish: @escaping () -> Void,
        onOpenMainApp: @escaping () -> Void
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vm = OnboardingViewModel(permissionService: permissionService, sttClient: sttClient)
        let view = OnboardingFlowView(
            viewModel: vm,
            onFinish: { [weak self] in
                self?.close()
                onFinish()
            },
            onOpenMainApp: onOpenMainApp
        )

        let hosting = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 480),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered,
                         defer: false)
        w.title = "Welcome to MacParakeet"
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = hosting
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.delegate = self

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // User clicked the close button.
        window = nil
    }
}
