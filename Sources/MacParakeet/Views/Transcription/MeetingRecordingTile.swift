import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Capture tile for meeting recording, rendered below the YouTube + File
/// drop cards on the Transcribe tab. Mirrors the floating recording pill's
/// visual language (flower-of-life rosette + stem + leaves) at a larger
/// scale, on a light surface. Tap toggles recording; the same callback the
/// menu bar uses.
struct MeetingRecordingTile: View {
    @Bindable var viewModel: MeetingRecordingPillViewModel
    var onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack {
            background
            content
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.md)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Layout.dropZoneCornerRadius))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onTap)
        .scaleEffect(isHovered && interactive ? 1.005 : 1.0)
        .animation(DesignSystem.Animation.hoverTransition, value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    // MARK: - Background

    private var background: some View {
        RoundedRectangle(cornerRadius: DesignSystem.Layout.dropZoneCornerRadius)
            .fill(DesignSystem.Colors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.dropZoneCornerRadius)
                    .strokeBorder(borderColor, lineWidth: 0.6)
            )
            .cardShadow(isHovered && interactive ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
            .animation(DesignSystem.Animation.hoverTransition, value: isHovered)
    }

    private var borderColor: Color {
        switch viewModel.state {
        case .recording:
            return DesignSystem.Colors.recordingRed.opacity(0.30)
        case .error:
            return DesignSystem.Colors.warningAmber.opacity(0.35)
        default:
            return DesignSystem.Colors.border.opacity(0.7)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            idleContent
        case .recording:
            recordingContent
        case .completing, .transcribing:
            transcribingContent
        case .completed:
            completedContent
        case .error(let message):
            errorContent(message: message)
        }
    }

    private var idleContent: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            SacredFlowerTile(isAnimating: false, audioLevel: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text("Record Meeting")
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Capture system audio + mic, transcribed locally.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            startButton
        }
    }

    private var recordingContent: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            SacredFlowerTile(
                isAnimating: true,
                audioLevel: max(viewModel.micLevel, viewModel.systemLevel)
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    BreathingDot()
                    Text("Recording")
                        .font(DesignSystem.Typography.sectionTitle)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }
                Text(viewModel.formattedElapsed)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: viewModel.elapsedSeconds)
            }

            Spacer()

            stopButton
        }
    }

    private var transcribingContent: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.sacredGlow.opacity(0.18))
                    .frame(width: 56, height: 56)
                SpinnerRingView(size: 30, revolutionDuration: 2.0, tintColor: DesignSystem.Colors.accent)
            }
            .frame(width: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.state == .completing ? "Wrapping up…" : "Transcribing…")
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Processing entirely on this Mac.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    private var completedContent: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.successGreen.opacity(0.14))
                    .frame(width: 56, height: 56)
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.successGreen)
            }
            .frame(width: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text("Saved to Library")
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Your meeting is ready.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    private func errorContent(message: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.warningAmber.opacity(0.14))
                    .frame(width: 56, height: 56)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
            }
            .frame(width: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text("Recording failed")
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(message)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                viewModel.state = .idle
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }

    // MARK: - Action Buttons

    private var startButton: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(DesignSystem.Colors.recordingRed)
                .frame(width: 8, height: 8)
            Text("Start")
                .font(DesignSystem.Typography.caption.weight(.semibold))
        }
        .foregroundStyle(DesignSystem.Colors.recordingRed)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(DesignSystem.Colors.recordingRed.opacity(isHovered ? 0.16 : 0.10))
        )
        .overlay(
            Capsule()
                .strokeBorder(DesignSystem.Colors.recordingRed.opacity(isHovered ? 0.34 : 0.22), lineWidth: 0.8)
        )
        .animation(DesignSystem.Animation.hoverTransition, value: isHovered)
    }

    private var stopButton: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 8, height: 8)
                Text("Stop")
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(DesignSystem.Colors.recordingRed)
            )
        }
        .buttonStyle(.plain)
        .help("Stop recording")
        .accessibilityLabel("Stop recording")
    }

    // MARK: - Interactivity

    private var interactive: Bool {
        switch viewModel.state {
        case .idle, .recording: return true
        case .completing, .transcribing, .completed, .error: return false
        }
    }

    private var accessibilityLabel: String {
        switch viewModel.state {
        case .idle:
            return "Record meeting"
        case .recording:
            return "Recording meeting, \(viewModel.formattedElapsed) elapsed"
        case .completing, .transcribing:
            return "Transcribing meeting"
        case .completed:
            return "Meeting saved"
        case .error(let message):
            return "Recording failed: \(message)"
        }
    }

    private var accessibilityHint: String {
        switch viewModel.state {
        case .idle: return "Captures system audio and microphone, then transcribes locally."
        case .recording: return "Stops the active recording and starts transcription."
        default: return ""
        }
    }
}

// MARK: - Sacred Flower Glyph (tile-scale)

/// Larger, light-surface variant of the flower-of-life rosette + stem + leaves
/// motif used by the floating recording pill. Sized for the Transcribe tile
/// (50pt head + short stem). Greens-on-light replaces the pill's white-on-black.
private struct SacredFlowerTile: View {
    var isAnimating: Bool
    var audioLevel: Float

    @State private var rotation: Double = 0
    @State private var sway: Double = -1
    @State private var idleBreath: Double = 0

    private let headSize: CGFloat = 50
    private let stemHeight: CGFloat = 18

