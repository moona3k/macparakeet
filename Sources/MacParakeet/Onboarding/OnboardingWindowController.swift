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
        diarizationService: DiarizationServiceProtocol? = nil,
        onFinish: @escaping () -> Void,
        onHotkeyPreviewArm: @escaping () -> Void = {},
        onHotkeyPreviewDisarm: @escaping () -> Void = {},
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
            diarizationService: diarizationService
        )
        viewModel = vm
        // Retained so the rehearsal taps/overlay are torn down if the window
        // closes while the user is on the hotkey step (SwiftUI `onDisappear`
        // can lag window teardown). `disarm()` is idempotent.
        onHotkeyPreviewDisarmHandler = onHotkeyPreviewDisarm

        let view = OnboardingFlowView(
            viewModel: vm,
            onFinish: { [weak self] in
                self?.allowCloseWithoutCompletion = true
                self?.close()
                onFinish()
            },
            onOpenMainApp: onOpenMainApp,
            onOpenSettings: onOpenSettings,
            onHotkeyPreviewArm: onHotkeyPreviewArm,
            onHotkeyPreviewDisarm: onHotkeyPreviewDisarm
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
            alert.informativeText = "MacParakeet needs permissions and speech model setup (Parakeet) before core features are reliable."
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
    private var onHotkeyPreviewDisarmHandler: (() -> Void)?

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
        onHotkeyPreviewDisarmHandler?()
        onHotkeyPreviewDisarmHandler = nil
        viewModel?.stopObservingWarmUp()
        viewModel = nil
        // Defer teardown to the next run-loop tick so we don't destroy the
        // SwiftUI hosting view (and its window animations) while the button
        // callback that triggered close() is still on the call stack.
        let w = window
        window = nil
        DispatchQueue.main.async {
            w?.contentView = nil
        }
    }
}
