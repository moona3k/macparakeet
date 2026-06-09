import SwiftUI
import MacParakeetCore

/// A simplified, recolorable, single-color vector mark for a media platform.
///
/// Hand-drawn with `Canvas` (no third-party logo assets) so each mark stays
/// trademark-safe, scales crisply at any size, and tints to any color. A `nil`
/// platform renders a neutral globe ("any website"). Rendered once per size —
/// orbit motion is applied as a layer transform, so the path is not re-rasterized
/// every frame.
struct PlatformGlyph: View {
    let platform: MediaPlatform?
    var color: Color = .primary

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
                .insetBy(dx: size.width * 0.07, dy: size.height * 0.07)
            switch platform {
            case .youtube: Self.drawYouTube(ctx, rect, color)
            case .x: Self.drawX(ctx, rect, color)
            case .vimeo: Self.drawVimeo(ctx, rect, color)
            case .facebook: Self.drawFacebook(ctx, rect, color)
            case .tiktok: Self.drawTikTok(ctx, rect, color)
            case .instagram: Self.drawInstagram(ctx, rect, color)
            case .applePodcasts: Self.drawPodcasts(ctx, rect, color)
            case .soundcloud, .twitch, .none: Self.drawGeneric(ctx, rect, color)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Coordinate helper

    private static func pt(_ r: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height)
    }

    // MARK: - YouTube — wide rounded pill with a knocked-out play triangle

    private static func drawYouTube(_ ctx: GraphicsContext, _ r: CGRect, _ color: Color) {
        let bodyH = r.height * 0.72
        let body = CGRect(x: r.minX, y: r.midY - bodyH / 2, width: r.width, height: bodyH)
        var path = Path(roundedRect: body, cornerRadius: bodyH * 0.30)
        let tw = r.width * 0.15
        let th = bodyH * 0.30
        var tri = Path()
        tri.move(to: CGPoint(x: r.midX - tw * 0.55, y: r.midY - th))
        tri.addLine(to: CGPoint(x: r.midX - tw * 0.55, y: r.midY + th))
        tri.addLine(to: CGPoint(x: r.midX + tw, y: r.midY))
        tri.closeSubpath()
        path.addPath(tri)
        ctx.fill(path, with: .color(color), style: FillStyle(eoFill: true))
    }

    // MARK: - X — two crossing blades

    private static func drawX(_ ctx: GraphicsContext, _ r: CGRect, _ color: Color) {
        let inset = r.width * 0.10
        let tl = CGPoint(x: r.minX + inset, y: r.minY + inset)
        let br = CGPoint(x: r.maxX - inset, y: r.maxY - inset)
        let tr = CGPoint(x: r.maxX - inset, y: r.minY + inset)
        let bl = CGPoint(x: r.minX + inset, y: r.maxY - inset)
        let thick = r.width * 0.22
        ctx.fill(bar(tl, br, thick), with: .color(color))
        ctx.fill(bar(tr, bl, thick), with: .color(color))
    }

    /// A filled quadrilateral "bar" from `a` to `b` of the given thickness.
    private static func bar(_ a: CGPoint, _ b: CGPoint, _ thick: CGFloat) -> Path {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max((dx * dx + dy * dy).squareRoot(), 0.0001)
        let nx = -dy / len * thick / 2
        let ny = dx / len * thick / 2
        var p = Path()
        p.move(to: CGPoint(x: a.x + nx, y: a.y + ny))
        p.addLine(to: CGPoint(x: b.x + nx, y: b.y + ny))
        p.addLine(to: CGPoint(x: b.x - nx, y: b.y - ny))
        p.addLine(to: CGPoint(x: a.x - nx, y: a.y - ny))
        p.closeSubpath()
        return p
    }

    // MARK: - Vimeo — bold rounded "v"

