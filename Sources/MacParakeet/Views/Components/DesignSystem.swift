import SwiftUI

/// Centralized design tokens for consistent styling across the app.
enum DesignSystem {
    // MARK: - Colors

    enum Colors {
        static let pillBackground = Color.black.opacity(0.9)
        static let pillBorder = Color.white.opacity(0.1)
        static let recordingRed = Color.red
        static let successGreen = Color.green
        static let warningYellow = Color.yellow
        static let warningOrange = Color.orange
        static let statusGranted = Color.green
        static let statusDenied = Color.red
        static let accentTeal = Color(nsColor: NSColor(red: 0.0, green: 0.8, blue: 0.75, alpha: 1.0))

        static let sidebarBackground = Color(nsColor: .controlBackgroundColor)
        static let contentBackground = Color(nsColor: .textBackgroundColor)
    }

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 40
    }

    // MARK: - Typography

    enum Typography {
        static let caption = Font.caption
        static let body = Font.body
        static let headline = Font.headline
        static let title = Font.title2
        static let largeTitle = Font.largeTitle
    }

    // MARK: - Layout

    enum Layout {
        static let sidebarMinWidth: CGFloat = 180
        static let contentMinWidth: CGFloat = 400
        static let windowMinHeight: CGFloat = 500
        static let cornerRadius: CGFloat = 12
        static let dropZoneHeight: CGFloat = 200
    }
}
