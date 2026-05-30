import AppKit
import SwiftUI

/// Sacred geometry flower icon ported from Oatmeal's meeting recording pill.
///
/// This is AppKit/Core Animation backed instead of a pure SwiftUI
/// `repeatForever` animation. Sampling showed the floating recording pill could
/// add 40-55% CPU while recording because SwiftUI re-rendered the display list
/// at animation cadence. Keeping the animation on CALayers preserves the moving
/// pill without making the tiny floating panel drive the whole SwiftUI renderer.
struct MerkabaPillIcon: NSViewRepresentable {
    var isAnimating: Bool = false
    var audioLevel: Float = 0
    /// When `false`, render only the Flower-of-Life head (no stem/leaves) -
    /// used where the rosette is a compact standalone mark, e.g. inside the
    /// calendar countdown halo. Defaults to `true` so the recording pill keeps
    /// the full flower.
    var showStem: Bool = true

    func makeNSView(context: Context) -> MerkabaPillIconView {
        let view = MerkabaPillIconView()
        view.configure(showStem: showStem)
        view.update(isAnimating: isAnimating, audioLevel: audioLevel)
        return view
    }

    func updateNSView(_ nsView: MerkabaPillIconView, context: Context) {
        nsView.configure(showStem: showStem)
        nsView.update(isAnimating: isAnimating, audioLevel: audioLevel)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MerkabaPillIconView, context: Context) -> CGSize? {
        CGSize(width: 30, height: showStem ? 74 : 30)
    }
}

final class MerkabaPillIconView: NSView {
    private let glowLayer = CAShapeLayer()
    private let flowerLayer = CALayer()
    private let stemLayer = CAShapeLayer()
    private let leftLeafFillLayer = CAShapeLayer()
    private let leftLeafStrokeLayer = CAShapeLayer()
    private let rightLeafFillLayer = CAShapeLayer()
    private let rightLeafStrokeLayer = CAShapeLayer()

