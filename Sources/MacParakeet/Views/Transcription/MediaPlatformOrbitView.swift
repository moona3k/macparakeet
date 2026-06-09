import SwiftUI
import MacParakeetCore

/// The hero for the Transcribe-URL surfaces: a slow constellation of platform
/// glyphs orbiting a core. When a recognized URL is pasted, the orbit recedes and
/// the matched platform blooms to focus in the center.
///
/// **Idle-CPU note.** The rotation is driven by a single `repeatForever`
/// `.rotationEffect` animation, *not* a `TimelineView`. That means the view `body`
/// is evaluated once and Core Animation interpolates the transform on the render
/// server — there is no per-frame SwiftUI/NSHostingView display-list re-commit
/// (the cost behind the v0.6.14 idle-CPU regression; see `BreathingSeedOfLifeView`).
/// The window server automatically throttles render-server animation when the
/// window is occluded, miniaturized, or inactive, so no extra visibility gating is
/// needed. Under Reduce Motion the orbit is static.
struct MediaPlatformOrbitView: View {
    /// The platform recognized from the current URL draft (nil while idle/typing).
    var matched: MediaPlatform?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin: Double = 0

    /// Seconds per full revolution — deliberately slow.
    private let period: Double = 48

    private let orbitPlatforms: [MediaPlatform] = [
        .youtube, .x, .vimeo, .facebook, .tiktok, .instagram, .applePodcasts,
    ]

    /// The matched platform, but only when it is one we orbit (so an obscure
    /// recognized site falls back to the generic hero rather than a missing chip).
    private var focus: MediaPlatform? {
        guard let matched, orbitPlatforms.contains(matched) else { return nil }
        return matched
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side * 0.40
            let node = side * 0.215

            ZStack {
                guideRing(radius: radius)
                    .opacity(matched == nil ? 0.22 : 0.06)

                ring(radius: radius, node: node)
                    .opacity(matched == nil ? 1 : 0.14)
                    .blur(radius: matched == nil ? 0 : 1.5)
                    .animation(.easeInOut(duration: 0.35), value: matched == nil)

                center(side: side)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear(perform: startSpin)
        .onChange(of: reduceMotion) { _, _ in startSpin() }
    }

    // MARK: - Pieces

    private func guideRing(radius: CGFloat) -> some View {
        Circle()
            .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
            .frame(width: radius * 2, height: radius * 2)
    }

    /// The orbiting chips. Each chip self-places at `base + spin` and counter-rotates
    /// by the same amount so it stays upright while orbiting. Animating the single
    /// `spin` value promotes every rotation to a render-server transform.
    private func ring(radius: CGFloat, node: CGFloat) -> some View {
        ZStack {
            ForEach(Array(orbitPlatforms.enumerated()), id: \.element) { index, platform in
                let angle = baseDegrees(index) + spin
                chip(platform, size: node)
                    .rotationEffect(.degrees(-angle))   // keep upright
                    .offset(y: -radius)
                    .rotationEffect(.degrees(angle))     // place on the circle
            }
        }
    }

    private func chip(_ platform: MediaPlatform, size: CGFloat) -> some View {
        PlatformGlyph(platform: platform, color: platform.brandTint)
            .frame(width: size * 0.62, height: size * 0.62)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .fill(platform.brandTint.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .strokeBorder(platform.brandTint.opacity(0.16), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private func center(side: CGFloat) -> some View {
        ZStack {
            if let focus {
                heroBadge(platform: focus, tint: focus.brandTint, side: side)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if matched != nil {
                // Recognized but not one of the orbit chips (e.g. SoundCloud) —
                // show a neutral hero so the field still feels "understood".
                heroBadge(platform: matched, tint: DesignSystem.Colors.accent, side: side)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                idleCore(side: side)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: matched)
    }

    private func heroBadge(platform: MediaPlatform?, tint: Color, side: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.14))
                .frame(width: side * 0.46, height: side * 0.46)
            Circle()
                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
                .frame(width: side * 0.46, height: side * 0.46)
            PlatformGlyph(platform: platform, color: tint)
                .frame(width: side * 0.26, height: side * 0.26)
        }
    }

    private func idleCore(side: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(DesignSystem.Colors.accent.opacity(0.06))
                .frame(width: side * 0.40, height: side * 0.40)
            PlatformGlyph(platform: nil, color: DesignSystem.Colors.textSecondary)
                .frame(width: side * 0.20, height: side * 0.20)
                .opacity(0.55)
        }
    }

    // MARK: - Motion

    /// (Re)start the continuous rotation. Render-server driven via `repeatForever`,
    /// so it costs no app-side per-frame work; static under Reduce Motion.
    private func startSpin() {
        spin = 0
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
            spin = 360
        }
    }

    /// Resting angle (degrees) for chip `index`, evenly spaced, first chip at top.
    private func baseDegrees(_ index: Int) -> Double {
        Double(index) / Double(orbitPlatforms.count) * 360 - 90
    }
}

#if DEBUG
#Preview("Orbit — idle") {
    MediaPlatformOrbitView(matched: nil)
        .frame(width: 130, height: 130)
        .padding(40)
}

#Preview("Orbit — matched YouTube") {
    MediaPlatformOrbitView(matched: .youtube)
        .frame(width: 130, height: 130)
        .padding(40)
}
#endif
