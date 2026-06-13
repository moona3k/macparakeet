import SwiftUI
import MacParakeetCore

/// Circular waveform visualization derived from audio data — each recording's unique visual fingerprint.
/// Generates a radial pattern from word-level confidence scores (or text hash for dictations without timestamps).
struct SonicMandalaView: View {
    let data: MandalaData
    var size: CGFloat = 32
    var style: MandalaStyle = .monochrome

    enum MandalaStyle {
        case monochrome   // Lists: single stroke, accent at 0.3 opacity
        case fullColor    // Detail: filled, gradient, optional glow
    }

    var body: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let maxRadius = min(canvasSize.width, canvasSize.height) / 2 - 2

            let points = data.radialPoints
            guard points.count >= 4 else { return }

            let path = buildSmoothPath(points: points, center: center, maxRadius: maxRadius)

            switch style {
            case .monochrome:
                context.stroke(
                    path,
                    with: .color(DesignSystem.Colors.accent.opacity(0.35)),
                    lineWidth: size > 48 ? 1.5 : 1.0
                )

            case .fullColor:
                // Gradient fill
                let gradient = Gradient(colors: [
                    DesignSystem.Colors.accent,
                    Color(red: 0.95, green: 0.75, blue: 0.30) // gold
                ])
                context.fill(
                    path,
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: canvasSize.width, y: canvasSize.height)
                    )
                )

                // Soft outer stroke
                context.stroke(
                    path,
                    with: .color(DesignSystem.Colors.accent.opacity(0.4)),
                    lineWidth: 1.0
                )
            }

            // Center dot
            let dotSize: CGFloat = size > 48 ? 4 : 2
            let dotRect = CGRect(x: center.x - dotSize / 2, y: center.y - dotSize / 2,
                                 width: dotSize, height: dotSize)
            context.fill(
                Path(ellipseIn: dotRect),
                with: .color(DesignSystem.Colors.accent.opacity(style == .fullColor ? 0.6 : 0.25))
            )
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Voice waveform pattern")
    }

    // MARK: - Path Building

    /// Builds a smooth closed radial path using Catmull-Rom interpolation.
    private func buildSmoothPath(points: [CGFloat], center: CGPoint, maxRadius: CGFloat) -> Path {
        let n = points.count
        let minRadius = maxRadius * 0.3
        let radiusRange = maxRadius - minRadius

        // Convert radial values to Cartesian points
        var cartesian: [CGPoint] = []
        for i in 0..<n {
            let angle = (Double(i) / Double(n)) * 2 * .pi - .pi / 2
            let r = minRadius + points[i] * radiusRange
            let x = center.x + cos(angle) * r
            let y = center.y + sin(angle) * r
            cartesian.append(CGPoint(x: x, y: y))
        }

        var path = Path()
        path.move(to: catmullRomPoint(p0: cartesian[(n - 1) % n], p1: cartesian[0],
                                       p2: cartesian[1], p3: cartesian[2], t: 0))

        for i in 0..<n {
            let p0 = cartesian[(i - 1 + n) % n]
            let p1 = cartesian[i]
            let p2 = cartesian[(i + 1) % n]
            let p3 = cartesian[(i + 2) % n]

            // 6 interpolation steps per segment for smoothness
            let steps = 6
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = catmullRomPoint(p0: p0, p1: p1, p2: p2, p3: p3, t: t)
                path.addLine(to: point)
            }
        }

        path.closeSubpath()
        return path
    }

    /// Catmull-Rom spline interpolation between p1 and p2.
    private func catmullRomPoint(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, t: CGFloat) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t

        let x = 0.5 * ((2 * p1.x) +
                        (-p0.x + p2.x) * t +
                        (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
                        (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)

        let y = 0.5 * ((2 * p1.y) +
                        (-p0.y + p2.y) * t +
                        (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
                        (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)

        return CGPoint(x: x, y: y)
    }
}

// MARK: - Mandala Data

/// Encapsulates the radial data points that define a mandala's shape.
struct MandalaData {
    /// Normalized radial values (0...1) — one per "petal" around the circle.
    let radialPoints: [CGFloat]

    /// Creates mandala data from word-level timestamps (transcriptions).
    static func from(wordTimestamps: [WordTimestamp]) -> MandalaData {
        guard !wordTimestamps.isEmpty else { return .fallback }

        let sampleCount = 24
        let confidences = wordTimestamps.map { CGFloat($0.confidence) }

        // Resample to fixed point count
        var points: [CGFloat] = []
        let step = max(1.0, Double(confidences.count) / Double(sampleCount))

        for i in 0..<sampleCount {
            let idx = Int(Double(i) * step)
            let safeIdx = min(idx, confidences.count - 1)
            points.append(confidences[safeIdx])
        }

        // Mirror for symmetry — makes it look intentional and organic
        let half = sampleCount / 2
        for i in 0..<half {
            let mirrorIdx = sampleCount - 1 - i
            if mirrorIdx < points.count && i < points.count {
                points[mirrorIdx] = points[i] * 0.8 + points[mirrorIdx] * 0.2
            }
        }

        return MandalaData(radialPoints: points)
    }

    /// Creates mandala data from text hash (dictations without word timestamps).
    static func from(text: String, durationMs: Int) -> MandalaData {
        guard !text.isEmpty else { return .fallback }

        let sampleCount = 24
        var points: [CGFloat] = []

        // Use a deterministic hash of the text characters to generate the pattern
        var hashState: UInt64 = UInt64(durationMs) ^ 0x517cc1b727220a95
        let chars = Array(text.utf8)

        for i in 0..<sampleCount {
            let charIdx = i < chars.count ? Int(chars[i]) : (i * 37)
            hashState = hashState &* 6364136223846793005 &+ UInt64(charIdx)
            let value = CGFloat((hashState >> 33) & 0xFFFF) / CGFloat(0xFFFF)
            // Clamp to 0.2...1.0 range for visual appeal (avoid too-small petals)
            points.append(0.2 + value * 0.8)
        }

        // Partial mirror for organic symmetry
        let half = sampleCount / 2
        for i in 0..<half {
            let mirrorIdx = sampleCount - 1 - i
            points[mirrorIdx] = points[i] * 0.7 + points[mirrorIdx] * 0.3
        }

        return MandalaData(radialPoints: points)
    }

    /// Simple concentric circle fallback for items without any audio data.
    static let fallback = MandalaData(
        radialPoints: (0..<24).map { i in
            let angle = Double(i) / 24.0 * .pi * 2
            return CGFloat(0.5 + 0.15 * sin(angle * 3))
        }
    )
}
