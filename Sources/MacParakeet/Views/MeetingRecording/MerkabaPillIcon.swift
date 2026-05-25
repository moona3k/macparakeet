import SwiftUI

/// Sacred geometry flower icon ported from Oatmeal's meeting recording pill.
/// The Flower of Life rotates while recording, and the center glow reacts to audio level.
struct MerkabaPillIcon: View {
    var isAnimating: Bool = false
    var audioLevel: Float = 0
    /// When `false`, render only the Flower-of-Life head (no stem/leaves) —
    /// used where the rosette is a compact standalone mark, e.g. inside the
    /// calendar countdown halo. Defaults to `true` so the recording pill keeps
    /// the full flower.
    var showStem: Bool = true

    @State private var rotation: Double = 0
    @State private var sway: Double = -1

    private var glowOpacity: Double {
        let base: Double = isAnimating ? 0.4 : 0.1
        let audioBoost = Double(audioLevel) * 0.5
        return min(0.9, base + audioBoost)
    }

    var body: some View {
        VStack(spacing: 0) {
            flowerHead
                .frame(width: 30, height: 30)
                .padding(.top, showStem ? 6 : 0)

            if showStem {
                stemAndLeaves
                    .frame(width: 30, height: 34)
                    .padding(.bottom, 4)
            }
        }
        .onChange(of: isAnimating) { _, animating in
            if animating {
                startAnimations()
            } else {
                stopAnimations()
            }
        }
        .onAppear {
            if isAnimating {
                startAnimations()
            }
        }
    }

    private var flowerHead: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            sacredGlow.opacity(glowOpacity),
                            sacredGlow.opacity(glowOpacity * 0.3),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 12
                    )
                )
                .frame(width: 24, height: 24)
                .animation(.easeOut(duration: 0.1), value: audioLevel)

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.55), lineWidth: 0.75)
                    .frame(width: 13, height: 13)

                ForEach(0..<6, id: \.self) { index in
                    let angle = Double(index) * 60
                    let radians = angle * .pi / 180
                    let radius: CGFloat = 6.5

                    Circle()
                        .stroke(Color.white.opacity(0.4), lineWidth: 0.75)
                        .frame(width: 13, height: 13)
                        .offset(
                            x: radius * CGFloat(cos(radians)),
                            y: radius * CGFloat(sin(radians))
                        )
                }
            }
            .rotationEffect(.degrees(rotation))
        }
    }

    private var stemAndLeaves: some View {
        let stemColor = sacredStem
        let swayOffset = CGFloat(sway) * 1.5

        return ZStack {
            StemShape(swayOffset: swayOffset)
                .stroke(stemColor.opacity(0.7), lineWidth: 1.2)

            LeafShape(
                basePoint: CGPoint(x: 0.5, y: 0.38),
                direction: .left,
                size: 8,
                swayOffset: swayOffset
            )
            .fill(stemColor.opacity(0.45))

            LeafShape(
                basePoint: CGPoint(x: 0.5, y: 0.38),
                direction: .left,
                size: 8,
                swayOffset: swayOffset
            )
            .stroke(stemColor.opacity(0.55), lineWidth: 0.5)

            LeafShape(
                basePoint: CGPoint(x: 0.5, y: 0.62),
                direction: .right,
                size: 9,
                swayOffset: swayOffset
            )
            .fill(stemColor.opacity(0.45))

            LeafShape(
                basePoint: CGPoint(x: 0.5, y: 0.62),
                direction: .right,
                size: 9,
                swayOffset: swayOffset
            )
            .stroke(stemColor.opacity(0.55), lineWidth: 0.5)
        }
    }

    private func startAnimations() {
        withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
            rotation = 360
        }
        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
            sway = 1
        }
    }

    private func stopAnimations() {
        withAnimation(.easeOut(duration: 0.5)) {
            rotation = 0
            sway = 0
        }
    }

    private var sacredGlow: Color {
        DesignSystem.Colors.sacredGlow
    }

    private var sacredStem: Color {
        DesignSystem.Colors.sacredStem
    }
}

private struct StemShape: Shape {
    var swayOffset: CGFloat

    var animatableData: CGFloat {
        get { swayOffset }
        set { swayOffset = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let midX = rect.midX
        var path = Path()
        path.move(to: CGPoint(x: midX, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: midX + swayOffset * 0.3, y: rect.height),
            control: CGPoint(x: midX + swayOffset, y: rect.height * 0.5)
        )
        return path
    }
}

private struct LeafShape: Shape {
    enum Direction { case left, right }

    let basePoint: CGPoint
    let direction: Direction
    let size: CGFloat
    var swayOffset: CGFloat = 0

    var animatableData: CGFloat {
        get { swayOffset }
        set { swayOffset = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let base = CGPoint(
            x: rect.width * basePoint.x + swayOffset * basePoint.y,
            y: rect.height * basePoint.y
        )
        let sign: CGFloat = direction == .left ? -1 : 1

        var path = Path()
        path.move(to: base)
        path.addQuadCurve(
            to: CGPoint(x: base.x + sign * size, y: base.y - 3),
            control: CGPoint(x: base.x + sign * size * 0.6, y: base.y - 5)
        )
        path.addQuadCurve(
            to: base,
            control: CGPoint(x: base.x + sign * size * 0.6, y: base.y + 2)
        )
        return path
    }
}
