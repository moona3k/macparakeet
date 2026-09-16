import SwiftUI
import MacParakeetCore

/// Static, UUID-seeded Seed of Life artwork for a recording with no image.
///
/// `BranchingRecordingCoverRecipe` is computed before `Canvas` draws. The
/// canvas closure only maps its bounded, normalized geometry to the card's
/// current size; it does not inspect recording content or schedule work.
struct BranchingRecordingCoverView: View {
    @State private var recipe: BranchingRecordingCoverRecipe

    init(recordingID: UUID) {
        _recipe = State(initialValue: BranchingRecordingCoverRecipe(recordingID: recordingID))
    }

    var body: some View {
        Canvas { context, size in
            let background = Color(BranchingRecordingCoverRecipe.nightBackground)
            let ink = Color(recipe.ink)
            let pale = Color(recipe.pale)
            let bounds = CGRect(origin: .zero, size: size)
            let minimumSide = min(size.width, size.height)
            let radius = minimumSide * CGFloat(recipe.radius)
            let origin = point(recipe.center, in: size)

            context.fill(Path(bounds), with: .color(background))
            context.fill(
                Path(bounds),
                with: .radialGradient(
                    Gradient(colors: [ink.opacity(0.14), .clear]),
                    center: origin,
                    startRadius: 6,
                    endRadius: size.width * 0.46
                )
            )

            let lit = Set(recipe.litRingIndexes)
            for (index, ringCenter) in ringCenters(origin: origin, radius: radius).enumerated() {
                let ring = Path(
                    ellipseIn: CGRect(
                        x: ringCenter.x - radius,
                        y: ringCenter.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                )
                let emphasis = lit.contains(index)
                context.fill(ring, with: .color(ink.opacity(emphasis ? 0.16 : 0.06)))
                context.stroke(
                    ring,
                    with: .color((emphasis ? pale : ink).opacity(emphasis ? 0.82 : 0.48)),
                    lineWidth: max(1, minimumSide * (emphasis ? 0.0054 : 0.0041))
                )
            }

            let beadRadius = max(1.3, radius * 0.06)
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: origin.x - beadRadius,
                        y: origin.y - beadRadius,
                        width: beadRadius * 2,
                        height: beadRadius * 2
                    )
                ),
                with: .color(pale.opacity(0.72))
            )
        }
        .accessibilityHidden(true)
    }

    private func point(_ point: BranchingRecordingCoverPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func ringCenters(origin: CGPoint, radius: CGFloat) -> [CGPoint] {
        var centers = [origin]
        for index in 0..<6 {
            let angle = recipe.rotation + Double(index) * (Double.pi / 3)
            centers.append(
                CGPoint(
                    x: origin.x + CGFloat(cos(angle)) * radius,
                    y: origin.y + CGFloat(sin(angle)) * radius
                )
            )
        }
        return centers
    }
}

private extension Color {
    init(_ color: BranchingRecordingCoverColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1)
    }
}
