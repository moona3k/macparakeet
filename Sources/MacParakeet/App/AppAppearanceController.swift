import AppKit
import MacParakeetCore

@MainActor
enum AppAppearanceController {
    static func apply(_ mode: AppAppearanceMode) {
        apply(mode, to: NSApplication.shared)
    }

    static func apply(_ mode: AppAppearanceMode, to application: NSApplication) {
        application.appearance = nsAppearance(for: mode)
    }

    private static func nsAppearance(for mode: AppAppearanceMode) -> NSAppearance? {
        switch mode {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}
