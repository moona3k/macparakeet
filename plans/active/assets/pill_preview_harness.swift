import AppKit

// Offscreen preview of the floating meeting-recording pill, including the
// hover-revealed elapsed-time badge. Reuses the real MerkabaPillIconView.

let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

final class PillPreview: NSView {
    let iconView = MerkabaPillIconView()
    let backgroundLayer = CAShapeLayer()
    let pauseLayer = CALayer()
    let timeBadgeLayer = CAShapeLayer()
    let timeDotLayer = CAShapeLayer()
    let timeTextLayer = CATextLayer()
    let pillWidth: CGFloat
    let pillHeight: CGFloat
    let paused: Bool
    let hovered: Bool
    let timeText: String

    init(pillWidth: CGFloat, pillHeight: CGFloat, paused: Bool = false, hovered: Bool = false, timeText: String = "12:34") {
        self.pillWidth = pillWidth
        self.pillHeight = pillHeight
        self.paused = paused
        self.hovered = hovered
        self.timeText = timeText
        super.init(frame: NSRect(x: 0, y: 0, width: 118, height: 150))
        wantsLayer = true
        layer?.masksToBounds = false
        backgroundLayer.fillColor = NSColor.black.withAlphaComponent(hovered ? 0.90 : 0.88).cgColor
        backgroundLayer.strokeColor = NSColor.white.withAlphaComponent(hovered ? 0.15 : 0.08).cgColor
        backgroundLayer.lineWidth = 0.5
        layer?.addSublayer(backgroundLayer)
        iconView.configure(showStem: true)
        iconView.update(isAnimating: !paused, audioLevel: paused ? 0 : 0.5)
        iconView.alphaValue = paused ? 0.45 : 1.0
        addSubview(iconView)

        for x in [CGFloat(0), CGFloat(7)] {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            bar.cornerRadius = 1.5
            bar.frame = CGRect(x: x, y: 0, width: 3, height: 11)
            pauseLayer.addSublayer(bar)
        }
        pauseLayer.isHidden = !paused
        layer?.addSublayer(pauseLayer)

        // Time badge
        timeBadgeLayer.fillColor = NSColor.black.withAlphaComponent(0.72).cgColor
        timeBadgeLayer.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        timeBadgeLayer.lineWidth = 0.5
        timeBadgeLayer.shadowColor = NSColor.black.cgColor
        timeBadgeLayer.shadowOpacity = 0.25
        timeBadgeLayer.shadowRadius = 6
        timeBadgeLayer.shadowOffset = CGSize(width: 0, height: -2)
        timeBadgeLayer.opacity = hovered ? 1 : 0
        timeDotLayer.fillColor = (paused ? NSColor.systemOrange : NSColor.systemRed).cgColor
        timeTextLayer.font = badgeFont
        timeTextLayer.fontSize = badgeFont.pointSize
        timeTextLayer.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        timeTextLayer.alignmentMode = .left
        timeTextLayer.contentsScale = 2
        timeTextLayer.isWrapped = false
        timeTextLayer.string = timeText
        timeBadgeLayer.addSublayer(timeDotLayer)
        timeBadgeLayer.addSublayer(timeTextLayer)
        layer?.addSublayer(timeBadgeLayer)
        needsLayout = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let pillRect = CGRect(
            x: bounds.maxX - 74,
            y: bounds.midY - pillHeight / 2,
            width: pillWidth,
            height: pillHeight
        )
        backgroundLayer.path = CGPath(roundedRect: pillRect, cornerWidth: pillWidth / 2, cornerHeight: pillWidth / 2, transform: nil)
        iconView.frame = CGRect(x: pillRect.midX - 15, y: pillRect.midY - 37, width: 30, height: 74)
        pauseLayer.frame = CGRect(x: pillRect.midX - 5, y: pillRect.midY - 5.5, width: 10, height: 11)
        iconView.layoutSubtreeIfNeeded()

        // Badge layout (mirror of layoutTimeBadge in the real view)
        let textSize = (timeText as NSString).size(withAttributes: [.font: badgeFont])
        let dot: CGFloat = 5, gap: CGFloat = 5, hPad: CGFloat = 10, vPad: CGFloat = 5
        let badgeH = ceil(textSize.height) + vPad * 2
        let badgeW = dot + gap + ceil(textSize.width) + hPad * 2
        let capsuleMidX = bounds.maxX - 74 + 27
        let capsuleTop = bounds.midY - 43
        timeBadgeLayer.frame = CGRect(x: capsuleMidX - badgeW / 2, y: capsuleTop - badgeH - 4, width: badgeW, height: badgeH)
        timeBadgeLayer.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: badgeW, height: badgeH), cornerWidth: badgeH / 2, cornerHeight: badgeH / 2, transform: nil)
        let centerY = badgeH / 2
        timeDotLayer.frame = CGRect(x: hPad, y: centerY - dot / 2, width: dot, height: dot)
        timeDotLayer.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: dot, height: dot), transform: nil)
        timeTextLayer.frame = CGRect(x: hPad + dot + gap, y: centerY - ceil(textSize.height) / 2, width: ceil(textSize.width) + 1, height: ceil(textSize.height))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let cropX: CGFloat = 24
let cropW: CGFloat = 92
let panelH: CGFloat = 150
let labelH: CGFloat = 26

struct Panel { let label: String; let w: CGFloat; let h: CGFloat; let paused: Bool; let hovered: Bool }
let panels: [Panel] = [
    Panel(label: "0:17", w: 54, h: 86, paused: false, hovered: true),
    Panel(label: "12:34", w: 54, h: 86, paused: false, hovered: true),
    Panel(label: "114:44 (#200)", w: 54, h: 86, paused: false, hovered: true),
    Panel(label: "999:59", w: 54, h: 86, paused: false, hovered: true),
]

let cols = CGFloat(panels.count)
let canvas = NSImage(size: NSSize(width: cropW * cols, height: panelH + labelH))
canvas.lockFocus()
NSColor(white: 0.40, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: cropW * cols, height: panelH + labelH).fill()

for (i, p) in panels.enumerated() {
    let v = PillPreview(pillWidth: p.w, pillHeight: p.h, paused: p.paused, hovered: p.hovered,
                        timeText: p.label.components(separatedBy: " ").first ?? "12:34")
    v.layoutSubtreeIfNeeded()
    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        let dst = NSRect(x: CGFloat(i) * cropW, y: labelH, width: cropW, height: panelH)
        let src = NSRect(x: cropX, y: 0, width: cropW, height: panelH)
        rep.draw(in: dst, from: src, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
    }
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11, weight: .medium)]
    (p.label as NSString).draw(at: NSPoint(x: CGFloat(i) * cropW + 6, y: 6), withAttributes: attrs)
}
canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
try! png.write(to: URL(fileURLWithPath: "/tmp/pill_longtimes.png"))
print("wrote /tmp/pill_longtimes.png")
