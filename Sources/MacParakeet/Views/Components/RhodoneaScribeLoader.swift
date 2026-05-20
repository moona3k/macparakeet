import SwiftUI

/// Sacred-geometry rose-curve loader used for compact "work is in flight"
/// states. It has no intrinsic size; callers keep ownership of the icon box
/// with an outer `.frame(width:height:)`.
struct RhodoneaScribeLoader: View {
    var tint: Color
    var paused: Bool = false
    var period: Double = 3.0
    var accessibilityLabel: String = "Working"

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: paused)) { context in
            Canvas { ctx, size in
                let now = context.date.timeIntervalSinceReferenceDate
                let t = (now.truncatingRemainder(dividingBy: period)) / period
                Self.draw(in: ctx, size: size, t: t, tint: tint)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    private static func draw(in ctx: GraphicsContext, size: CGSize, t: Double, tint: Color) {
        var basePath = Path()
        let baseSamples = 240
        for i in 0...baseSamples {
            let phase = Double(i) / Double(baseSamples)
            let p = point(phase: phase, size: size)
            if i == 0 {
                basePath.move(to: p)
            } else {
                basePath.addLine(to: p)
            }
        }
        ctx.stroke(
            basePath,
            with: .color(tint.opacity(0.18)),
            style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
        )

        let segments = 42
        let trailArc = 0.30
        let baseLineWidth: CGFloat = 1.7

        for i in 0..<segments {
            let frac = Double(i) / Double(segments - 1)
            let nextFrac = Double(i + 1) / Double(segments - 1)
            let phaseA = t - frac * trailArc
            let phaseB = t - nextFrac * trailArc

            let pA = point(phase: phaseA, size: size)
            let pB = point(phase: phaseB, size: size)

            var seg = Path()
            seg.move(to: pA)
            seg.addLine(to: pB)

            let alpha = pow(1.0 - frac, 1.6)
            let width = baseLineWidth * (1.0 - frac * 0.35)

            ctx.stroke(
                seg,
                with: .color(tint.opacity(alpha)),
                style: StrokeStyle(lineWidth: width, lineCap: .round)
            )
        }

        let head = point(phase: t, size: size)
        let dotR: CGFloat = 1.7
        let dotRect = CGRect(x: head.x - dotR, y: head.y - dotR, width: dotR * 2, height: dotR * 2)
        ctx.fill(Path(ellipseIn: dotRect), with: .color(tint))
    }

    private static func point(phase: Double, size: CGSize) -> CGPoint {
        let theta = phase * 2 * .pi
        let cx = size.width / 2
        let cy = size.height / 2
        let radius = min(size.width, size.height) * 0.44
        let s = sin(2.5 * theta)
        let r = radius * s * s
        let x = cx + r * cos(theta)
        let y = cy + r * sin(theta)
        return CGPoint(x: x, y: y)
    }
}
