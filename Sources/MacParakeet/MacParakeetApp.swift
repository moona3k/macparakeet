import AppKit
import MacParakeetCore

/// MacParakeet - Local-first voice app for macOS
///
/// Hybrid menu bar app: menu bar always visible, dock icon appears when main window is open.
/// Uses manual NSApplication.run() for reliable CLI execution (no .app bundle required).
@main
struct MacParakeetApp {
    static func main() {
        let app = NSApplication.shared

        // Enforce the documented minimum OS version (macOS 14.2+).
        // SPM manifests can't express patch-level deployment targets for macOS 14,
        // so we guard at runtime instead.
        guard #available(macOS 14.2, *) else {
            app.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "macOS 14.2+ Required"
            alert.informativeText = "MacParakeet requires macOS 14.2 (Sonoma) or later."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            return
        }

        let delegate = AppDelegate()
        app.delegate = delegate

        // Start without dock icon (menu bar only)
        // Dock icon will appear dynamically when main window opens (see AppDelegate)
        app.setActivationPolicy(.accessory)

        app.run()
    }
}
