import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Capture tile for meeting recording, rendered below the YouTube + File
/// drop cards on the Transcribe tab. Mirrors the floating recording pill's
/// visual language (flower-of-life rosette + stem + leaves) at a larger
/// scale, on a light surface. The tile body is informational; only the
/// Start / Stop buttons fire the action. Mirrors the sibling YouTube
/// card's "click the button, not the body" pattern, and gives Start and
/// Stop symmetric tap targets so users learn one rule.
struct MeetingRecordingTile: View {
    enum PermissionState: Equatable {
        case ready(capturesMicrophone: Bool)
        case missing(microphone: Bool, screenRecording: Bool)

        init(
            microphoneGranted: Bool,
            screenRecordingGranted: Bool,
            sourceMode: MeetingAudioSourceMode
        ) {
            let needsMicrophone = sourceMode.capturesMicrophone && !microphoneGranted
            let needsScreenRecording = !screenRecordingGranted
            if needsMicrophone || needsScreenRecording {
                self = .missing(microphone: needsMicrophone, screenRecording: needsScreenRecording)
            } else {
                self = .ready(capturesMicrophone: sourceMode.capturesMicrophone)
            }
        }

        var isReady: Bool {
            if case .ready = self {
                return true
            }
            return false
        }

        var title: String {
            switch self {
            case .ready:
                return "Record a meeting"
            case .missing:
                return "Enable meeting recording"
            }
        }

        var detail: String {
            switch self {
            case .ready(let capturesMicrophone):
                return capturesMicrophone
                    ? "Transcribes the whole conversation, privately on your Mac."
                    : "Transcribes the call audio, privately on your Mac."
            case .missing(let microphone, let screenRecording):
                switch (microphone, screenRecording) {
                case (true, true):
                    return "Grant microphone and Screen & System Audio Recording access."
                case (true, false):
                    return "Grant microphone access to capture your voice."
                case (false, true):
                    return "Grant Screen & System Audio Recording access for meeting audio."
                case (false, false):
                    return "Ready to record meetings."
                }
            }
        }
    }

    @Bindable var viewModel: MeetingRecordingPillViewModel
    var permissionState: PermissionState = .ready(capturesMicrophone: true)
    var onTap: () -> Void
    /// Optional pause/resume handler. When `nil` the tile renders no pause
    /// control — keeps existing call sites unchanged.
    var onPauseToggle: (() -> Void)?

    var body: some View {
        tileSurface
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)
    }

    private var tileSurface: some View {
        ZStack {
            background
            content
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.md)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
    }

    // MARK: - Background

    private var background: some View {
        RoundedRectangle(cornerRadius: DesignSystem.Layout.dropZoneCornerRadius)
            .fill(DesignSystem.Colors.surfaceElevated)
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.dropZoneCornerRadius)
                    .strokeBorder(borderColor, lineWidth: 0.6)
            )
            .cardShadow(DesignSystem.Shadows.cardRest)
    }

    private var borderColor: Color {
        switch viewModel.state {
        case .recording:
            return DesignSystem.Colors.recordingRed.opacity(0.30)
        case .paused:
            return DesignSystem.Colors.border.opacity(0.85)
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
        case .recording, .paused:
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
            if permissionState.isReady {
                SacredFlowerTile(audioLevel: 0)
            } else {
                permissionIcon
                    .frame(width: 64)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(permissionState.title)
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(permissionState.detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            StartRecordingButton(permissionState: permissionState, onTap: onTap)
        }
    }

    private var recordingContent: some View {
        let isPaused = viewModel.isPaused
        return HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                SacredFlowerTile(
                    audioLevel: isPaused ? 0 : max(viewModel.micLevel, viewModel.systemLevel)
                )
                .opacity(isPaused ? 0.45 : 1.0)
                // Transient (value-keyed on a pause flip) — fires only on
                // pause/resume, not continuously, so it costs nothing at rest
                // and keeps the dim/undim a fade rather than a snap.
                .animation(.easeInOut(duration: 0.25), value: isPaused)

                if isPaused {
                    // Match the pill's pause-bars overlay so the two
                    // surfaces communicate the paused state at a glance.
                    HStack(spacing: 4) {
                        Capsule()
                            .fill(DesignSystem.Colors.textSecondary)
                            .frame(width: 4, height: 14)
                        Capsule()
                            .fill(DesignSystem.Colors.textSecondary)
                            .frame(width: 4, height: 14)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isPaused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DesignSystem.Colors.textTertiary)
                    } else {
                        BreathingDot()
                    }
                    Text(isPaused ? "Paused" : "Recording")
                        .font(DesignSystem.Typography.sectionTitle)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }
                Text(viewModel.formattedElapsed)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    // Rolling-digit timer. Transient (value-keyed on the 1 s
                    // elapsed tick), so it animates the digit change without any
                    // continuous animation.
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: viewModel.elapsedSeconds)
            }

            Spacer()

            HStack(spacing: 8) {
                if let onPauseToggle, viewModel.canTogglePause {
                    TilePauseResumeButton(isPaused: isPaused, onToggle: onPauseToggle)
                }
                stopButton
            }
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
        // No manual dismiss button: the flow coordinator auto-dismisses the
        // error state via its `startAutoDismissTimer` action and resets the
        // pill view model to `.idle` on `.hidePill`. A view-side state mutation
        // would bypass that machine and leave the coordinator in `.finishing`,
        // making the tile look ready while a tap is a silent no-op until the
        // timer expires. The floating pill follows the same convention.
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
        }
    }

    // MARK: - Action Buttons

    private var permissionIcon: some View {
        ZStack {
            Circle()
                .fill(DesignSystem.Colors.warningAmber.opacity(0.14))
                .frame(width: 56, height: 56)
            Image(systemName: "lock.shield")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.warningAmber)
        }
    }

    private var stopButton: some View {
        StopConfirmCapsule(onStop: onTap)
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        switch viewModel.state {
        case .idle:
            return permissionState.isReady ? "Record meeting" : "\(permissionState.title): \(permissionState.detail)"
        case .recording:
            return "Recording meeting, \(viewModel.formattedElapsed) elapsed"
        case .paused:
            return "Meeting recording paused, \(viewModel.formattedElapsed) elapsed"
        case .completing, .transcribing:
            return "Transcribing meeting"
        case .completed:
            return "Meeting saved"
        case .error(let message):
            return "Recording failed: \(message)"
        }
    }

    private var accessibilityHint: String {
        // Tile body is informational; Start / Stop buttons carry the
        // action hints themselves.
        ""
    }
}

