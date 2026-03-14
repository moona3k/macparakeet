import SwiftUI

/// A sentient streaming indicator — three orbs that breathe with overlapping
/// phases, each with a soft glow halo. Slow, organic, alive.
struct AIStreamingIndicator: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = sin(t * 1.3 + Double(i) * 0.85)
                    let intensity = 0.3 + 0.7 * ((phase + 1) / 2)
                    let scale = 0.75 + 0.25 * ((phase + 1) / 2)

                    Circle()
                        .fill(DesignSystem.Colors.accent)
                        .frame(width: 5, height: 5)
                        .scaleEffect(scale)
                        .opacity(intensity)
                        .background(
                            Circle()
                                .fill(DesignSystem.Colors.accent)
                                .frame(width: 12, height: 12)
                                .blur(radius: 4)
                                .opacity(intensity * 0.4)
                        )
                }
            }
        }
    }
}

/// A shimmer overlay for skeleton loading states.
/// Draws a subtle gradient that sweeps across the content.
struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: max(0, phase - 0.3)),
                        .init(color: DesignSystem.Colors.accent.opacity(0.08), location: phase),
                        .init(color: .clear, location: min(1, phase + 0.3)),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .clipped()
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerEffect())
    }
}

/// Merkaba-centered skeleton for the summary loading state.
/// Shows a meditative merkaba spinner with subtle status text.
struct SummarySkeletonView: View {
    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            MeditativeMerkabaView(
                size: 96,
                revolutionDuration: 4.0,
                tintColor: DesignSystem.Colors.accent
            )

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("Generating summary")
                    .font(DesignSystem.Typography.bodySmall.weight(.medium))
                    .foregroundStyle(.secondary)

                AIStreamingIndicator()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DesignSystem.Spacing.xl)
    }
}

/// Placeholder view for empty chat assistant messages during streaming.
/// Shows a compact merkaba spinner with streaming dots.
struct ChatStreamingPlaceholder: View {
    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            SpinnerRingView(
                size: 22,
                revolutionDuration: 3.0,
                tintColor: DesignSystem.Colors.accent
            )
            AIStreamingIndicator()
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }
}

/// A slow, intense light sweep loading indicator for chat.
/// A prismatic light beam drifts left-to-right with a shifting warm hue,
/// trailing a soft glow. Wider track, slow-motion pace.
struct ChatLoadingSweep: View {
    @State private var phase: CGFloat = -0.2
    @State private var hueRotation: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.25))
            .frame(maxWidth: .infinity)
            .frame(height: 6)
            .overlay(
                GeometryReader { geo in
                    let beamWidth = geo.size.width * 0.6
                    let offsetX = phase * (geo.size.width + beamWidth) - beamWidth * 0.3

                    // Core light beam — warm white shifting through accent hues
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .white.opacity(0.15), location: 0.1),
                                    .init(color: DesignSystem.Colors.accent.opacity(0.5), location: 0.3),
                                    .init(color: .white.opacity(0.95), location: 0.5),
                                    .init(color: DesignSystem.Colors.accent.opacity(0.5), location: 0.7),
                                    .init(color: .white.opacity(0.15), location: 0.9),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: beamWidth, height: geo.size.height)
                        .hueRotation(.degrees(hueRotation))
                        .blur(radius: 1)
                        .offset(x: offsetX)

                    // Bright leading-edge spark
                    Circle()
                        .fill(.white.opacity(0.9))
                        .frame(width: 4, height: 4)
                        .blur(radius: 2)
                        .offset(
                            x: offsetX + beamWidth * 0.72,
                            y: (geo.size.height - 4) / 2
                        )
                }
            )
            .clipShape(Capsule())
            .padding(.vertical, 14)
            .onAppear {
                withAnimation(.linear(duration: 6.0).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
                withAnimation(.linear(duration: 6.0).repeatForever(autoreverses: false)) {
                    hueRotation = 360
                }
            }
    }
}
