import SwiftUI

/// Exit animation when recording stops: Flower of Life accelerates and collapses,
/// leaves detach and drift down, stem fades, gold flash at singularity, checkmark, fade out.
/// Ported from Oatmeal's meeting recording pill.
struct FlowerCompletionView: View {
    @Binding var stemCollapsed: Bool
    var onFinished: (() -> Void)?

    // Flower head
    @State private var flowerRotation: Double = 0
    @State private var petalScale: CGFloat = 1.0
    @State private var flowerOpacity: CGFloat = 1.0

    // Glow color transition (0 = green, 1 = gold)
    @State private var glowGold: CGFloat = 0
    @State private var glowOpacity: CGFloat = 0.5

    // Stem & leaves
    @State private var stemTrim: CGFloat = 1.0
    @State private var stemOpacity: CGFloat = 1.0
    @State private var stemFrameHeight: CGFloat = 34
    @State private var topPadding: CGFloat = 6
    @State private var bottomPadding: CGFloat = 4
    @State private var leftLeafOffset: CGSize = .zero
    @State private var leftLeafRotation: Double = 0
    @State private var leftLeafOpacity: CGFloat = 1.0
    @State private var rightLeafOffset: CGSize = .zero
    @State private var rightLeafRotation: Double = 0
    @State private var rightLeafOpacity: CGFloat = 1.0

    // Flash & checkmark
    @State private var flashOpacity: CGFloat = 0
    @State private var checkVisible: Bool = false

    // Overall
    @State private var overallScale: CGFloat = 1.0
    @State private var overallOpacity: CGFloat = 1.0

