import SwiftUI

/// A deterministic before/after glyph for a saved Transform run.
///
/// Dictation rows use `SonicMandalaView` as a voice fingerprint. Transform
/// rows need a sibling visual, not the same metaphor: the faint stroke comes
/// from the selected input text, and the stronger stroke comes from the
/// rewritten result. The same saved run always produces the same sigil.
struct TransformSigilView: View {
    let data: TransformSigilData
    var size: CGFloat = 32

    var body: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let maxRadius = min(canvasSize.width, canvasSize.height) / 2 - 2

            guard data.inputPoints.count >= 4, data.outputPoints.count >= 4 else { return }

            let inputPath = buildSmoothPath(
                points: data.inputPoints,
                center: center,
                maxRadius: maxRadius * 0.88,
                phase: -.pi / 2
            )
            let outputPath = buildSmoothPath(
                points: data.outputPoints,
                center: center,
                maxRadius: maxRadius,
                phase: -.pi / 2 + .pi / 24
            )

            context.stroke(
                inputPath,
                with: .color(DesignSystem.Colors.accent.opacity(0.18)),
                lineWidth: size > 48 ? 1.2 : 0.8
            )
            context.stroke(
                outputPath,
                with: .color(DesignSystem.Colors.accent.opacity(0.45)),
                lineWidth: size > 48 ? 1.6 : 1.1
            )

            let dotSize: CGFloat = size > 48 ? 4 : 2.4
            let dotRect = CGRect(
                x: center.x - dotSize / 2,
                y: center.y - dotSize / 2,
                width: dotSize,
                height: dotSize
            )
            context.fill(
                Path(ellipseIn: dotRect),
                with: .color(DesignSystem.Colors.accent.opacity(0.32))
            )
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Transform before and after pattern")
    }

    private func buildSmoothPath(
        points: [CGFloat],
        center: CGPoint,
        maxRadius: CGFloat,
        phase: CGFloat
    ) -> Path {
        let count = points.count
        let minRadius = maxRadius * 0.34
        let radiusRange = maxRadius - minRadius

        var cartesian: [CGPoint] = []
        cartesian.reserveCapacity(count)

        for index in 0..<count {
            let angle = (CGFloat(index) / CGFloat(count)) * 2 * .pi + phase
            let radius = minRadius + points[index] * radiusRange
            cartesian.append(
                CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )
            )
        }

        var path = Path()
        path.move(
            to: catmullRomPoint(
                p0: cartesian[(count - 1) % count],
                p1: cartesian[0],
                p2: cartesian[1],
                p3: cartesian[2],
                t: 0
            )
        )

        for index in 0..<count {
            let p0 = cartesian[(index - 1 + count) % count]
            let p1 = cartesian[index]
            let p2 = cartesian[(index + 1) % count]
            let p3 = cartesian[(index + 2) % count]

            for step in 1...6 {
                let t = CGFloat(step) / 6
                path.addLine(to: catmullRomPoint(p0: p0, p1: p1, p2: p2, p3: p3, t: t))
            }
        }

        path.closeSubpath()
        return path
    }

    private func catmullRomPoint(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, t: CGFloat) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t

        let x = 0.5 * (
            (2 * p1.x)
                + (-p0.x + p2.x) * t
                + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3
        )
        let y = 0.5 * (
            (2 * p1.y)
                + (-p0.y + p2.y) * t
                + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
                + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
        )

        return CGPoint(x: x, y: y)
    }
}

struct TransformSigilData: Equatable {
    let inputPoints: [CGFloat]
    let outputPoints: [CGFloat]

    static func from(inputText: String, outputText: String, transformName: String) -> TransformSigilData {
        TransformSigilData(
            inputPoints: radialPoints(
                from: inputText,
                fallback: transformName,
                salt: 0x8f7c_3a29_41d5_b6e3,
                mirrorStrength: 0.48
            ),
            outputPoints: radialPoints(
                from: outputText,
                fallback: "\(transformName)\n\(inputText)",
                salt: 0xc2b2_ae35_87f6_4d1b,
                mirrorStrength: 0.68
            )
        )
    }

    private static func radialPoints(
        from text: String,
        fallback: String,
        salt: UInt64,
        mirrorStrength: CGFloat
    ) -> [CGFloat] {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : text
        let bytes = Array(source.utf8)
        let sampleCount = 24
        var seed = stableSeed(source, salt: salt)
        var points: [CGFloat] = []
        points.reserveCapacity(sampleCount)

        for index in 0..<sampleCount {
            let byte = bytes.isEmpty ? UInt8((index * 37) & 0xff) : bytes[index % bytes.count]
            seed = seed &* 6364136223846793005 &+ UInt64(byte) &+ UInt64(index * 1447)
            let random = CGFloat((seed >> 33) & 0xffff) / CGFloat(0xffff)
            let harmonic = CGFloat(
                0.5 + 0.5 * sin((Double(index) / Double(sampleCount)) * 2 * .pi * 3 + Double(seed & 0xff) / 255)
            )
            points.append(0.18 + random * 0.64 + harmonic * 0.18)
        }

        for index in 0..<(sampleCount / 2) {
            let mirrorIndex = sampleCount - 1 - index
            points[mirrorIndex] = points[index] * mirrorStrength + points[mirrorIndex] * (1 - mirrorStrength)
        }

        return points
    }

    private static func stableSeed(_ text: String, salt: UInt64) -> UInt64 {
        var hash = 1469598103934665603 ^ salt
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return hash
    }
}
