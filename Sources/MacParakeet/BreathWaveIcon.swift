import AppKit

/// Generates the MacParakeet "Cursive P" logo programmatically.
///
/// Design: An enclosed circular bowl with a dot inside, and a cursive loop tail
/// that descends, loops under, and trails off left. The loop echoes the bowl's
/// circular rhythm — two circles in harmony.
///
/// Inspired by Daoist simplicity: a single stroke forming a P with a bird's-eye
/// dot at center. The cursive tail gives it handwritten warmth.
///
/// The icon is drawn via Core Graphics so it scales perfectly at any size
/// and works as a template image (adapts to light/dark mode automatically).
enum BreathWaveIcon {

    // MARK: - Canonical Geometry (128×128 viewBox)

    // Bowl: circle cx=68, cy=34, r=26
    // Dot: cx=68, cy=34, r=6
    // Stem + cursive loop tail:
    //   M 42,34 L 42,82 C 42,100 30,110 18,112 C 6,114 2,106 8,98 C 14,90 30,88 42,92
    // Stroke width: 7 (large), 10 (small/menu bar)

    /// Load the parakeet silhouette as a **template** NSImage for menu bar use.
    /// The image is stored as a processed SwiftPM resource (menubar-icon.png / @2x).
    /// Template images adapt to light/dark mode automatically.
    static func menuBarIcon(pointSize: CGFloat = 18) -> NSImage {
        // Try loading from SwiftPM resource bundle first, then fall back to main bundle.
        if let url = Bundle.module.url(forResource: "menubar-icon@2x", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: pointSize, height: pointSize)
            image.isTemplate = true
            return image
        }

        // Fallback: 1x version
        if let url = Bundle.module.url(forResource: "menubar-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: pointSize, height: pointSize)
            image.isTemplate = true
            return image
        }

        // Last resort: return a system symbol
        let fallback = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MacParakeet")
            ?? NSImage()
        fallback.size = NSSize(width: pointSize, height: pointSize)
        fallback.isTemplate = true
        return fallback
    }

    /// Create the Cursive P logo as a filled NSImage for app icon / dock use.
    /// Uses white on a colored background.
    static func appIcon(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let s = size / 128.0
            let cornerRadius = 22 * s

            // Background — deep teal-blue gradient
            let bg = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            let gradient = NSGradient(
                starting: NSColor(red: 0.12, green: 0.20, blue: 0.32, alpha: 1.0),
                ending: NSColor(red: 0.08, green: 0.14, blue: 0.24, alpha: 1.0)
            )
            gradient?.draw(in: bg, angle: -90)

            // White logo, centered with padding
            let padding: CGFloat = 20 * s
            let ls = (size - padding * 2) / 128.0

            NSColor.white.setStroke()
            NSColor.white.setFill()

            let bowlRadius = 26 * ls

            // Enclosed circular bowl
            let bowl = NSBezierPath(
                ovalIn: NSRect(
                    x: padding + 68 * ls - bowlRadius, y: padding + 34 * ls - bowlRadius,
                    width: bowlRadius * 2, height: bowlRadius * 2
                )
            )
            bowl.lineWidth = 7 * ls
            bowl.stroke()

            // Stem + cursive loop tail
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: padding + 42 * ls, y: padding + 34 * ls))
            tail.line(to: NSPoint(x: padding + 42 * ls, y: padding + 82 * ls))
            tail.curve(
                to: NSPoint(x: padding + 18 * ls, y: padding + 112 * ls),
                controlPoint1: NSPoint(x: padding + 42 * ls, y: padding + 100 * ls),
                controlPoint2: NSPoint(x: padding + 30 * ls, y: padding + 110 * ls)
            )
            tail.curve(
                to: NSPoint(x: padding + 8 * ls, y: padding + 98 * ls),
                controlPoint1: NSPoint(x: padding + 6 * ls, y: padding + 114 * ls),
                controlPoint2: NSPoint(x: padding + 2 * ls, y: padding + 106 * ls)
            )
            tail.curve(
                to: NSPoint(x: padding + 42 * ls, y: padding + 92 * ls),
                controlPoint1: NSPoint(x: padding + 14 * ls, y: padding + 90 * ls),
                controlPoint2: NSPoint(x: padding + 30 * ls, y: padding + 88 * ls)
            )
            tail.lineWidth = 7 * ls
            tail.lineCapStyle = .round
            tail.stroke()

            // Dot
            let dotRadius = 6 * ls
            NSBezierPath(ovalIn: NSRect(
                x: padding + 68 * ls - dotRadius, y: padding + 34 * ls - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            )).fill()

            return true
        }
        return image
    }
}