    private let greenColor = Color(red: 0.4, green: 0.85, blue: 0.4)
    private let goldColor = Color(red: 1.0, green: 0.85, blue: 0.4)
    private let stemColor = Color(red: 0.35, green: 0.65, blue: 0.35)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Center glow — green → gold
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                glowColor.opacity(glowOpacity),
                                glowColor.opacity(glowOpacity * 0.3),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 12
                        )
                    )
                    .frame(width: 24, height: 24)

                // Flower of Life — accelerating spin, petals collapsing inward
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.55), lineWidth: 0.75)
                        .frame(width: 13, height: 13)

                    ForEach(0..<6, id: \.self) { index in
                        let angle = Double(index) * 60.0 * .pi / 180
                        let r: CGFloat = 6.5 * petalScale
                        Circle()
                            .stroke(Color.white.opacity(0.4), lineWidth: 0.75)
                            .frame(width: 13 * petalScale, height: 13 * petalScale)
                            .offset(
                                x: r * CGFloat(cos(angle)),
                                y: r * CGFloat(sin(angle))
                            )
                    }
                }
                .rotationEffect(.degrees(flowerRotation))
                .opacity(flowerOpacity)

                // Gold flash — singularity burst
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                goldColor.opacity(flashOpacity),
                                goldColor.opacity(flashOpacity * 0.4),
                                .clear,
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 15
                        )
                    )
                    .frame(width: 30, height: 30)

                // Checkmark
                if checkVisible {
                    AnimatedCheckmarkView(color: greenColor)
                        .frame(width: 26, height: 26)
                }
            }
            .frame(width: 30, height: 30)
            .padding(.top, topPadding)

            // Stem + leaves — frame height animates to 0
            ZStack {
                StemLineShape()
                    .trim(from: 0, to: stemTrim)
                    .stroke(stemColor.opacity(0.7), lineWidth: 1.2)

                leftLeaf
                    .offset(leftLeafOffset)
                    .rotationEffect(.degrees(leftLeafRotation), anchor: .trailing)
                    .opacity(leftLeafOpacity)

                rightLeaf
                    .offset(rightLeafOffset)
                    .rotationEffect(.degrees(rightLeafRotation), anchor: .leading)
                    .opacity(rightLeafOpacity)
            }
            .frame(width: 30, height: stemFrameHeight)
            .opacity(stemOpacity)
            .padding(.bottom, bottomPadding)
        }
        .scaleEffect(overallScale)
        .opacity(overallOpacity)
        .onAppear { runAnimation() }
    }

    // MARK: - Leaf Shapes

    private var leftLeaf: some View {
        Canvas { context, size in
            let base = CGPoint(x: size.width * 0.5, y: size.height * 0.38)
            var path = Path()
            path.move(to: base)
            path.addQuadCurve(
                to: CGPoint(x: base.x - 8, y: base.y - 3),
                control: CGPoint(x: base.x - 4.8, y: base.y - 5)
            )
            path.addQuadCurve(
                to: base,
                control: CGPoint(x: base.x - 4.8, y: base.y + 2)
            )
            context.fill(path, with: .color(stemColor.opacity(0.45)))
            context.stroke(path, with: .color(stemColor.opacity(0.55)), lineWidth: 0.5)
        }
        .frame(width: 30, height: 34)
    }

    private var rightLeaf: some View {
        Canvas { context, size in
            let base = CGPoint(x: size.width * 0.5, y: size.height * 0.62)
            var path = Path()
            path.move(to: base)
            path.addQuadCurve(
                to: CGPoint(x: base.x + 9, y: base.y - 3),
                control: CGPoint(x: base.x + 5.4, y: base.y - 5)
            )
            path.addQuadCurve(
                to: base,
                control: CGPoint(x: base.x + 5.4, y: base.y + 2)
            )
            context.fill(path, with: .color(stemColor.opacity(0.45)))
            context.stroke(path, with: .color(stemColor.opacity(0.55)), lineWidth: 0.5)
        }
        .frame(width: 30, height: 34)
    }

    // MARK: - Glow Color

    private var glowColor: Color {
        Color(
            red: 0.4 + glowGold * 0.6,
            green: 0.85,
            blue: 0.4 * (1.0 - glowGold)
        )
    }

    // MARK: - Stem Shape

    private struct StemLineShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: 0))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.height))
            return path
        }
    }

    // MARK: - Animation Sequence

    private func runAnimation() {
        // Phase 1 (0-0.8s): Flower head accelerates, petals collapse
        withAnimation(.easeIn(duration: 0.8)) {
            flowerRotation = 540
            petalScale = 0.1
            glowGold = 1.0
        }

        // Phase 1b (0.1-0.7s): Leaves detach and drift
        withAnimation(.easeOut(duration: 0.6).delay(0.1)) {
            leftLeafOffset = CGSize(width: -10, height: 14)
            leftLeafRotation = -30
            leftLeafOpacity = 0
        }
        withAnimation(.easeOut(duration: 0.6).delay(0.15)) {
            rightLeafOffset = CGSize(width: 10, height: 12)
            rightLeafRotation = 25
            rightLeafOpacity = 0
        }

        // Phase 1c (0.3-0.7s): Stem retracts + layout collapses, topPadding syncs
        withAnimation(.easeInOut(duration: 0.4).delay(0.3)) {
            stemTrim = 0
            stemOpacity = 0
            stemFrameHeight = 0
            bottomPadding = 0
            topPadding = 0
            stemCollapsed = true
        }

        // Phase 2 (0.8-1.0s): Gold flash, flower + glow fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut(duration: 0.2)) {
                flashOpacity = 1.0
                flowerOpacity = 0
                glowOpacity = 0
            }
        }

        // Phase 3 (1.0s): Flash fades, checkmark appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeOut(duration: 0.2)) {
                flashOpacity = 0
            }
            checkVisible = true
        }

        // Phase 4 (1.0-2.6s): Hold checkmark

        // Phase 5 (2.6-3.0s): Scale down and fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            withAnimation(.easeIn(duration: 0.4)) {
                overallScale = 0.5
                overallOpacity = 0
            }
        }

        // Done — fire callback
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) {
            onFinished?()
        }
    }
}

// MARK: - Animated Checkmark (Apple Pay style)

private struct AnimatedCheckmarkView: View {
    var color: Color = Color(red: 0.3, green: 0.85, blue: 0.45)

    @State private var ringTrim: CGFloat = 0
    @State private var checkTrim: CGFloat = 0

    private let lineWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: ringTrim)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            CheckmarkShape()
                .trim(from: 0, to: checkTrim)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .padding(6)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                ringTrim = 1
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.5)) {
                checkTrim = 1
            }
        }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: w * 0.22, y: h * 0.52))
        path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.72))
        path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.28))
        return path
    }
}
