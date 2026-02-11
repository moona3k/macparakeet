import AppKit

/// Generates the MacParakeet "Breath Wave" logo programmatically.
///
/// Design: A sinuous S-wave with two yin-yang dots — one above, one below.
/// Represents the duality of dictation (voice in) and transcription (text out),
/// inspired by Daoist balance and the flow of breath.
///
/// The icon is drawn via Core Graphics so it scales perfectly at any size
/// and works as a template image (adapts to light/dark mode automatically).
enum BreathWaveIcon {

    // MARK: - Canonical Geometry (128×128 viewBox)

    // S-wave path: M 16,64 C 16,20 64,20 64,64 C 64,108 112,108 112,64
    // Dot 1 (below-left): center (40, 72), radius 7
    // Dot 2 (above-right): center (88, 56), radius 7
    // Stroke width: 7 (large), 9 (small/menu bar)

    /// Create the Breath Wave logo as a **template** NSImage for menu bar use.
    /// Template images are drawn in black; macOS applies the system tint automatically.
    static func menuBarIcon(pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            let s = pointSize / 128.0

            // Use thicker stroke + larger dots for legibility at small sizes
            let strokeWidth = max(10 * s, 1.5)
            let dotRadius = max(8 * s, 1.5)

            NSColor.black.setStroke()
            NSColor.black.setFill()

            // S-curve wave
            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: 16 * s, y: 64 * s))
            wave.curve(
                to: NSPoint(x: 64 * s, y: 64 * s),
                controlPoint1: NSPoint(x: 16 * s, y: 20 * s),
                controlPoint2: NSPoint(x: 64 * s, y: 20 * s)
            )
            wave.curve(
                to: NSPoint(x: 112 * s, y: 64 * s),
                controlPoint1: NSPoint(x: 64 * s, y: 108 * s),
                controlPoint2: NSPoint(x: 112 * s, y: 108 * s)
            )
            wave.lineWidth = strokeWidth
            wave.lineCapStyle = .round
            wave.stroke()

            // Dot 1 — below the left curve
            let d1 = NSRect(
                x: 40 * s - dotRadius, y: 72 * s - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            )
            NSBezierPath(ovalIn: d1).fill()

            // Dot 2 — above the right curve
            let d2 = NSRect(
                x: 88 * s - dotRadius, y: 56 * s - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            )
            NSBezierPath(ovalIn: d2).fill()

            return true
        }
        image.isTemplate = true
        return image
    }

    /// Create the Breath Wave logo as a filled NSImage for app icon / dock use.
    /// Uses white on a colored background.
    static func appIcon(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let s = size / 128.0
            let cornerRadius = 22 * s  // macOS icon corner radius proportion

            // Background — deep teal-blue gradient
            let bg = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            let gradient = NSGradient(
                starting: NSColor(red: 0.12, green: 0.20, blue: 0.32, alpha: 1.0),
                ending: NSColor(red: 0.08, green: 0.14, blue: 0.24, alpha: 1.0)
            )
            gradient?.draw(in: bg, angle: -90)

            // White logo, centered with padding
            let padding: CGFloat = 20 * s
            let logoSize = size - padding * 2
            let ls = logoSize / 128.0

            NSColor.white.setStroke()
            NSColor.white.setFill()

            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: padding + 16 * ls, y: padding + 64 * ls))
            wave.curve(
                to: NSPoint(x: padding + 64 * ls, y: padding + 64 * ls),
                controlPoint1: NSPoint(x: padding + 16 * ls, y: padding + 20 * ls),
                controlPoint2: NSPoint(x: padding + 64 * ls, y: padding + 20 * ls)
            )
            wave.curve(
                to: NSPoint(x: padding + 112 * ls, y: padding + 64 * ls),
                controlPoint1: NSPoint(x: padding + 64 * ls, y: padding + 108 * ls),
                controlPoint2: NSPoint(x: padding + 112 * ls, y: padding + 108 * ls)
            )
            wave.lineWidth = 7 * ls
            wave.lineCapStyle = .round
            wave.stroke()

            let dotRadius = 7 * ls
            let d1 = NSRect(
                x: padding + 40 * ls - dotRadius, y: padding + 72 * ls - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            )
            NSBezierPath(ovalIn: d1).fill()

            let d2 = NSRect(
                x: padding + 88 * ls - dotRadius, y: padding + 56 * ls - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            )
            NSBezierPath(ovalIn: d2).fill()

            return true
        }
        return image
    }
}
