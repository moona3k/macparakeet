import SwiftUI

// MARK: - Triangle Shape

/// Equilateral triangle inscribed in a circle.
struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for i in 0..<3 {
            let angle = (Double(i) * 120.0 - 90.0) * .pi / 180.0
            let point = CGPoint(
                x: center.x + Foundation.cos(angle) * radius,
                y: center.y + Foundation.sin(angle) * radius
            )
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Spinner Ring (Compact Merkaba)

/// Merkaba-inspired spinner — two counter-rotating triangles with glowing vertices
/// and a pulsing center. Used in dictation overlay processing state (26x26).
///
/// Uses `.shadow()` instead of `.blur()` for vertex/center glow — shadow is
/// CA-cacheable and avoids per-frame Gaussian rasterization inside rotating layers.
struct SpinnerRingView: View {
    var size: CGFloat = 26
    var revolutionDuration: Double = 3.0
    var tintColor: Color = .white

    @State private var rotationCW: Double = 0
    @State private var rotationCCW: Double = 0
    @State private var centerPulse: Double = 0.3
    @State private var vertexPulse: Double = 0.6

    private var radius: CGFloat { size * 0.423 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tintColor.opacity(0.05), lineWidth: 0.5)
                .frame(width: size, height: size)

            triangleLayer(rotation: rotationCW, opacity: 0.7, vertexOpacity: vertexPulse)
            triangleLayer(rotation: rotationCCW, opacity: 0.4, vertexOpacity: vertexPulse * 0.7)

            // Center nexus — shadow for glow instead of blur
            Circle()
                .fill(tintColor.opacity(centerPulse))
                .frame(width: size * 0.115, height: size * 0.115)
                .shadow(color: tintColor.opacity(centerPulse * 0.5), radius: size * 0.154)
        }
        .frame(width: size, height: size)
        .drawingGroup()
        .onAppear {
            withAnimation(.linear(duration: revolutionDuration).repeatForever(autoreverses: false)) {
                rotationCW = 360
            }
            withAnimation(.linear(duration: revolutionDuration).repeatForever(autoreverses: false)) {
                rotationCCW = -360
            }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                centerPulse = 0.9
            }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                vertexPulse = 1.0
            }
        }
    }

    private func triangleLayer(rotation: Double, opacity: Double, vertexOpacity: Double) -> some View {
        ZStack {
            TriangleShape()
                .stroke(tintColor.opacity(opacity * 0.5), lineWidth: 0.8)
                .frame(width: radius * 2, height: radius * 2)

            ForEach(0..<3, id: \.self) { i in
                vertexDot(index: i, vertexOpacity: vertexOpacity)
            }
        }
        .rotationEffect(.degrees(rotation))
    }

    private func vertexDot(index: Int, vertexOpacity: Double) -> some View {
        let angle = (Double(index) * 120.0 - 90.0) * .pi / 180.0
        let x = Foundation.cos(angle) * radius
        let y = Foundation.sin(angle) * radius

        return Circle()
            .fill(tintColor.opacity(vertexOpacity))
            .frame(width: size * 0.096, height: size * 0.096)
            .shadow(color: tintColor.opacity(vertexOpacity * 0.4), radius: size * 0.115)
            .offset(x: x, y: y)
    }
}

// MARK: - Meditative Merkaba (Large, Slow)

/// Larger, slower merkaba for empty states and idle backgrounds.
/// Softer opacity, adapts to light/dark mode via `.primary`.
///
/// Pass `animate: false` (the default) for decorative/static use — no CPU cost.
/// Pass `animate: true` only for active loading states (e.g. during drag, streaming).
struct MeditativeMerkabaView: View {
    var size: CGFloat = 64
    var revolutionDuration: Double = 6.0
    var tintColor: Color? = nil
    var animate: Bool = false

    @State private var rotationCW: Double = 0
    @State private var rotationCCW: Double = 0
    @State private var centerPulse: Double = 0.15
    @State private var vertexPulse: Double = 0.3