// MARK: - Start / Enable button

/// The tile's primary record control. Idle reads as a soft outline-tinted
/// capsule — red when ready to record, amber when permissions are still
/// missing. On hover it commits to a solid capsule with a white glyph + label
/// and lifts `1.03`: the same outline→fill polish the co-visible "Browse Files"
/// button uses, paired with the same lift the sibling `TilePauseResumeButton`
/// and `StopConfirmCapsule` use — so the whole capture surface answers the
/// cursor in one voice. The solid-red hover also pre-echoes the recording-state
/// Stop pill, reinforcing that this is the record control.
private struct StartRecordingButton: View {
    var permissionState: MeetingRecordingTile.PermissionState
    var onTap: () -> Void

    @State private var isHovered = false

    private var accent: Color {
        permissionState.isReady
            ? DesignSystem.Colors.recordingRed
            : DesignSystem.Colors.warningAmber
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: permissionState.isReady ? "record.circle.fill" : "lock.open")
                    .font(.system(size: 11, weight: .semibold))
                Text(permissionState.isReady ? "Start" : "Enable")
                    .font(DesignSystem.Typography.caption.weight(.semibold))
            }
            .foregroundStyle(isHovered ? Color.white : accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isHovered ? accent : accent.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .strokeBorder(accent.opacity(isHovered ? 0 : 0.22), lineWidth: 0.8)
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel(permissionState.isReady ? "Start recording" : "Enable meeting recording")
        .accessibilityHint(permissionState.isReady
            ? "Captures system audio and microphone, then transcribes locally."
            : "Opens the required macOS permission flow before recording.")
    }
}

// MARK: - Pause / Resume button (issue #235)

/// Tile-styled pause/resume button. Single-click toggle (no countdown — pause
/// is recoverable). Sits to the left of the red Stop pill so the row reads
/// "pause | stop" — the recoverable action first, the destructive action
/// last. Outline-style (not filled) to keep stop the visual emphasis.
///
/// Hover lights up `warningAmber` (glyph + label + capsule tint + stroke) so
/// the tile button speaks the same color language as the panel header
/// `PauseResumeButton`. Idle stays neutral so the row doesn't shout while at
/// rest; the amber only declares intent on cursor approach.
private struct TilePauseResumeButton: View {
    var isPaused: Bool
    var onToggle: () -> Void

    @State private var isHovered = false

    private var idleForeground: Color {
        // Resume affordance is one notch brighter than pause to pull the eye
        // back once the user has paused — same rationale as the panel
        // PauseResumeButton.
        isPaused
            ? DesignSystem.Colors.textPrimary.opacity(0.85)
            : DesignSystem.Colors.textSecondary
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(isPaused ? "Resume" : "Pause")
                    .font(DesignSystem.Typography.caption.weight(.semibold))
            }
            .foregroundStyle(
                isHovered
                    ? DesignSystem.Colors.warningAmber
                    : idleForeground
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isHovered
                        ? DesignSystem.Colors.warningAmber.opacity(0.12)
                        : DesignSystem.Colors.surfaceElevated.opacity(0.7))
                    .overlay(
                        Capsule()
                            .stroke(
                                isHovered
                                    ? DesignSystem.Colors.warningAmber.opacity(0.45)
                                    : DesignSystem.Colors.border.opacity(0.7),
                                lineWidth: 0.6
                            )
                    )
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(
            isPaused
                ? "Resume recording"
                : "Pause recording — audio resumes when you click play"
        )
        .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
    }
}

