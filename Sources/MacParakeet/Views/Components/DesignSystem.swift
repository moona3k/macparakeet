import SwiftUI

/// Centralized design tokens for consistent styling across the app.
/// "Warm Magical" design system — coral-orange accent, generous spacing, rounded headlines.
enum DesignSystem {
    // MARK: - Colors

    enum Colors {
        // Accent — warm coral-orange (parakeet plumage)
        static let accent = Color(light: .init(red: 0.91, green: 0.42, blue: 0.23),
                                  dark: .init(red: 1.0, green: 0.54, blue: 0.36))
        static let accentLight = Color(light: .init(red: 1.0, green: 0.94, blue: 0.92),
                                       dark: .init(red: 1.0, green: 0.54, blue: 0.36).opacity(0.12))
        static let accentDark = Color(light: .init(red: 0.77, green: 0.33, blue: 0.16),
                                      dark: .init(red: 0.91, green: 0.42, blue: 0.23))

        // Backgrounds — warm off-whites, not pure white
        static let background = Color(light: .init(red: 0.98, green: 0.98, blue: 0.97),
                                      dark: .init(red: 0.11, green: 0.11, blue: 0.12))
        static let surface = Color(light: .white,
                                   dark: .init(red: 0.17, green: 0.17, blue: 0.18))
        static let surfaceElevated = Color(light: .init(red: 0.96, green: 0.96, blue: 0.94),
                                           dark: .init(red: 0.23, green: 0.23, blue: 0.24))

        // Text — high contrast primaries
        static let textPrimary = Color(light: .init(red: 0.10, green: 0.10, blue: 0.10),
                                       dark: .white)
        static let textSecondary = Color(light: .init(red: 0.42, green: 0.42, blue: 0.42),
                                         dark: .init(red: 0.63, green: 0.63, blue: 0.65))
        static let textTertiary = Color(light: .init(red: 0.61, green: 0.61, blue: 0.61),
                                        dark: .init(red: 0.39, green: 0.39, blue: 0.40))

        // Semantic
        static let successGreen = Color(light: .init(red: 0.20, green: 0.66, blue: 0.33),
                                        dark: .init(red: 0.29, green: 0.87, blue: 0.50))
        static let warningAmber = Color(light: .init(red: 0.96, green: 0.65, blue: 0.14),
                                        dark: .init(red: 0.98, green: 0.75, blue: 0.14))
        static let errorRed = Color(light: .init(red: 0.90, green: 0.30, blue: 0.26),
                                    dark: .init(red: 0.97, green: 0.44, blue: 0.44))
        static let onAccent = Color.white

        // Borders & dividers
        static let border = Color(light: .init(red: 0.91, green: 0.91, blue: 0.88),
                                  dark: .init(red: 0.30, green: 0.30, blue: 0.32))
        static let divider = Color(light: .init(red: 0.94, green: 0.94, blue: 0.91),
                                   dark: .init(red: 0.25, green: 0.25, blue: 0.27))

        // Interactive
        static let rowHoverBackground = Color(light: .init(red: 0.96, green: 0.96, blue: 0.94),
                                              dark: .primary.opacity(0.06))
        static let cardBackground = Color(light: .white,
                                          dark: .init(red: 0.17, green: 0.17, blue: 0.18))

        // Playback
        static let playbackTrack = Color.primary.opacity(0.08)
        static let playbackFill = Color.accentColor

        // Speaker diarization palette — distinct, readable in both light/dark
        static let speakerColors: [Color] = [
            Color(light: .init(red: 0.20, green: 0.51, blue: 0.84),
                  dark: .init(red: 0.42, green: 0.68, blue: 0.96)),   // Blue
            Color(light: .init(red: 0.72, green: 0.33, blue: 0.64),
                  dark: .init(red: 0.85, green: 0.52, blue: 0.78)),   // Purple
            Color(light: .init(red: 0.16, green: 0.60, blue: 0.46),
                  dark: .init(red: 0.30, green: 0.78, blue: 0.62)),   // Teal
            Color(light: .init(red: 0.82, green: 0.52, blue: 0.14),
                  dark: .init(red: 0.95, green: 0.68, blue: 0.30)),   // Amber
            Color(light: .init(red: 0.80, green: 0.28, blue: 0.28),
                  dark: .init(red: 0.95, green: 0.45, blue: 0.45)),   // Red
            Color(light: .init(red: 0.40, green: 0.56, blue: 0.24),
                  dark: .init(red: 0.56, green: 0.76, blue: 0.38)),   // Green
        ]

        static func speakerColor(for index: Int) -> Color {
            speakerColors[index % speakerColors.count]
        }

        // YouTube badge
        static let youtubeRed = Color.red

