import MacParakeetCore
import SwiftUI

/// The view rendered by the dictation overlay pill during the `.formatting`
/// beat — the window between STT completion and the success checkmark while
/// the AI formatter is polishing the transcript.
///
/// Renders a **spinning Seed of Life** whose six coral petal circles grow
/// in place from tiny vertex dots into full petals. Rotation is continuous
/// from first paint through dismissal — there is no settle phase, no
/// angular snap, and no restart after the bloom completes. The composition
/// orbits at a meditative ~10s/rev for the entire formatter window.
///
/// ## Why it reads as a natural morph from the `.processing` Merkaba
///
/// Two geometric properties carry the transition:
///
/// 1. **6-fold symmetry.** The Merkaba in `SpinnerRingView` carries six
///    vertex lights (two triangles × three vertices) arranged at 60°
///    around the center. This view carries six coral petals, also at
///    60° around the center. The eye sees "six things → six things"
///    during the cross-fade, even though the individual elements morph.
///
/// 2. **Matching bounding ring.** Each petal's outer edge reaches a
///    radius of `2 × ringOffset` = `size × 0.44` from the center, which
///    is visually close to `SpinnerRingView`'s outer-vertex radius of
///    `size × 0.423`. So the coral bloom fills approximately the same
///    circle the Merkaba's vertex lights were tracing, and the
///    transition reads as a geometry re-composition rather than a
///    resize or relocation.
///
/// The petal *centers* sit at `size × 0.22` — half the Merkaba vertex
/// radius — so each petal grows *inward* from the outer bounding ring
/// toward its center. If you retune `ringOffset`, re-check that the
/// resulting `2 × ringOffset` stays close to `SpinnerRingView.radius`
/// so the cross-fade continues to feel continuous.
///
/// ## Phases (all concurrent with the continuous rotation)
/// - **Bud**   (0 → 0.15s): six coral dots ignite at the vertex ring.
/// - **Bloom** (0.15 → 1.00s): each dot expands in place into a full
///   Seed of Life petal. Breath and nexus heartbeat come in gently.
/// - **Hold**  (1.00s → ∞): the full flower rotates + breathes until
///   the formatter completes and the success checkmark takes over.
///
/// ## Accessibility
/// Honors `Reduce Motion` by presenting the fully-bloomed peak state
/// statically — the user still sees the coral flower, just no spin. The
/// view is exposed to VoiceOver as "Refining transcript."
struct FormatterVisualView: View {
    /// Outer diameter of the icon box. The pill's equal padding (10 pt on
    /// each side, when icon-only) adds 20 pt on top, so the pill renders
    /// at 46×46 — the same size as the `.processing` spinner. Keeping the
    /// pill size identical is what makes the state transition feel like a
    /// hue/geometry evolution rather than a resize.
    var size: CGFloat = 26

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0 = vertex dots (petals invisible), 1 = full Seed of Life petals.
    @State private var petalScale: CGFloat = 0
    /// Continuous slow CW rotation — starts on appear and never stops.
    @State private var rotation: Double = 0
    /// 0 = rest, 1 = inhaled. Drives petal brightness + guide ring breath.
    @State private var breath: CGFloat = 0
    /// Center nexus heartbeat.
    @State private var nexusPulse: CGFloat = 0
    /// Vertex dot brightness — bright at t=0 (ignition), recedes to a
    /// subtle anchor brightness after the petals reach full size so the
    /// 6-fold symmetry stays legible through the hold phase.
    @State private var dotBrightness: CGFloat = 0

    /// Distance from center to each petal's center. Because each petal's
    /// radius is also `size × 0.22`, the outer edge of the bloom sits at
    /// `2 × ringOffset` = `size × 0.44` — visually close to
    /// `SpinnerRingView`'s outer-vertex radius of `size × 0.423`, which
    /// is what makes the cross-fade feel like a geometry re-composition
    /// at the same bounding ring.
    private var ringOffset: CGFloat { size * 0.22 }

    var body: some View {
        ZStack {
            // Faint outer guide ring — coral tint, gently breathing.
            Circle()
                .stroke(
                    DesignSystem.Colors.accent.opacity(0.08 + 0.08 * Double(breath)),
                    lineWidth: 0.6
                )
                .frame(width: size, height: size)

            // Rotating container — petals + vertex dots spin as one body.
            ZStack {
                // Six coral petals, growing in place from 0 radius.
                SeedOfLifeGrowingPetals(petalScale: petalScale)
                    .stroke(
                        DesignSystem.Colors.accent.opacity(0.45 + 0.25 * Double(breath)),
                        style: StrokeStyle(lineWidth: 0.9, lineJoin: .round)
                    )
                    .frame(width: size, height: size)
                    .shadow(
                        color: DesignSystem.Colors.accent.opacity(0.32 * Double(petalScale) * (0.6 + 0.4 * Double(breath))),
                        radius: size * 0.14
                    )

                // Six vertex dots at the ring positions — ignition points
                // of the bloom, kept at ~40% brightness through the hold
                // so the 6-fold symmetry reads as steady anchor beats.
                ForEach(0..<6, id: \.self) { i in
                    vertexDot(index: i)
                }
            }
            .rotationEffect(.degrees(rotation))

            // Central coral heartbeat — the warm core.
            Circle()
                .fill(DesignSystem.Colors.accent.opacity(0.60 + 0.35 * Double(nexusPulse)))
                .frame(width: size * 0.11, height: size * 0.11)
                .shadow(
                    color: DesignSystem.Colors.accent.opacity(0.50 * Double(nexusPulse)),
                    radius: size * 0.22
                )
        }
        .frame(width: size, height: size)
        .drawingGroup()
        .accessibilityElement()
        .accessibilityLabel("Refining transcript")
        .onAppear { runAnimations() }
    }