// MARK: - Stop Confirm Capsule (two-step end)

/// Two-step end button. First click expands the red capsule into "End now"
/// with a 3-second countdown drain; second click stops the recording.
/// Reverts to "Stop" if no second click. Mirrors the floating pill's
/// `StopRecordingButton` confirm UX with polish tuned for the larger,
/// light-surface tile (white-on-red filled capsule rather than the pill's
/// red-on-dark outline style).
private struct StopConfirmCapsule: View {
    var onStop: () -> Void

    @State private var confirming = false
    @State private var countdownProgress: CGFloat = 1.0
    @State private var revertTask: Task<Void, Never>?
    @State private var isHovered = false

    var body: some View {
        Group {
            if confirming {
                Button(action: confirm) {
                    Text("End now")
                        .font(DesignSystem.Typography.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(DesignSystem.Colors.errorRed))
                        .overlay(
                            Capsule().stroke(.white.opacity(0.35), lineWidth: 0.6)
                        )
                        // Countdown strip: thin 2pt bar at the bottom that
                        // drains right→left over 3s. Lives inside the capsule
                        // padding so it doesn't bleed into the rounded corners.
                        .overlay(alignment: .bottom) {
                            GeometryReader { geo in
                                Capsule()
                                    .fill(.white.opacity(0.55))
                                    .frame(width: geo.size.width * countdownProgress, height: 2)
                            }
                            .frame(height: 2)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 4)
                        }
                }
                .buttonStyle(.plain)
                .help("End recording now")
                .accessibilityLabel("Confirm end recording")
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
                Button(action: beginConfirmation) {
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
                    .background(Capsule().fill(DesignSystem.Colors.recordingRed))
                    .scaleEffect(isHovered ? 1.03 : 1.0)
                    .animation(.easeOut(duration: 0.15), value: isHovered)
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .help("Stop recording")
                .accessibilityLabel("Stop recording")
                .accessibilityHint("Asks for confirmation, then ends the recording.")
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .onDisappear { revertTask?.cancel() }
    }

    private func beginConfirmation() {
        countdownProgress = 1.0
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            confirming = true
        }
        withAnimation(.linear(duration: 3)) {
            countdownProgress = 0
        }
        revertTask?.cancel()
        revertTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                confirming = false
            }
        }
    }

    private func confirm() {
        revertTask?.cancel()
        confirming = false
        onStop()
    }
}

// MARK: - Sacred Flower Glyph (tile-scale)

/// Larger, light-surface variant of the flower-of-life rosette + stem + leaves
/// motif used by the floating recording pill. Sized for the Transcribe tile
/// (50pt head + short stem). Greens-on-light replaces the pill's white-on-black.
///
/// Rendered statically. The tile lives in the always-resident main window, and
/// an animated SwiftUI rosette here (a `repeatForever` rotation/sway) drove
/// continuous `NSHostingView` re-layout — a measured contributor to the
/// v0.6.14 meeting-recording CPU regression. The audio-reactive glow is the
/// only live element, and it changes at most once per second (the pill poll is
/// quantized upstream). See `plans/active/2026-05-meeting-recording-cpu-debug.md`.
private struct SacredFlowerTile: View {
    /// Drives only the glow intensity; the rosette geometry is static.
    var audioLevel: Float

    private let headSize: CGFloat = 50
    private let stemHeight: CGFloat = 18

    private var glowOpacity: Double {
        let audioBoost = Double(audioLevel) * 0.45
        return min(0.85, 0.22 + audioBoost)
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
        // The tile shares the pill view-model, whose levels are sampled by the
        // 1 s state poll (not the pill/panel fast loop). Ease each step so the
        // glow breathes toward the new level instead of snapping once a second.
        // Transient (value-scoped) — no continuous animation, so it doesn't
        // reintroduce the resident-window render churn this PR removed.
        .animation(.easeOut(duration: 0.5), value: audioLevel)
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
        }
    }

    private var stemAndLeaves: some View {
        let stemColor = DesignSystem.Colors.sacredStem
        let swayOffset: CGFloat = 0

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
}

// MARK: - Recording dot (gentle breathing)

private struct BreathingDot: View {
    var body: some View {
        Circle()
            .fill(DesignSystem.Colors.recordingRed)
            .frame(width: 8, height: 8)
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