        // Pill / overlay
        static let pillBackground = Color.black.opacity(0.7)
        static let pillBorder = Color.white.opacity(0.15)
        static let recordingRed = Color.red
        static let sacredGlow = Color(light: .init(red: 0.40, green: 0.85, blue: 0.40),
                                      dark: .init(red: 0.46, green: 0.90, blue: 0.46))
        static let sacredStem = Color(light: .init(red: 0.35, green: 0.65, blue: 0.35),
                                      dark: .init(red: 0.43, green: 0.74, blue: 0.43))
        static let meetingPillBackground = Color(light: .black.opacity(0.88),
                                                 dark: .black.opacity(0.90))
        static let meetingPillBackgroundHover = Color(light: .black.opacity(0.90),
                                                      dark: .init(red: 0.18, green: 0.18, blue: 0.19).opacity(0.95))
        static let meetingPillStroke = Color.white.opacity(0.08)
        static let meetingPillStrokeHover = Color.white.opacity(0.15)
        static let meetingPillText = Color.white.opacity(0.9)
        static let meetingPillBadgeBackground = Color.black.opacity(0.8)

        // Sidebar
        static let contentBackground = Color(nsColor: .textBackgroundColor)
    }

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
        static let hero: CGFloat = 64
    }

    // MARK: - Typography

    enum Typography {
        // Headlines — .rounded design = instantly warmer
        static let heroTitle = Font.system(size: 28, weight: .bold, design: .rounded)
        static let pageTitle = Font.system(size: 22, weight: .semibold, design: .rounded)
        static let sectionTitle = Font.system(size: 17, weight: .semibold)

        // Body — larger minimums
        static let bodyLarge = Font.system(size: 15)
        static let body = Font.system(size: 14)
        static let bodySmall = Font.system(size: 13)

        // Metadata
        static let caption = Font.system(size: 12)
        static let micro = Font.system(size: 11)

        // Monospace
        static let timestamp = Font.system(size: 12).monospacedDigit()
        static let duration = Font.system(size: 11).monospacedDigit()
        static let meetingPillStatus = Font.system(size: 13, weight: .semibold)
        static let meetingPillBadge = Font.system(size: 10, weight: .medium, design: .monospaced)
        static let meetingPillCheckmark = Font.system(size: 24, weight: .semibold)

        /// Soft rounded label used inside the dictation overlay's no-speech terminal
        /// pill (e.g. "More audio pls"). Uses `.rounded` to match the organic curves
        /// of the falling leaf + Merkaba dissolve animation, and the same family as
        /// the app's headline typography (`heroTitle`, `pageTitle`). Sized to sit
        /// naturally beside the 26pt Merkaba glyph inside a low-profile horizontal
        /// oval pill.
        static let dictationOverlayTerminalLabel = Font.system(size: 9.5, weight: .medium, design: .rounded)

        // Legacy aliases (kept for existing references)
        static let headline = Font.system(size: 17, weight: .semibold, design: .rounded)
        static let title = Font.system(size: 22, weight: .semibold, design: .rounded)
        static let largeTitle = Font.system(size: 28, weight: .bold, design: .rounded)
        static let sectionHeader = Font.system(size: 13, weight: .semibold)
    }

    // MARK: - Layout

    enum Layout {
        static let sidebarMinWidth: CGFloat = 200
        static let contentMinWidth: CGFloat = 500
        static let windowMinHeight: CGFloat = 560
        static let cornerRadius: CGFloat = 16
        static let cardCornerRadius: CGFloat = 14
        static let rowCornerRadius: CGFloat = 12
        static let dropZoneCornerRadius: CGFloat = 20
        static let buttonCornerRadius: CGFloat = 12
        static let minTouchTarget: CGFloat = 44
        static let dropZoneHeight: CGFloat = 200
        static let playbackBarHeight: CGFloat = 6
        static let videoPlayerMinWidth: CGFloat = 320
        static let videoPlayerIdealRatio: CGFloat = 0.4
        static let audioScrubberHeight: CGFloat = 44
        static let thumbnailCardMinWidth: CGFloat = 200
        static let thumbnailAspectRatio: CGFloat = 16 / 9
    }

    // MARK: - Animation

    enum Animation {
        static let selectionChange: SwiftUI.Animation = .easeInOut(duration: 0.15)
        static let hoverTransition: SwiftUI.Animation = .easeInOut(duration: 0.12)
        static let contentSwap: SwiftUI.Animation = .easeInOut(duration: 0.2)
        static let portalLift: SwiftUI.Animation = .spring(response: 0.3, dampingFraction: 0.7)
        static let meetingPillHover: SwiftUI.Animation = .easeOut(duration: 0.15)
    }

    // MARK: - Shadows

    enum Shadows {
        static let cardRest = ShadowStyle(color: .black.opacity(0.06), radius: 4, y: 2)
        static let cardHover = ShadowStyle(color: .black.opacity(0.10), radius: 12, y: 6)
        static let portalLift = ShadowStyle(color: .black.opacity(0.12), radius: 16, y: 8)
        static let meetingPill = ShadowStyle(color: .black.opacity(0.28), radius: 12, y: 6)
    }
}

// MARK: - Shadow Style

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let y: CGFloat

    init(color: Color, radius: CGFloat, y: CGFloat) {
        self.color = color
        self.radius = radius
        self.y = y
    }
}

// MARK: - Adaptive Color Helper

extension Color {
    /// Creates a color that adapts to light/dark mode.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(dark) : NSColor(light)
        })
    }
}

// MARK: - Shadow View Modifier

extension View {
    func cardShadow(_ style: ShadowStyle) -> some View {
        self.shadow(color: style.color, radius: style.radius, x: 0, y: style.y)
    }
}
