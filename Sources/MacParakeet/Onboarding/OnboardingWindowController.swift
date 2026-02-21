import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var viewModel: OnboardingViewModel?
    private var allowCloseWithoutCompletion = false
    var isVisible: Bool {
        window?.isVisible == true
    }

    func show(
        permissionService: PermissionServiceProtocol,
        sttClient: STTClientProtocol,
        llmService: any LLMServiceProtocol,
        onFinish: @escaping () -> Void,
        onOpenMainApp: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onIncompleteDismiss: @escaping () -> Void
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vm = OnboardingViewModel(
            permissionService: permissionService,
            sttClient: sttClient,
            llmService: llmService
        )
        viewModel = vm
        let view = OnboardingFlowView(
            viewModel: vm,
            onFinish: { [weak self] in
                self?.allowCloseWithoutCompletion = true
                self?.close()
                onFinish()
            },
            onOpenMainApp: onOpenMainApp,
            onOpenSettings: onOpenSettings
        )

        let hosting = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 500),
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

        func confirmDismissOnboarding() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Setup is not finished"
            alert.informativeText = "MacParakeet needs permissions and local model setup (Parakeet + Qwen) before core features are reliable."
            alert.addButton(withTitle: "Continue Setup")
            alert.addButton(withTitle: "Exit Setup")

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                onIncompleteDismiss()
                allowCloseWithoutCompletion = true
                close()
            }
        }

        self.onIncompleteDismiss = confirmDismissOnboarding
    }

    func close() {
        window?.close()
    }

    private var onIncompleteDismiss: (() -> Void)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowCloseWithoutCompletion {
            return true
        }

        if viewModel?.hasCompletedOnboarding == true {
            return true
        }

        onIncompleteDismiss?()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        allowCloseWithoutCompletion = false
        onIncompleteDismiss = nil
        viewModel = nil
        window = nil
    }
}