    private static func drawVimeo(_ ctx: GraphicsContext, _ r: CGRect, _ color: Color) {
        var path = Path()
        path.move(to: pt(r, 0.12, 0.32))
        path.addLine(to: pt(r, 0.50, 0.78))
        path.addLine(to: pt(r, 0.88, 0.22))
        ctx.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: r.width * 0.17, lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - Facebook — filled circle with a knocked-out "f"

    private static func drawFacebook(_ ctx: GraphicsContext, _ r: CGRect, _ color: Color) {
        ctx.fill(Path(ellipseIn: r), with: .color(color))
        var knock = ctx
        knock.blendMode = .destinationOut
        let stemW = r.width * 0.12
        let stemX = r.midX + r.width * 0.03
        let stem = CGRect(x: stemX - stemW / 2, y: r.minY + r.height * 0.28,
                          width: stemW, height: r.height * 0.52)
        knock.fill(Path(roundedRect: stem, cornerRadius: stemW * 0.25), with: .color(.black))
        let crossbar = CGRect(x: stemX - r.width * 0.12, y: r.minY + r.height * 0.42,
                              width: r.width * 0.26, height: stemW)
        knock.fill(Path(roundedRect: crossbar, cornerRadius: stemW * 0.3), with: .color(.black))
        // Top hook: short horizontal arm at the crown of the stem.
        let hook = CGRect(x: stemX - stemW / 2, y: r.minY + r.height * 0.26,
                          width: r.width * 0.15, height: stemW)
        knock.fill(Path(roundedRect: hook, cornerRadius: stemW * 0.3), with: .color(.black))
    }

    // MARK: - TikTok — stylized eighth note

    private static func drawTikTok(_ ctx: GraphicsContext, _ r: CGRect, _ color: Color) {
        let stemW = r.width * 0.13
        let stemX = r.minX + r.width * 0.60
        let stem = CGRect(x: stemX - stemW / 2, y: r.minY + r.height * 0.14,
                          width: stemW, height: r.height * 0.52)
        ctx.fill(Path(roundedRect: stem, cornerRadius: stemW * 0.45), with: .color(color))
        // Note head (bottom-left).
        let headW = r.width * 0.34
        let headH = headW * 0.80
        let head = CGRect(x: r.minX + r.width * 0.18, y: r.minY + r.height * 0.56,
                          width: headW, height: headH)
        ctx.fill(Path(ellipseIn: head), with: .color(color))
        // Flag curling off the top of the stem.
        var flag = Path()
        flag.move(to: pt(r, 0.60, 0.16))
        flag.addQuadCurve(to: pt(r, 0.93, 0.36), control: pt(r, 0.95, 0.12))
        ctx.stroke(flag, with: .color(color), style: StrokeStyle(lineWidth: r.width * 0.13, lineCap: .round))
    }

    // MARK: - Instagram — outlined squircle + lens + corner dot

    private static func drawInstagram(_ ctx: GraphicsContext, _ r: CGRect, _ color: Color) {
        let lw = r.width * 0.09
        let frame = r.insetBy(dx: lw / 2, dy: lw / 2)
        ctx.stroke(Path(roundedRect: frame, cornerRadius: r.width * 0.28),
                   with: .color(color), style: StrokeStyle(lineWidth: lw))
        let lensD = r.width * 0.42
        let lens = CGRect(x: r.midX - lensD / 2, y: r.midY - lensD / 2, width: lensD, height: lensD)
        ctx.stroke(Path(ellipseIn: lens), with: .color(color), style: StrokeStyle(lineWidth: lw))
        let dotD = r.width * 0.11
        let dot = CGRect(x: r.maxX - r.width * 0.30, y: r.minY + r.height * 0.19, width: dotD, height: dotD)
        ctx.fill(Path(ellipseIn: dot), with: .color(color))
    }

    // MARK: - Apple Podcasts — broadcast ring + microphone figure

    private static func drawPodcasts(_ ctx: GraphicsContext, _ r: CGRect, _ color: Color) {
        let lw = r.width * 0.085
        ctx.stroke(Path(ellipseIn: r.insetBy(dx: lw / 2, dy: lw / 2)),
                   with: .color(color), style: StrokeStyle(lineWidth: lw))
        // Mic head.
        let headD = r.width * 0.22
        let head = CGRect(x: r.midX - headD / 2, y: r.minY + r.height * 0.32, width: headD, height: headD)
        ctx.fill(Path(ellipseIn: head), with: .color(color))
        // Tapered mic body.
        let stemW = r.width * 0.15
        let stem = CGRect(x: r.midX - stemW / 2, y: r.minY + r.height * 0.45,
                          width: stemW, height: r.height * 0.24)
        ctx.fill(Path(roundedRect: stem, cornerRadius: stemW * 0.5), with: .color(color))
    }

    // MARK: - Generic — globe (any website)

    private static func drawGeneric(_ ctx: GraphicsContext, _ r: CGRect, _ color: Color) {
        let lw = r.width * 0.08
        ctx.stroke(Path(ellipseIn: r.insetBy(dx: lw / 2, dy: lw / 2)),
                   with: .color(color), style: StrokeStyle(lineWidth: lw))
        var equator = Path()
        equator.move(to: pt(r, 0.06, 0.5))
        equator.addLine(to: pt(r, 0.94, 0.5))
        ctx.stroke(equator, with: .color(color), style: StrokeStyle(lineWidth: lw * 0.8))
        let meridian = CGRect(x: r.midX - r.width * 0.18, y: r.minY + lw / 2,
                              width: r.width * 0.36, height: r.height - lw)
        ctx.stroke(Path(ellipseIn: meridian), with: .color(color), style: StrokeStyle(lineWidth: lw * 0.8))
    }
}

// MARK: - Brand tint mapping

extension MediaPlatform {
    /// The brand tint used when this platform's glyph "blooms" to color.
    var brandTint: Color {
        switch self {
        case .youtube: return DesignSystem.Colors.youtubeRed
        case .x: return DesignSystem.Colors.xMark
        case .vimeo: return DesignSystem.Colors.vimeoBlue
        case .facebook: return DesignSystem.Colors.facebookBlue
        case .tiktok: return DesignSystem.Colors.tiktokTeal
        case .instagram: return DesignSystem.Colors.instagramPink
        case .applePodcasts: return DesignSystem.Colors.podcastPurple
        case .soundcloud: return DesignSystem.Colors.warningAmber
        case .twitch: return DesignSystem.Colors.podcastPurple
        }
    }
}

#if DEBUG
#Preview("Platform glyphs") {
    let platforms: [MediaPlatform] = [
        .youtube, .x, .vimeo, .facebook, .tiktok, .instagram, .applePodcasts,
    ]
    return VStack(spacing: 24) {
        HStack(spacing: 20) {
            ForEach(platforms, id: \.self) { p in
                VStack {
                    PlatformGlyph(platform: p, color: p.brandTint)
                        .frame(width: 44, height: 44)
                    Text(p.displayName).font(.caption2)
                }
            }
            VStack {
                PlatformGlyph(platform: nil, color: .secondary)
                    .frame(width: 44, height: 44)
                Text("Other").font(.caption2)
            }
        }
        HStack(spacing: 20) {
            ForEach(platforms, id: \.self) { p in
                PlatformGlyph(platform: p, color: .primary)
                    .frame(width: 34, height: 34)
            }
        }
    }
    .padding(40)
}
#endif
