import SwiftUI

/// Ensō-inspired dual audio indicator.
/// An outer ring breathes with system audio; a center dot pulses with mic level.
/// Subtle glow creates a living, zen quality at compact size.
struct DualAudioOrbView: View {
    var micLevel: Float
    var systemLevel: Float

    private let size: CGFloat = 20

    var body: some View {
        let micClamped = Double(max(0, min(1, micLevel)))
        let sysClamped = Double(max(0, min(1, systemLevel)))

        ZStack {
            // System audio — outer ensō ring with glow
            Circle()
                .stroke(
                    DesignSystem.Colors.speakerColor(for: 0)
                        .opacity(0.2 + sysClamped * 0.65),
                    lineWidth: 1.5
                )
                .frame(width: size, height: size)
                .scaleEffect(1.0 + CGFloat(sysClamped) * 0.1)
                .shadow(
                    color: DesignSystem.Colors.speakerColor(for: 0)
                        .opacity(sysClamped * 0.4),
                    radius: CGFloat(sysClamped) * 4
                )

            // Mic — center dot with glow
            Circle()
                .fill(
                    DesignSystem.Colors.accent
                        .opacity(0.25 + micClamped * 0.65)
                )
                .frame(width: size * 0.32, height: size * 0.32)
                .scaleEffect(1.0 + CGFloat(micClamped) * 0.25)
                .shadow(
                    color: DesignSystem.Colors.accent
                        .opacity(micClamped * 0.5),
                    radius: CGFloat(micClamped) * 3
                )
        }
        .frame(width: size + 6, height: size + 6)
        .animation(.easeOut(duration: 0.12), value: micLevel)
        .animation(.easeOut(duration: 0.12), value: systemLevel)
    }
}