    private var effectiveColor: Color { tintColor ?? .primary }
    private var radius: CGFloat { size * 0.4 }

    var body: some View {
        ZStack {
            // Outer guide ring
            Circle()
                .stroke(effectiveColor.opacity(0.06), lineWidth: 0.5)
                .frame(width: size, height: size)

            // Triangle 1 — clockwise
            meditativeTriangle(rotation: rotationCW, strokeOpacity: 0.25, vertexOpacity: vertexPulse)

            // Triangle 2 — counter-clockwise
            meditativeTriangle(rotation: rotationCCW, strokeOpacity: 0.15, vertexOpacity: vertexPulse * 0.6)

            // Center nexus — shadow for glow instead of blur
            Circle()
                .fill(effectiveColor.opacity(centerPulse * 1.5))
                .frame(width: size * 0.06, height: size * 0.06)
                .shadow(color: effectiveColor.opacity(centerPulse * 0.4), radius: size * 0.12)
        }
        .frame(width: size, height: size)
        .drawingGroup()
        .onAppear {
            if animate {
                startAnimation()
            }
        }
        .onChange(of: animate) { _, newValue in
            if newValue {
                startAnimation()
            } else {
                stopAnimation()
            }
        }
    }

    private func startAnimation() {
        withAnimation(.linear(duration: revolutionDuration).repeatForever(autoreverses: false)) {
            rotationCW = 360
            rotationCCW = -360
        }
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            centerPulse = 0.5
        }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            vertexPulse = 0.6
        }
    }

    private func stopAnimation() {
        withAnimation(.linear(duration: 0)) {
            rotationCW = 0
            rotationCCW = 0
            centerPulse = 0.15
            vertexPulse = 0.3
        }
    }

    private func meditativeTriangle(rotation: Double, strokeOpacity: Double, vertexOpacity: Double) -> some View {
        ZStack {
            TriangleShape()
                .stroke(effectiveColor.opacity(strokeOpacity), lineWidth: size > 80 ? 1.0 : 0.8)
                .frame(width: radius * 2, height: radius * 2)

            ForEach(0..<3, id: \.self) { i in
                let angle = (Double(i) * 120.0 - 90.0) * .pi / 180.0
                let x = Foundation.cos(angle) * radius
                let y = Foundation.sin(angle) * radius

                Circle()
                    .fill(effectiveColor.opacity(vertexOpacity))
                    .frame(width: size * 0.07, height: size * 0.07)
                    .shadow(color: effectiveColor.opacity(vertexOpacity * 0.4), radius: size * 0.06)
                    .offset(x: x, y: y)
            }
        }
        .rotationEffect(.degrees(rotation))
    }
}

// MARK: - Sacred Geometry Divider

/// Thin line with centered diamond ornament (two tiny triangles point-to-point).
/// Warm coral tint on the diamond for personality.
struct SacredGeometryDivider: View {
    var body: some View {
        HStack(spacing: 0) {
            line
            diamond
            line
        }
        .frame(height: 12)
    }

    private var line: some View {
        Rectangle()
            .fill(DesignSystem.Colors.border)
            .frame(height: 0.5)
    }

    private var diamond: some View {
        Canvas { context, size in
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            let hw: CGFloat = 4
            let hh: CGFloat = 6

            var path = Path()
            path.move(to: CGPoint(x: mid.x, y: mid.y - hh))
            path.addLine(to: CGPoint(x: mid.x + hw, y: mid.y))
            path.addLine(to: CGPoint(x: mid.x, y: mid.y + hh))
            path.addLine(to: CGPoint(x: mid.x - hw, y: mid.y))
            path.closeSubpath()

            context.stroke(path, with: .color(DesignSystem.Colors.accent.opacity(0.3)), lineWidth: 0.8)
        }
        .frame(width: 16, height: 12)
    }
}
