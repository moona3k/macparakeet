import SwiftUI
import MacParakeetCore

/// Static, UUID-seeded artwork for a recording with no available image.
///
/// `BranchingRecordingCoverRecipe` is intentionally computed before `Canvas`
/// draws. The canvas closure only maps its bounded, normalized geometry to the
/// card's current size; it does not inspect recording content or schedule work.
struct BranchingRecordingCoverView: View {
    @State private var recipe: BranchingRecordingCoverRecipe

    init(recordingID: UUID) {
        _recipe = State(initialValue: BranchingRecordingCoverRecipe(recordingID: recordingID))
    }

    var body: some View {
        Canvas { context, size in
            let colors = recipe.palette.colors
            let background = Color(colors.background)
            let field = Color(colors.field)
            let branch = Color(colors.branch)
            let accent = Color(colors.accent)
            let line = Color(colors.line)
            let bounds = CGRect(origin: .zero, size: size)

            context.fill(Path(bounds), with: .color(background))
            context.fill(
                Path(bounds),
                with: .linearGradient(
                    Gradient(colors: [field.opacity(0.58), background.opacity(0.15), branch.opacity(0.18)]),
                    startPoint: CGPoint(x: 0, y: size.height),
                    endPoint: CGPoint(x: size.width, y: 0)
                )
            )

            for limb in recipe.limbs {
                let pigment = color(for: limb.pigment, field: field, branch: branch, accent: accent)
                let bodyPath = taperedPath(for: limb, in: size)
                let start = point(limb.start, in: size)
                let end = point(limb.end, in: size)
                let centerline = curvedPath(for: limb, in: size)

                context.fill(
                    bodyPath,
                    with: .linearGradient(
                        Gradient(colors: [
                            pigment.opacity(limb.opacity * 0.22),
                            pigment.opacity(limb.opacity * 0.72),
                        ]),
                        startPoint: start,
                        endPoint: end
                    )
                )
                context.stroke(
                    centerline,
                    with: .color(line.opacity(0.20 + limb.opacity * 0.24)),
                    lineWidth: max(0.45, min(size.width, size.height) * CGFloat(limb.endWidth) * 0.18)
                )
            }

            let focalPoint = point(recipe.focalPoint, in: size)
            let focalRadius = max(2, min(size.width, size.height) * 0.055)
            let aura = Path(
                ellipseIn: CGRect(
                    x: focalPoint.x - focalRadius * 2.5,
                    y: focalPoint.y - focalRadius * 2.5,
                    width: focalRadius * 5,
                    height: focalRadius * 5
                ))
            context.fill(
                aura,
                with: .radialGradient(
                    Gradient(colors: [accent.opacity(0.42), accent.opacity(0.06), .clear]),
                    center: focalPoint,
                    startRadius: 0,
                    endRadius: focalRadius * 2.5
                )
            )
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: focalPoint.x - focalRadius * 0.28,
                        y: focalPoint.y - focalRadius * 0.28,
                        width: focalRadius * 0.56,
                        height: focalRadius * 0.56
                    )),
                with: .color(accent.opacity(0.92))
            )
        }
        .accessibilityHidden(true)
    }

    private func color(
        for pigment: BranchingRecordingCoverPigment,
        field: Color,
        branch: Color,
        accent: Color
    ) -> Color {
        switch pigment {
        case .field: field
        case .branch: branch
        case .accent: accent
        }
    }

    private func taperedPath(for limb: BranchingRecordingCoverLimb, in size: CGSize) -> Path {
        let start = point(limb.start, in: size)
        let control = point(limb.control, in: size)
        let end = point(limb.end, in: size)
        let minimumSize = min(size.width, size.height)
        let startOffset = normal(from: start, to: control).scaled(by: minimumSize * CGFloat(limb.startWidth) * 0.5)
        let endOffset = normal(from: control, to: end).scaled(by: minimumSize * CGFloat(limb.endWidth) * 0.5)
        let controlOffset = (startOffset + endOffset).scaled(by: 0.5)
        let outerControls = cubicControls(
            from: start + startOffset,
            through: control + controlOffset,
            to: end + endOffset
        )
        let innerControls = cubicControls(
            from: end - endOffset,
            through: control - controlOffset,
            to: start - startOffset
        )

        var path = Path()
        path.move(to: start + startOffset)
        path.addCurve(
            to: end + endOffset,
            control1: outerControls.0,
            control2: outerControls.1
        )
        path.addLine(to: end - endOffset)
        path.addCurve(
            to: start - startOffset,
            control1: innerControls.0,
            control2: innerControls.1
        )
        path.closeSubpath()
        return path
    }

    private func curvedPath(for limb: BranchingRecordingCoverLimb, in size: CGSize) -> Path {
        let start = point(limb.start, in: size)
        let end = point(limb.end, in: size)
        let controls = cubicControls(from: start, through: point(limb.control, in: size), to: end)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: controls.0, control2: controls.1)
        return path
    }

    /// Converts the shared quadratic shape model into equivalent cubic controls
    /// so filled tapered limbs and their center strokes bend together.
    private func cubicControls(from start: CGPoint, through control: CGPoint, to end: CGPoint) -> (CGPoint, CGPoint) {
        (
            start + (control - start).scaled(by: 2.0 / 3.0),
            end + (control - end).scaled(by: 2.0 / 3.0)
        )
    }

    private func point(_ point: BranchingRecordingCoverPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func normal(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(0.0001, hypot(dx, dy))
        return CGPoint(x: -dy / length, y: dx / length)
    }
}

private extension Color {
    init(_ color: BranchingRecordingCoverColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1)
    }
}

private extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    func scaled(by factor: CGFloat) -> CGPoint {
        CGPoint(x: x * factor, y: y * factor)
    }
}
