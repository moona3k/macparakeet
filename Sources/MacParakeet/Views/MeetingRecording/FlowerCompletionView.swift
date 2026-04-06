import SwiftUI

/// Exit animation when recording stops: Flower of Life accelerates and collapses,
/// leaves detach and drift down, stem fades. Fires callback when collapse is done
/// so the pill can transition to the merkaba processing spinner.
struct FlowerCompletionView: View {
    @Binding var stemCollapsed: Bool
    var onCollapseFinished: (() -> Void)?

    // Flower head
    @State private var flowerRotation: Double = 0
    @State private var petalScale: CGFloat = 1.0
    @State private var flowerOpacity: CGFloat = 1.0

    // Glow
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

    // Overall fade
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

                // Flower of Life
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
            }
            .frame(width: 30, height: 30)
            .padding(.top, topPadding)

            // Stem + leaves
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
        .opacity(overallOpacity)
        .onAppear { runCollapseAnimation() }
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

    // MARK: - Collapse Animation

    private func runCollapseAnimation() {
        // Phase 1a (0-0.8s): Flower head accelerates, petals collapse
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

        // Phase 1c (0.3-0.7s): Stem retracts + layout collapses
        withAnimation(.easeInOut(duration: 0.4).delay(0.3)) {
            stemTrim = 0
            stemOpacity = 0
            stemFrameHeight = 0
            bottomPadding = 0
            topPadding = 0
            stemCollapsed = true
        }

        // Phase 1d (0.8-1.0s): Flower fades out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut(duration: 0.2)) {
                flowerOpacity = 0
                glowOpacity = 0
                overallOpacity = 0
            }
        }

        // Done — hand off to next phase
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            onCollapseFinished?()
        }
    }
}
