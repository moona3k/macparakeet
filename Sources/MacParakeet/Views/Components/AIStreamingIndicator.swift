import SwiftUI

/// A premium streaming indicator that shows animated dots with a warm shimmer.
/// Used during LLM summary generation and chat response streaming.
struct AIStreamingIndicator: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(DesignSystem.Colors.accent)
                    .frame(width: 5, height: 5)
                    .opacity(dotOpacity(for: index))
                    .scaleEffect(dotScale(for: index))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    private func dotOpacity(for index: Int) -> Double {
        let offset = Double(index) * 0.25
        let value = sin((phase + offset) * .pi * 2)
        return 0.3 + 0.7 * max(0, value)
    }

    private func dotScale(for index: Int) -> Double {
        let offset = Double(index) * 0.25
        let value = sin((phase + offset) * .pi * 2)
        return 0.7 + 0.3 * max(0, value)
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
                size: 56,
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
