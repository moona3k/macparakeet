import SwiftUI

/// 14-bar waveform visualization driven by audio level.
/// Thin, airy bars with subtle opacity — premium feel without visual weight.
struct WaveformView: View {
    let audioLevel: Float
    var barCount: Int = 14

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.8))
                    .frame(width: 2, height: barHeight(for: index))
            }
        }
        .frame(height: 20)
    }

    /// Calculate bar height with center-peaking wave pattern
    private func barHeight(for index: Int) -> CGFloat {
        let center = Float(barCount) / 2.0
        let distance = abs(Float(index) - center) / center
        let baseHeight: Float = 4.0
        let maxAdditional: Float = 16.0

        // Amplify audio level — raw mic levels are typically 0.0-0.3 for speech,
        // so we boost by 3x and clamp to make the waveform visually responsive.
        let boosted = min(audioLevel * 3.0, 1.0)

        // Center bars are taller, edge bars shorter
        let peakFactor = 1.0 - (distance * 0.6)
        let level = boosted * peakFactor
        let height = baseHeight + (maxAdditional * level)

        return CGFloat(max(baseHeight, min(height, 20)))
    }
}

#Preview {
    VStack(spacing: 20) {
        WaveformView(audioLevel: 0.0)
        WaveformView(audioLevel: 0.3)
        WaveformView(audioLevel: 0.6)
        WaveformView(audioLevel: 1.0)
    }
    .padding()
    .background(Color.black)
}