    private var didBuildLayers = false
    private var currentShowStem = true
    private var currentAnimating = false
    private var currentAudioLevel: Float = -1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 30, height: currentShowStem ? 74 : 30)
    }

    override func layout() {
        super.layout()
        buildLayersIfNeeded()
        layoutLayers()
    }

    func configure(showStem: Bool) {
        guard currentShowStem != showStem else { return }
        currentShowStem = showStem
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func update(isAnimating: Bool, audioLevel: Float) {
        buildLayersIfNeeded()

        if currentAnimating != isAnimating {
            currentAnimating = isAnimating
            isAnimating ? startAnimations() : stopAnimations()
        }

        let clampedAudio = min(1, max(0, audioLevel))
        if currentAudioLevel != clampedAudio {
            currentAudioLevel = clampedAudio
            let base: Float = isAnimating ? 0.4 : 0.1
            let opacity = min(0.9, base + clampedAudio * 0.5)
            glowLayer.opacity = opacity
        }
    }

    private func buildLayersIfNeeded() {
        guard !didBuildLayers, let rootLayer = layer else { return }
        didBuildLayers = true

        rootLayer.masksToBounds = false
        glowLayer.fillColor = NSColor(named: "SacredGlow")?.cgColor ?? NSColor.systemGreen.withAlphaComponent(0.35).cgColor
        rootLayer.addSublayer(glowLayer)

        flowerLayer.masksToBounds = false
        rootLayer.addSublayer(flowerLayer)
        addFlowerCircles()

        for leafLayer in [leftLeafFillLayer, rightLeafFillLayer] {
            leafLayer.fillColor = NSColor.systemGreen.withAlphaComponent(0.45).cgColor
            leafLayer.strokeColor = nil
        }
        for leafLayer in [leftLeafStrokeLayer, rightLeafStrokeLayer] {
            leafLayer.fillColor = NSColor.clear.cgColor
            leafLayer.strokeColor = NSColor.systemGreen.withAlphaComponent(0.55).cgColor
            leafLayer.lineWidth = 0.5
        }

        stemLayer.fillColor = NSColor.clear.cgColor
        stemLayer.strokeColor = NSColor.systemGreen.withAlphaComponent(0.7).cgColor
        stemLayer.lineWidth = 1.2
        stemLayer.lineCap = .round

        rootLayer.addSublayer(stemLayer)
        rootLayer.addSublayer(leftLeafFillLayer)
        rootLayer.addSublayer(leftLeafStrokeLayer)
        rootLayer.addSublayer(rightLeafFillLayer)
        rootLayer.addSublayer(rightLeafStrokeLayer)
    }

    private func addFlowerCircles() {
        let strokeColors: [(CGFloat, CGFloat)] = [(0.55, 0.75)] + Array(repeating: (0.40, 0.75), count: 6)
        for (index, stroke) in strokeColors.enumerated() {
            let circle = CAShapeLayer()
            circle.fillColor = NSColor.clear.cgColor
            circle.strokeColor = NSColor.white.withAlphaComponent(stroke.0).cgColor
            circle.lineWidth = stroke.1
            circle.path = CGPath(ellipseIn: CGRect(x: -6.5, y: -6.5, width: 13, height: 13), transform: nil)

            if index == 0 {
                circle.position = CGPoint(x: 15, y: 15)
            } else {
                let angle = CGFloat(index - 1) * 60 * .pi / 180
                circle.position = CGPoint(
                    x: 15 + Foundation.cos(angle) * 6.5,
                    y: 15 + Foundation.sin(angle) * 6.5
                )
            }
            flowerLayer.addSublayer(circle)
        }
    }

    private func layoutLayers() {
        let headY: CGFloat = currentShowStem ? 6 : 0
        glowLayer.path = CGPath(ellipseIn: CGRect(x: 3, y: headY + 3, width: 24, height: 24), transform: nil)

        flowerLayer.frame = CGRect(x: 0, y: headY, width: 30, height: 30)
        flowerLayer.position = CGPoint(x: 15, y: headY + 15)
        flowerLayer.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)

        let stemFrame = CGRect(x: 0, y: headY + 30, width: 30, height: 34)
        for layer in [stemLayer, leftLeafFillLayer, leftLeafStrokeLayer, rightLeafFillLayer, rightLeafStrokeLayer] {
            layer.isHidden = !currentShowStem
            layer.frame = stemFrame
        }

        stemLayer.path = stemPath(in: stemFrame.size)
        let leftPath = leafPath(in: stemFrame.size, basePoint: CGPoint(x: 0.5, y: 0.38), direction: -1, size: 8)
        let rightPath = leafPath(in: stemFrame.size, basePoint: CGPoint(x: 0.5, y: 0.62), direction: 1, size: 9)
        leftLeafFillLayer.path = leftPath
        leftLeafStrokeLayer.path = leftPath
        rightLeafFillLayer.path = rightPath
        rightLeafStrokeLayer.path = rightPath
    }

    private func stemPath(in size: CGSize) -> CGPath {
        let path = CGMutablePath()
        let midX = size.width / 2
        path.move(to: CGPoint(x: midX, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: midX, y: size.height),
            control: CGPoint(x: midX, y: size.height * 0.5)
        )
        return path
    }

    private func leafPath(in rectSize: CGSize, basePoint: CGPoint, direction: CGFloat, size: CGFloat) -> CGPath {
        let base = CGPoint(x: rectSize.width * basePoint.x, y: rectSize.height * basePoint.y)
        let path = CGMutablePath()
        path.move(to: base)
        path.addQuadCurve(
            to: CGPoint(x: base.x + direction * size, y: base.y - 3),
            control: CGPoint(x: base.x + direction * size * 0.6, y: base.y - 5)
        )
        path.addQuadCurve(
            to: base,
            control: CGPoint(x: base.x + direction * size * 0.6, y: base.y + 2)
        )
        return path
    }

    private func startAnimations() {
        guard flowerLayer.animation(forKey: "recordingRotation") == nil else { return }

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 12
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        flowerLayer.add(rotation, forKey: "recordingRotation")

        for layer in [stemLayer, leftLeafFillLayer, leftLeafStrokeLayer, rightLeafFillLayer, rightLeafStrokeLayer] {
            let sway = CABasicAnimation(keyPath: "transform.translation.x")
            sway.fromValue = -1.5
            sway.toValue = 1.5
            sway.duration = 3
            sway.autoreverses = true
            sway.repeatCount = .infinity
            sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(sway, forKey: "recordingSway")
        }
    }

    private func stopAnimations() {
        flowerLayer.removeAnimation(forKey: "recordingRotation")
        for layer in [stemLayer, leftLeafFillLayer, leftLeafStrokeLayer, rightLeafFillLayer, rightLeafStrokeLayer] {
            layer.removeAnimation(forKey: "recordingSway")
        }
    }
}
