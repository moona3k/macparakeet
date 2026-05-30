import AppKit
import SwiftUI

/// Sacred geometry flower icon ported from Oatmeal's meeting recording pill.
///
/// This is AppKit/Core Animation backed instead of a pure SwiftUI
/// `repeatForever` animation. Sampling showed continuous SwiftUI animation
/// hosted in always-resident windows does per-frame work on the main thread
/// (re-eval `body` → rebuild the display list → CA commit, every refresh).
/// Driving the same motion through `CALayer` + `CABasicAnimation` interpolates
/// on the render server at ~0 app CPU, so the mark can be *rich* — a live
/// audio-responsive glow plus the full recording lifecycle (collapse →
/// processing spinner → completion checkmark) — without the render churn.
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
    /// Which lifecycle mark is currently shown. The flower-of-life rosette
    /// (recording / paused / collapse), the counter-rotating merkaba spinner
    /// (transcribing), and the draw-on checkmark (completed) live as three
    /// layer groups in one view so transitions read as the *same* mark
    /// transforming in place.
    private enum Face {
        case rosette
        case spinner
        case checkmark
    }

    // MARK: Rosette (recording / paused / collapse)
    private let glowLayer = CAShapeLayer()
    private let flowerLayer = CALayer()
    private let stemLayer = CAShapeLayer()
    private let leftLeafFillLayer = CAShapeLayer()
    private let leftLeafStrokeLayer = CAShapeLayer()
    private let rightLeafFillLayer = CAShapeLayer()
    private let rightLeafStrokeLayer = CAShapeLayer()

    // MARK: Spinner (transcribing) — two counter-rotating triangles + nexus
    private let spinnerLayer = CALayer()
    private let spinnerRingLayer = CAShapeLayer()
    private let spinnerTriCWLayer = CAShapeLayer()
    private let spinnerTriCCWLayer = CAShapeLayer()
    private let spinnerCenterLayer = CAShapeLayer()

    // MARK: Checkmark (completed) — ring draws, then check strokes in
    private let checkLayer = CALayer()
    private let checkRingTrackLayer = CAShapeLayer()
    private let checkRingLayer = CAShapeLayer()
    private let checkMarkLayer = CAShapeLayer()

    private var rosetteLayers: [CALayer] {
        [glowLayer, flowerLayer, stemLayer,
         leftLeafFillLayer, leftLeafStrokeLayer, rightLeafFillLayer, rightLeafStrokeLayer]
    }

    private var didBuildLayers = false
    private var currentShowStem = true
    private var currentAnimating = false
    private var currentAudioLevel: Float = -1
    private var currentFace: Face = .rosette
    private var smoothedGlow: Float = -1

    /// Resting glow before audio lifts it: brighter while actively listening,
    /// dim when paused/idle so the mark reads as "quiet".
    private var glowBase: Float { currentAnimating ? 0.4 : 0.1 }

    private let successGreen = NSColor(red: 0.20, green: 0.66, blue: 0.33, alpha: 1)
    private let completionGold = NSColor(red: 1.0, green: 0.85, blue: 0.4, alpha: 1)

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

    // MARK: - Recording / paused

    func update(isAnimating: Bool, audioLevel: Float) {
        buildLayersIfNeeded()
        setFace(.rosette)

        if currentAnimating != isAnimating {
            currentAnimating = isAnimating
            isAnimating ? startAnimations() : stopAnimations()
        }

        let clampedAudio = min(1, max(0, audioLevel))
        if currentAudioLevel != clampedAudio {
            currentAudioLevel = clampedAudio
            applyGlow(target: glowBase + clampedAudio * 0.5, smoothing: false)
        }
    }

    /// Live audio-responsive glow, driven from a fast (~30 fps) pill-local
    /// channel rather than the 1 s state poll, so the "internal light" tracks
    /// speech in near-real-time like the original SwiftUI pill. Touches only
    /// `glowLayer.opacity` (a compositor-only property on a static path), so it
    /// costs ~nothing — no body re-eval, no relayout, no display-list rebuild.
    /// Lightly smoothed so jittery audio meters read as organic breathing.
    func setLiveGlow(level: Float) {
        buildLayersIfNeeded()
        guard currentFace == .rosette else { return }
        let clamped = min(1, max(0, level))
        currentAudioLevel = clamped
        applyGlow(target: glowBase + clamped * 0.5, smoothing: true)
    }

    private func applyGlow(target: Float, smoothing: Bool) {
        let capped = min(0.9, max(0, target))
        let value: Float
        if smoothing, smoothedGlow >= 0 {
            // Exponential moving average — chases the audio without the
            // jitter of raw meter values or the lag of a long implicit fade.
            value = smoothedGlow + (capped - smoothedGlow) * 0.35
        } else {
            value = capped
        }
        smoothedGlow = value
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.opacity = value
        CATransaction.commit()
    }

    // MARK: - Lifecycle faces

    /// Recording stopped: the Flower of Life accelerates, petals collapse, the
    /// glow warms green → gold, leaves detach and drift, the stem retracts, then
    /// everything fades — handing off to the processing spinner. CA port of
    /// `FlowerCompletionView`. `onFinished` fires when the collapse is done.
    func playCompletion(reduceMotion: Bool, onFinished: @escaping @MainActor () -> Void) {
        buildLayersIfNeeded()
        setFace(.rosette)
        stopAnimations()
        currentAnimating = false

        guard !reduceMotion else {
            // Vestibular-safe: a quiet fade instead of the spinning collapse.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.duration = 0.4
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            for layer in rosetteLayers where !layer.isHidden { layer.add(fade, forKey: "completionFade") }
            scheduleCompletion(after: 0.4, onFinished)
            return
        }

        // Phase 1a (0–0.8s): flower head spins up and collapses inward.
        flowerLayer.add(rampAnimation(keyPath: "transform.rotation.z", from: 0, to: CGFloat.pi * 3, duration: 0.8, timing: .easeIn), forKey: "completionSpin")
        flowerLayer.add(rampAnimation(keyPath: "transform.scale", from: 1.0, to: 0.12, duration: 0.8, timing: .easeIn), forKey: "completionScale")

        // Glow warms green → gold, then exhales out at the end.
        let warm = CABasicAnimation(keyPath: "fillColor")
        warm.fromValue = glowLayer.fillColor
        warm.toValue = completionGold.cgColor
        warm.duration = 0.8
        warm.fillMode = .forwards
        warm.isRemovedOnCompletion = false
        warm.timingFunction = CAMediaTimingFunction(name: .easeIn)
        glowLayer.add(warm, forKey: "completionWarm")

        // Phase 1b (0.1–0.7s): leaves detach and drift down + away.
        addLeafDrift(fill: leftLeafFillLayer, stroke: leftLeafStrokeLayer, dx: -10, dy: 14, rotation: -.pi / 6, delay: 0.1)
        addLeafDrift(fill: rightLeafFillLayer, stroke: rightLeafStrokeLayer, dx: 10, dy: 12, rotation: .pi * 25 / 180, delay: 0.15)

        // Phase 1c (0.3–0.7s): stem retracts.
        let retract = rampAnimation(keyPath: "strokeEnd", from: 1.0, to: 0.0, duration: 0.4, timing: .easeInEaseOut)
        retract.beginTime = CACurrentMediaTime() + 0.3
        stemLayer.add(retract, forKey: "completionRetract")
        let stemFade = rampAnimation(keyPath: "opacity", from: 1.0, to: 0.0, duration: 0.4, timing: .easeInEaseOut)
        stemFade.beginTime = CACurrentMediaTime() + 0.3
        stemLayer.add(stemFade, forKey: "completionStemFade")

        // Phase 1d (0.8–1.0s): flower head + glow fade out.
        let headFade = rampAnimation(keyPath: "opacity", from: 1.0, to: 0.0, duration: 0.2, timing: .easeOut)
        headFade.beginTime = CACurrentMediaTime() + 0.8
        flowerLayer.add(headFade, forKey: "completionHeadFade")
        let glowFade = rampAnimation(keyPath: "opacity", from: CGFloat(glowLayer.opacity), to: 0.0, duration: 0.2, timing: .easeOut)
        glowFade.beginTime = CACurrentMediaTime() + 0.8
        glowLayer.add(glowFade, forKey: "completionGlowFade")

        scheduleCompletion(after: 1.0, onFinished)
    }

    /// Fire the collapse-finished callback after `delay`, on the main actor.
    /// (A `Task` instead of `DispatchQueue.asyncAfter(execute:)` so the
    /// `@MainActor` callback isn't forced through a `@Sendable` parameter —
    /// Swift 6 language-mode clean.)
    private func scheduleCompletion(after delay: Double, _ onFinished: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            onFinished()
        }
    }

    /// Processing state: two counter-rotating triangles (the merkaba) with a
    /// pulsing nexus. CA port of `SpinnerRingView`.
    func showSpinner(animated: Bool) {
        buildLayersIfNeeded()
        setFace(.spinner)
        stopAnimations()

        guard animated else { return } // static merkaba (Star of David) for reduce-motion

        if spinnerTriCWLayer.animation(forKey: "spin") == nil {
            spinnerTriCWLayer.add(spinAnimation(to: CGFloat.pi * 2, duration: 3), forKey: "spin")
            spinnerTriCCWLayer.add(spinAnimation(to: -CGFloat.pi * 2, duration: 3), forKey: "spin")
            spinnerCenterLayer.add(pulseAnimation(from: 0.3, to: 0.9, duration: 1.4), forKey: "pulse")
        }
    }

    /// Completed state: a success ring draws on, then the checkmark strokes in.
    /// CA port of `MeetingCompletionCheckmarkView` (Apple-Pay style).
    func showCheckmark(animated: Bool) {
        buildLayersIfNeeded()
        setFace(.checkmark)
        stopAnimations()

        guard animated else {
            checkRingLayer.strokeEnd = 1
            checkMarkLayer.strokeEnd = 1
            return
        }

        let ring = rampAnimation(keyPath: "strokeEnd", from: 0, to: 1, duration: 0.35, timing: .easeOut)
        ring.fillMode = .forwards
        ring.isRemovedOnCompletion = false
        checkRingLayer.add(ring, forKey: "ringDraw")

        let check = rampAnimation(keyPath: "strokeEnd", from: 0, to: 1, duration: 0.25, timing: .easeOut)
        check.beginTime = CACurrentMediaTime() + 0.25
        check.fillMode = .forwards
        check.isRemovedOnCompletion = false
        checkMarkLayer.add(check, forKey: "checkDraw")
    }

    private func setFace(_ face: Face) {
        guard currentFace != face else { return }
        currentFace = face
        if face != .checkmark {
            checkRingLayer.strokeEnd = 0
            checkMarkLayer.strokeEnd = 0
        }
        applyVisibility()
    }

    /// Single source of truth for layer visibility, driven by the current face
    /// and `showStem`. Re-applied on every layout so a `configure(showStem:)`
    /// change (which keeps the face) still hides/shows the stem + leaves.
    private func applyVisibility() {
        let rosette = (currentFace == .rosette)
        glowLayer.isHidden = !rosette
        flowerLayer.isHidden = !rosette
        for layer in [stemLayer, leftLeafFillLayer, leftLeafStrokeLayer, rightLeafFillLayer, rightLeafStrokeLayer] {
            layer.isHidden = !rosette || !currentShowStem
        }
        spinnerLayer.isHidden = (currentFace != .spinner)
        checkLayer.isHidden = (currentFace != .checkmark)
    }

    // MARK: - Layer construction

    private func buildLayersIfNeeded() {
        guard !didBuildLayers, let rootLayer = layer else { return }
        didBuildLayers = true

        rootLayer.masksToBounds = false
        rootLayer.addSublayer(glowLayer)

        flowerLayer.masksToBounds = false
        rootLayer.addSublayer(flowerLayer)
        addFlowerCircles()

        for leafLayer in [leftLeafFillLayer, rightLeafFillLayer] {
            leafLayer.strokeColor = nil
        }
        for leafLayer in [leftLeafStrokeLayer, rightLeafStrokeLayer] {
            leafLayer.fillColor = NSColor.clear.cgColor
            leafLayer.lineWidth = 0.5
        }

        stemLayer.fillColor = NSColor.clear.cgColor
        stemLayer.lineWidth = 1.2
        stemLayer.lineCap = .round

        rootLayer.addSublayer(stemLayer)
        rootLayer.addSublayer(leftLeafFillLayer)
        rootLayer.addSublayer(leftLeafStrokeLayer)
        rootLayer.addSublayer(rightLeafFillLayer)
        rootLayer.addSublayer(rightLeafStrokeLayer)

        buildSpinnerLayers(in: rootLayer)
        buildCheckmarkLayers(in: rootLayer)

        applyRosetteColors()
    }

    /// Brand greens for the glow + stem/leaves, matching the shipped SwiftUI
    /// pill and the Transcribe-tab tile (`DesignSystem.Colors.sacredGlow` /
    /// `.sacredStem`) rather than the generic `systemGreen` the first CA port
    /// landed on. Resolved against the view's current appearance and re-applied
    /// from `viewDidChangeEffectiveAppearance`, since `CGColor` snapshots a
    /// dynamic `Color` at assignment time (so a Light↔Dark switch mid-recording
    /// would otherwise leave the rosette tinted for the old appearance).
    private func applyRosetteColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            glowLayer.fillColor = NSColor(DesignSystem.Colors.sacredGlow)
                .withAlphaComponent(0.35).cgColor
            let stem = NSColor(DesignSystem.Colors.sacredStem)
            for leafLayer in [leftLeafFillLayer, rightLeafFillLayer] {
                leafLayer.fillColor = stem.withAlphaComponent(0.45).cgColor
            }
            for leafLayer in [leftLeafStrokeLayer, rightLeafStrokeLayer] {
                leafLayer.strokeColor = stem.withAlphaComponent(0.55).cgColor
            }
            stemLayer.strokeColor = stem.withAlphaComponent(0.7).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard didBuildLayers else { return }
        applyRosetteColors()
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
                    x: 15 + cos(angle) * 6.5,
                    y: 15 + sin(angle) * 6.5
                )
            }
            flowerLayer.addSublayer(circle)
        }
    }

    private func buildSpinnerLayers(in root: CALayer) {
        spinnerLayer.isHidden = true
        for tri in [spinnerTriCWLayer, spinnerTriCCWLayer] {
            tri.fillColor = NSColor.clear.cgColor
            tri.strokeColor = NSColor.white.withAlphaComponent(0.45).cgColor
            tri.lineWidth = 0.8
            tri.lineJoin = .round
        }
        spinnerTriCCWLayer.strokeColor = NSColor.white.withAlphaComponent(0.3).cgColor
        spinnerRingLayer.fillColor = NSColor.clear.cgColor
        spinnerRingLayer.strokeColor = NSColor.white.withAlphaComponent(0.06).cgColor
        spinnerRingLayer.lineWidth = 0.5
        spinnerCenterLayer.fillColor = NSColor.white.withAlphaComponent(0.7).cgColor
        spinnerLayer.addSublayer(spinnerRingLayer)
        spinnerLayer.addSublayer(spinnerTriCWLayer)
        spinnerLayer.addSublayer(spinnerTriCCWLayer)
        spinnerLayer.addSublayer(spinnerCenterLayer)
        root.addSublayer(spinnerLayer)
    }

    private func buildCheckmarkLayers(in root: CALayer) {
        checkLayer.isHidden = true
        checkRingTrackLayer.fillColor = NSColor.clear.cgColor
        checkRingTrackLayer.strokeColor = successGreen.withAlphaComponent(0.2).cgColor
        checkRingTrackLayer.lineWidth = 1.5
        checkRingLayer.fillColor = NSColor.clear.cgColor
        checkRingLayer.strokeColor = successGreen.cgColor
        checkRingLayer.lineWidth = 1.5
        checkRingLayer.lineCap = .round
        checkRingLayer.strokeEnd = 0
        checkMarkLayer.fillColor = NSColor.clear.cgColor
        checkMarkLayer.strokeColor = successGreen.cgColor
        checkMarkLayer.lineWidth = 1.5
        checkMarkLayer.lineCap = .round
        checkMarkLayer.lineJoin = .round
        checkMarkLayer.strokeEnd = 0
        checkLayer.addSublayer(checkRingTrackLayer)
        checkLayer.addSublayer(checkRingLayer)
        checkLayer.addSublayer(checkMarkLayer)
        root.addSublayer(checkLayer)
    }

    // MARK: - Layout

    private func layoutLayers() {
        let headY: CGFloat = currentShowStem ? 6 : 0
        glowLayer.path = CGPath(ellipseIn: CGRect(x: 3, y: headY + 3, width: 24, height: 24), transform: nil)

        flowerLayer.frame = CGRect(x: 0, y: headY, width: 30, height: 30)
        flowerLayer.position = CGPoint(x: 15, y: headY + 15)
        flowerLayer.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)

        let stemFrame = CGRect(x: 0, y: headY + 30, width: 30, height: 34)
        for layer in [stemLayer, leftLeafFillLayer, leftLeafStrokeLayer, rightLeafFillLayer, rightLeafStrokeLayer] {
            layer.frame = stemFrame
        }

        stemLayer.path = stemPath(in: stemFrame.size)
        let leftPath = leafPath(in: stemFrame.size, basePoint: CGPoint(x: 0.5, y: 0.38), direction: -1, size: 8)
        let rightPath = leafPath(in: stemFrame.size, basePoint: CGPoint(x: 0.5, y: 0.62), direction: 1, size: 9)
        leftLeafFillLayer.path = leftPath
        leftLeafStrokeLayer.path = leftPath
        rightLeafFillLayer.path = rightPath
        rightLeafStrokeLayer.path = rightPath

        layoutSpinnerAndCheck(headY: headY)
        applyVisibility()
    }

    private func layoutSpinnerAndCheck(headY: CGFloat) {
        // Both containers sit exactly where the flower head is, so the
        // transcribing/completed marks read as the rosette transforming in
        // place. Sublayer coordinates below are relative to the 30×30 container
        // bounds, not the y-offset head rect.
        let headRect = CGRect(x: 0, y: headY, width: 30, height: 30)
        spinnerLayer.frame = headRect
        checkLayer.frame = headRect

        let local = CGRect(x: 0, y: 0, width: 30, height: 30)
        let center = CGPoint(x: 15, y: 15)
        let radius: CGFloat = 11

        spinnerRingLayer.frame = local
        spinnerRingLayer.path = CGPath(ellipseIn: CGRect(x: center.x - 13, y: center.y - 13, width: 26, height: 26), transform: nil)
        // bounds + centered position so transform.rotation.z spins about the
        // centroid (an unsized layer would orbit its origin instead).
        // The second triangle's path is offset 60° so the pair forms a Star of
        // David at rest (the reduce-motion / settled face); when animated they
        // counter-rotate from there into the spinning merkaba.
        spinnerTriCWLayer.bounds = local
        spinnerTriCWLayer.position = center
        spinnerTriCWLayer.path = trianglePath(center: center, radius: radius, rotation: 0)
        spinnerTriCCWLayer.bounds = local
        spinnerTriCCWLayer.position = center
        spinnerTriCCWLayer.path = trianglePath(center: center, radius: radius, rotation: .pi / 3)
        spinnerCenterLayer.frame = CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)
        spinnerCenterLayer.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 3, height: 3), transform: nil)

        // Checkmark ring + tick, inset to match the old 26pt frame with padding.
        for layer in [checkRingTrackLayer, checkRingLayer, checkMarkLayer] { layer.frame = local }
        checkRingTrackLayer.path = CGPath(ellipseIn: CGRect(x: 2, y: 2, width: 26, height: 26), transform: nil)
        // Sweep the ring from the top like the SwiftUI rotationEffect(-90°).
        let ringPath = CGMutablePath()
        ringPath.addArc(center: center, radius: 13, startAngle: -.pi / 2, endAngle: -.pi / 2 + .pi * 2, clockwise: false)
        checkRingLayer.path = ringPath
        checkMarkLayer.path = checkmarkPath(in: local.size)
    }

    // MARK: - Paths

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

    private func trianglePath(center: CGPoint, radius: CGFloat, rotation: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for i in 0..<3 {
            let angle = (CGFloat(i) * 120 - 90) * .pi / 180 + rotation
            let point = CGPoint(x: center.x + Foundation.cos(angle) * radius,
                                y: center.y + Foundation.sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private func checkmarkPath(in size: CGSize) -> CGPath {
        // Mirror of CheckmarkShape, inset 7pt like the SwiftUI padding(7).
        let inset: CGFloat = 7
        let w = size.width - inset * 2
        let h = size.height - inset * 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: inset + w * 0.22, y: inset + h * 0.52))
        path.addLine(to: CGPoint(x: inset + w * 0.42, y: inset + h * 0.72))
        path.addLine(to: CGPoint(x: inset + w * 0.78, y: inset + h * 0.28))
        return path
    }

    // MARK: - Recording rosette animations

    private func startAnimations() {
        guard flowerLayer.animation(forKey: "recordingRotation") == nil else { return }
        // Clear any held collapse transforms from a prior cycle (defensive;
        // views are normally fresh per session).
        flowerLayer.removeAnimation(forKey: "completionSpin")
        flowerLayer.removeAnimation(forKey: "completionScale")

        let rotation = spinAnimation(to: CGFloat.pi * 2, duration: 12)
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
        spinnerTriCWLayer.removeAnimation(forKey: "spin")
        spinnerTriCCWLayer.removeAnimation(forKey: "spin")
        spinnerCenterLayer.removeAnimation(forKey: "pulse")
    }

    // MARK: - Animation builders

    private func spinAnimation(to value: CGFloat, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = value
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        return animation
    }

    private func pulseAnimation(from: Float, to: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

    private func rampAnimation(keyPath: String, from: CGFloat, to: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunctionName) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        return animation
    }

    private func addLeafDrift(fill: CAShapeLayer, stroke: CAShapeLayer, dx: CGFloat, dy: CGFloat, rotation: CGFloat, delay: CFTimeInterval) {
        for layer in [fill, stroke] {
            let group = CAAnimationGroup()
            let move = CABasicAnimation(keyPath: "transform.translation")
            move.fromValue = NSValue(point: .zero)
            move.toValue = NSValue(point: NSPoint(x: dx, y: dy))
            let rotate = CABasicAnimation(keyPath: "transform.rotation.z")
            rotate.fromValue = 0
            rotate.toValue = rotation
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            group.animations = [move, rotate, fade]
            group.duration = 0.6
            group.beginTime = CACurrentMediaTime() + delay
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(group, forKey: "completionDrift")
        }
    }
}
