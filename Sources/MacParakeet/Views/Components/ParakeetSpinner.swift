import SwiftUI

/// App-wide indeterminate loading spinner.
///
/// Wraps the existing compact Merkaba loader so new waiting states inherit the
/// same sacred-geometry motion language as the dictation overlay, meeting pill,
/// and Transform progress surfaces.
struct ParakeetSpinner: View {
    enum SizePreset {
        case inline
        case card
        case hero

        var points: CGFloat {
            switch self {
            case .inline: return 14
            case .card: return 40
            case .hero: return 72
            }
        }

        var revolutionDuration: Double {
            switch self {
            case .inline: return 2.0
            case .card: return 2.5
            case .hero: return 3.0
            }
        }
    }

    private let size: SizePreset
    private let tint: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ size: SizePreset = .inline, tint: Color? = nil) {
        self.size = size
        self.tint = tint
    }

    init(size: SizePreset, tint: Color? = nil) {
        self.init(size, tint: tint)
    }

    private var resolvedTint: Color {
        if let tint {
            return tint
        }

        switch size {
        case .inline:
            return DesignSystem.Colors.textSecondary
        case .card, .hero:
            return DesignSystem.Colors.accent
        }
    }

    private var shouldAnimate: Bool {
        guard !reduceMotion else { return false }
        switch size {
        case .inline:
            // Inline spinners sit inside list rows and other deep view trees.
            // Keep the Merkaba identity but avoid repeat-forever invalidation
            // driving whole-window layout and accessibility updates.
            return false
        case .card, .hero:
            return true
        }
    }

    var body: some View {
        SpinnerRingView(
            size: size.points,
            revolutionDuration: size.revolutionDuration,
            tintColor: resolvedTint,
            animate: shouldAnimate
        )
        .frame(width: size.points, height: size.points)
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}