    private func vertexDot(index: Int) -> some View {
        let angle = (Double(index) * 60.0 - 90.0) * .pi / 180.0
        let x = Foundation.cos(angle) * ringOffset
        let y = Foundation.sin(angle) * ringOffset
        return Circle()
            .fill(DesignSystem.Colors.accent.opacity(0.60 * Double(dotBrightness)))
            .frame(width: size * 0.085, height: size * 0.085)
            .shadow(
                color: DesignSystem.Colors.accent.opacity(0.45 * Double(dotBrightness)),
                radius: size * 0.10
            )
            .offset(x: x, y: y)
    }

    private func runAnimations() {
        guard !reduceMotion else {
            // Reduce Motion: present the fully-bloomed peak state
            // statically. User still sees the coral flower — just no spin.
            petalScale = 1
            breath = 1
            nexusPulse = 1
            dotBrightness = 0.40
            rotation = 0
            return
        }

        // Continuous rotation — starts immediately, never stops. ~10s/rev
        // gives a meditative orbit that doesn't compete with the bloom.
        withAnimation(.linear(duration: 10.0).repeatForever(autoreverses: false)) {
            rotation = 360
        }

        // Bud — vertex dots ignite bright coral in the first 0.15s.
        withAnimation(.easeOut(duration: 0.15)) {
            dotBrightness = 1.0
        }

        // Bloom — petals grow in place from 0 radius to full radius over
        // ~0.85s. EaseOut gives a gentle arrival rather than a mechanical
        // sweep.
        withAnimation(.easeOut(duration: 0.85).delay(0.15)) {
            petalScale = 1
        }

        // After the petals reach full size, let the dot glow recede to a
        // subtle anchor brightness.
        withAnimation(.easeInOut(duration: 0.60).delay(0.80)) {
            dotBrightness = 0.40
        }

        // Breath — subtle inhale/exhale on petals + guide ring.
        withAnimation(
            .easeInOut(duration: 2.0)
                .repeatForever(autoreverses: true)
                .delay(0.30)
        ) {
            breath = 1
        }

        // Nexus heartbeat — faster than the breath so the center doesn't
        // lock-step with the petal glow.
        withAnimation(
            .easeInOut(duration: 1.1)
                .repeatForever(autoreverses: true)
        ) {
            nexusPulse = 1
        }
    }
}

// MARK: - Seed of Life shape

/// Seed of Life petals that grow **in place** from zero radius → full
/// petal radius, with petal centers fixed on the vertex ring.
///
/// Each petal grows outward from its own center — there is no sliding
/// or translation motion. Combined with the 6-fold symmetry and the
/// matching bounding-ring radius described in `FormatterVisualView`,
/// this makes the cross-fade from the `.processing` Merkaba feel like
/// the six vertex lights re-composed themselves into six coral petals.
private struct SeedOfLifeGrowingPetals: Shape {
    /// 0 = petals are invisible points, 1 = full Seed of Life.
    var petalScale: CGFloat

    var animatableData: CGFloat {
        get { petalScale }
        set { petalScale = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // In a true Seed of Life each petal's radius equals the distance
        // from the origin to its center — petals touch their neighbors at
        // the origin. We scale only the petal radius; the center offset
        // stays fixed so the bloom happens in place.
        let fullPetalRadius = rect.width * 0.22
        let ringOffset = rect.width * 0.22
        let petalRadius = fullPetalRadius * petalScale
        guard petalRadius > 0.01 else { return path }
        for i in 0..<6 {
            let angle = (Double(i) * 60.0 - 90.0) * .pi / 180.0
            let cx = center.x + CGFloat(Foundation.cos(angle)) * ringOffset
            let cy = center.y + CGFloat(Foundation.sin(angle)) * ringOffset
            let petalRect = CGRect(
                x: cx - petalRadius,
                y: cy - petalRadius,
                width: petalRadius * 2,
                height: petalRadius * 2
            )
            path.addEllipse(in: petalRect)
        }
        return path
    }
}

// MARK: - Preview

#Preview("Formatter refining visual") {
    VStack(spacing: 20) {
        FormatterVisualView()
            .padding(10)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.85))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            )

        Text("FormatterVisualView — `.formatting` beat")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
    .padding(30)
    .frame(width: 280)
    .background(Color.gray.opacity(0.25))
}