    private var glowOpacity: Double {
        let base: Double = isAnimating ? 0.55 : (0.22 + idleBreath * 0.10)
        let audioBoost = Double(audioLevel) * 0.45
        return min(0.85, base + audioBoost)
    }

    var body: some View {
        VStack(spacing: 0) {
            flowerHead
                .frame(width: headSize, height: headSize)
            stemAndLeaves
                .frame(width: headSize * 0.55, height: stemHeight)
                .padding(.top, -2)
        }
        .frame(width: 64)
        .onChange(of: isAnimating) { _, animating in
            if animating { startActive() } else { stopActive() }
        }
        .onAppear {
            if isAnimating {
                startActive()
            } else {
                startIdleBreath()
            }
        }
    }

    private var flowerHead: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            DesignSystem.Colors.sacredGlow.opacity(glowOpacity),
                            DesignSystem.Colors.sacredGlow.opacity(glowOpacity * 0.30),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: headSize * 0.55
                    )
                )
                .frame(width: headSize * 0.86, height: headSize * 0.86)
                .animation(.easeOut(duration: 0.12), value: audioLevel)

            ZStack {
                Circle()
                    .stroke(DesignSystem.Colors.sacredStem.opacity(0.65), lineWidth: 1.0)
                    .frame(width: headSize * 0.46, height: headSize * 0.46)

                ForEach(0..<6, id: \.self) { index in
                    let angle = Double(index) * 60
                    let radians = angle * .pi / 180
                    let radius: CGFloat = headSize * 0.23

                    Circle()
                        .stroke(DesignSystem.Colors.sacredStem.opacity(0.50), lineWidth: 1.0)
                        .frame(width: headSize * 0.46, height: headSize * 0.46)
                        .offset(
                            x: radius * CGFloat(cos(radians)),
                            y: radius * CGFloat(sin(radians))
                        )
                }
            }
            .rotationEffect(.degrees(rotation))
        }
    }

    private var stemAndLeaves: some View {
        let stemColor = DesignSystem.Colors.sacredStem
        let swayOffset = CGFloat(sway) * 1.8

        return ZStack {
            TileStemShape(swayOffset: swayOffset)
                .stroke(stemColor.opacity(0.75), lineWidth: 1.4)

            TileLeafShape(
                basePoint: CGPoint(x: 0.5, y: 0.40),
                direction: .left,
                size: 11,
                swayOffset: swayOffset
            )
            .fill(stemColor.opacity(0.50))
            TileLeafShape(
                basePoint: CGPoint(x: 0.5, y: 0.40),
                direction: .left,
                size: 11,
                swayOffset: swayOffset
            )
            .stroke(stemColor.opacity(0.62), lineWidth: 0.6)

            TileLeafShape(
                basePoint: CGPoint(x: 0.5, y: 0.68),
                direction: .right,
                size: 12,
                swayOffset: swayOffset
            )
            .fill(stemColor.opacity(0.50))
            TileLeafShape(
                basePoint: CGPoint(x: 0.5, y: 0.68),
                direction: .right,
                size: 12,
                swayOffset: swayOffset
            )
            .stroke(stemColor.opacity(0.62), lineWidth: 0.6)
        }
    }

    private func startActive() {
        // Match the pill's 12s rotation for visual continuity.
        withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
            rotation = 360
        }
        withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
            sway = 1
        }
    }

    private func stopActive() {
        withAnimation(.easeOut(duration: 0.5)) {
            rotation = 0
            sway = 0
        }
        startIdleBreath()
    }

    private func startIdleBreath() {
        // Subtle 4s breathing on the glow when idle — present, not nagging.
        withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
            idleBreath = 1
        }
    }
}

// MARK: - Recording dot (gentle breathing)

private struct BreathingDot: View {
    @State private var pulse: Bool = false

    var body: some View {
        Circle()
            .fill(DesignSystem.Colors.recordingRed)
            .frame(width: 8, height: 8)
            .opacity(pulse ? 0.55 : 1.0)
            .scaleEffect(pulse ? 0.92 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - Stem and Leaf Shapes (tile-scale variants)

private struct TileStemShape: Shape {
    var swayOffset: CGFloat

    var animatableData: CGFloat {
        get { swayOffset }
        set { swayOffset = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let midX = rect.midX
        var path = Path()
        path.move(to: CGPoint(x: midX, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: midX + swayOffset * 0.35, y: rect.height),
            control: CGPoint(x: midX + swayOffset, y: rect.height * 0.5)
        )
        return path
    }
}

private struct TileLeafShape: Shape {
    enum Direction { case left, right }

    let basePoint: CGPoint
    let direction: Direction
    let size: CGFloat
    var swayOffset: CGFloat = 0

    var animatableData: CGFloat {
        get { swayOffset }
        set { swayOffset = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let base = CGPoint(
            x: rect.width * basePoint.x + swayOffset * basePoint.y,
            y: rect.height * basePoint.y
        )
        let sign: CGFloat = direction == .left ? -1 : 1

        var path = Path()
        path.move(to: base)
        path.addQuadCurve(
            to: CGPoint(x: base.x + sign * size, y: base.y - 4),
            control: CGPoint(x: base.x + sign * size * 0.6, y: base.y - 6)
        )
        path.addQuadCurve(
            to: base,
            control: CGPoint(x: base.x + sign * size * 0.6, y: base.y + 3)
        )
        return path
    }
}
