import SwiftUI

/// A premium streaming indicator that shows animated dots with a warm shimmer.
/// Used during LLM summary generation and chat response streaming.
struct AIStreamingIndicator: View {
    @State private var activeIndex: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(DesignSystem.Colors.accent)
                    .frame(width: 5, height: 5)
                    .opacity(index == activeIndex ? 1.0 : 0.3)
                    .scaleEffect(index == activeIndex ? 1.0 : 0.7)
                    .animation(.easeInOut(duration: 0.3), value: activeIndex)
            }
        }
        .onReceive(timer) { _ in
            activeIndex = (activeIndex + 1) % 3
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
        VStack(spacing: DesignSystem.Spacing.lg) {
            MeditativeMerkabaView(
                size: 96,
                revolutionDuration: 4.0,
                tintColor: DesignSystem.Colors.accent
            )

            VStack(spacing: DesignSystem.Spacing.xs) {
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

/// A light sweep loading indicator for chat — an intense white light
/// that moves left to right on infinite repeat. No merkaba inside.
struct ChatLoadingSweep: View {
    @State private var phase: CGFloat = -0.3

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.4))
            .frame(width: 120, height: 8)
            .overlay(
                GeometryReader { geo in
                    let sweepWidth = geo.size.width * 0.4
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .white.opacity(0.7), location: 0.4),
                                    .init(color: .white.opacity(0.9), location: 0.5),
                                    .init(color: .white.opacity(0.7), location: 0.6),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: sweepWidth)
                        .offset(x: phase * (geo.size.width + sweepWidth) - sweepWidth / 2)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.vertical, 12)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1.3
                }
            }
    }
}
