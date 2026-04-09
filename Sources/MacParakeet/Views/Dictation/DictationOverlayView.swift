import MacParakeetCore
import SwiftUI

// MARK: - Animated Checkmark

/// Apple-style success checkmark: thin ring draws, then thin check strokes in.
/// Inspired by Apple Pay / Activity completion — confidence through restraint.
private struct AnimatedCheckmarkView: View {
    @State private var ringTrim: CGFloat = 0
    @State private var checkTrim: CGFloat = 0

    private let lineWidth: CGFloat = 1.5
    private let color = DesignSystem.Colors.successGreen

    var body: some View {
        ZStack {
            // Background ring (faint guide)
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)

            // Animated ring
            Circle()
                .trim(from: 0, to: ringTrim)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Checkmark
            CheckmarkShape()
                .trim(from: 0, to: checkTrim)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .padding(7)
        }
        .frame(width: 26, height: 26)
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) {
                ringTrim = 1
            }
            withAnimation(.easeOut(duration: 0.25).delay(0.25)) {
                checkTrim = 1
            }
        }
    }
}

/// Checkmark path shape
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: w * 0.22, y: h * 0.52))
        path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.72))
        path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.28))
        return path
    }
}

// MARK: - No Speech Content

/// No-speech terminal animation: Merkaba dissolves → falling leaf + serif label.
/// Self-contained @State so nothing leaks across dictation sessions.
/// Sized to 26×26 to match the success/processing circular pill.
private struct NoSpeechContentView: View {
    let isCommand: Bool

    @State private var leafVisible: Double = 0
    @State private var leafDrift: CGFloat = -4
    @State private var leafRotation: Double = -18
    @State private var textOpacity: Double = 0

    private var label: String {
        isCommand ? "no command" : "no audio"
    }

    var body: some View {
        ZStack {
            // Sacred geometry dissolves (matches SpinnerRingView default size: 26)
            MerkabaDissipateView(size: 26)

            // Leaf drifts in as geometry fades — warm coral-orange (parakeet plumage)
            Image(systemName: "leaf.fill")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(DesignSystem.Colors.accent.opacity(leafVisible))
                .rotationEffect(.degrees(leafRotation))
                .offset(x: leafDrift * 0.5, y: leafDrift)

            // Elegant serif italic label — overflows the 26×26 frame into pill padding,
            // so the pill background (46×46) can accommodate the text without resizing.
            // For command mode ("no command"), the pill is allowed to grow into an oval
            // via isIconOnly=false so the longer label is not clipped (see overlayContent).
            Text(label)
                .font(DesignSystem.Typography.dictationOverlayTerminalLabel)
                .foregroundStyle(.white.opacity(textOpacity))
                .fixedSize()
        }
        .frame(width: 26, height: 26)
        .onAppear {
            // Reset to baseline so repeated presentations replay deterministically.
            leafVisible = 0
            leafDrift = -4
            leafRotation = -18
            textOpacity = 0

#if DEBUG
            assert(
                NoSpeechAnimationTiming.isDismissWindowSufficient,
                "No-speech animation (\(NoSpeechAnimationTiming.estimatedAnimationCompletionSeconds)s) must complete before dismiss (\(NoSpeechAnimationTiming.dismissSeconds)s)."
            )
#endif

            // Leaf fades in as Merkaba dissolves
            withAnimation(.easeIn(duration: NoSpeechAnimationTiming.leafFadeInDuration).delay(NoSpeechAnimationTiming.leafFadeInDelay)) {
                leafVisible = 0.7
            }
            // Leaf gently drifts down + rotates (falling)
            withAnimation(.easeInOut(duration: NoSpeechAnimationTiming.leafDriftDuration).delay(NoSpeechAnimationTiming.leafDriftDelay)) {
                leafDrift = 6
                leafRotation = 18
            }
            // Text fades in, anchored at center over the leaf
            withAnimation(.easeIn(duration: NoSpeechAnimationTiming.textFadeInDuration).delay(NoSpeechAnimationTiming.textFadeInDelay)) {
                textOpacity = 0.95
            }
            // Leaf softly recedes so text reads clean
            withAnimation(.easeOut(duration: NoSpeechAnimationTiming.leafRecedeDuration).delay(NoSpeechAnimationTiming.leafRecedeDelay)) {
                leafVisible = 0.3
            }
        }
    }
}

/// The dictation overlay — compact dark capsule during dictation, wider card for errors.
struct DictationOverlayView: View {
    @Bindable var viewModel: DictationOverlayViewModel

    /// Align tooltip above the hovered button: leading for cancel, trailing for stop.
    private var tooltipAlignment: Alignment {
        if isCancelHovered { return .leading }
        if isStopHovered { return .trailing }
        return .center
    }

    var body: some View {
        VStack(spacing: 4) {
            // Tooltip — changes per hovered element via NSTrackingArea
            tooltipLabel
                .frame(maxWidth: .infinity, alignment: tooltipAlignment)
                .padding(.horizontal, 30)
                .opacity(viewModel.isHovered && viewModel.hoverTooltip != nil ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: viewModel.isHovered)
                .animation(.easeInOut(duration: 0.1), value: viewModel.hoverTooltip)
                .frame(height: 36)

            // Content with state-appropriate shape
            overlayContent
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch viewModel.state {
        case .error(let message):
            errorCard(message: message)

        default:
            let isReady = if case .ready = viewModel.state { true } else { false }
            // Processing (non-command), success, and noSpeech (non-command) show a single
            // icon — use equal padding so the Capsule background renders as a perfect
            // circle, not an oval. In command mode, the no-speech label is "no command"
            // (10 chars) which overflows the 46×46 circular pill via fixedSize; fall back
            // to the oval layout so the label reads cleanly.
            let isIconOnly: Bool = {
                switch viewModel.state {
                case .processing: return viewModel.sessionKind != .command
                case .success: return true
                case .noSpeech: return viewModel.sessionKind != .command
                default: return false
                }
            }()
            pillContent
                .padding(.horizontal, isReady ? 6 : (isIconOnly ? 10 : 16))
                .padding(.vertical, isReady ? 4 : (isIconOnly ? 10 : 7))
                .background(
                    Capsule()
                        .fill(DesignSystem.Colors.pillBackground)
                        .overlay(
                            Capsule()
                                .strokeBorder(DesignSystem.Colors.pillBorder, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                )
                .animation(.easeInOut(duration: 0.25), value: viewModel.pillStateKey)
        }
    }

    @ViewBuilder
    private var pillContent: some View {
        ZStack {
            switch viewModel.state {
            case .ready:
                readyContent
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))

            case .recording:
                Group {
                    if viewModel.sessionKind == .command {
                        commandRecordingContent
                    } else if viewModel.recordingMode == .holdToTalk {
                        holdToTalkContent
                    } else {
                        recordingContent
                    }
                }
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))

            case .cancelled:
                cancelledContent
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))

            case .processing:
                processingContent
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))

            case .success:
                successContent
                    .transition(.scale(scale: 0.8).combined(with: .opacity).animation(.spring(response: 0.35, dampingFraction: 0.7)))

            case .noSpeech:
                noSpeechContent
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))

            case .error:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.pillStateKey)
    }

    // MARK: - Ready State

    private var readyContent: some View {
        WaveformView(audioLevel: 0.15, barCount: 8)
            .frame(width: 44, height: 14)
    }

    // MARK: - Hold-to-Talk State

    /// Red dot + timer + waveform — no buttons needed since releasing Fn stops recording.
    private var holdToTalkContent: some View {
        HStack(spacing: 12) {
            // Recording indicator dot
            Circle()
                .fill(DesignSystem.Colors.recordingRed)
                .frame(width: 5, height: 5)

            // Recording timer
            Text(viewModel.formattedElapsed)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 36)

            // Waveform
            WaveformView(audioLevel: viewModel.audioLevel)
                .frame(width: 64)
        }
    }

    // MARK: - Recording State (Persistent)

    private var isCancelHovered: Bool {
        viewModel.hoverTooltip?.contains("Cancel") == true
    }

    private var isStopHovered: Bool {
        viewModel.hoverTooltip?.contains("Stop") == true
    }

    private var recordingContent: some View {
        HStack(spacing: 12) {
            // Cancel button
            Button(action: { viewModel.onCancel?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(isCancelHovered ? 1.0 : 0.9))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(isCancelHovered ? 0.35 : 0.2)))
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.15), value: isCancelHovered)

            // Recording timer
            Text(viewModel.formattedElapsed)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 36)

            // Waveform
            WaveformView(audioLevel: viewModel.audioLevel)
                .frame(width: 64)

            // Stop button
            Button(action: { viewModel.onStop?() }) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .padding(7)
                    .background(
                        Circle().fill(isStopHovered ? Color.red.opacity(1.0) : Color.red.opacity(0.85))
                            .shadow(color: isStopHovered ? .red.opacity(0.5) : .clear, radius: 6)
                    )
            }
            .buttonStyle(.plain)
            .scaleEffect(isStopHovered ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isStopHovered)
        }
    }

    private var commandRecordingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.commandPromptText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

            HStack(spacing: 4) {
                Text("Selected:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Text("\"\(viewModel.commandSelectedPreview)\"")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Text("(\(viewModel.commandSelectedCharacterCount)c)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            if viewModel.recordingMode == .holdToTalk {
                holdToTalkContent
            } else {
                recordingContent
            }
        }
    }

    // MARK: - Cancelled State

    private var cancelledContent: some View {
        HStack(spacing: 10) {
            // Countdown ring — implicit animation smoothly interpolates between 1s steps
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 1.5)
                    .frame(width: 24, height: 24)

                Circle()
                    .trim(from: 0, to: CGFloat(viewModel.cancelTimeRemaining / 5.0))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: viewModel.cancelTimeRemaining)

                Text("\(Int(ceil(viewModel.cancelTimeRemaining)))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .contentShape(Circle())
            .onTapGesture {
                // Confirm cancel immediately (matches spec: tap ring to discard now).
                viewModel.onCancel?()
            }

            // Undo button
            Button(action: { viewModel.onUndo?() }) {
                Text("Undo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Processing State

    private var processingContent: some View {
        if viewModel.sessionKind == .command {
            return AnyView(
                HStack(spacing: 8) {
                    SpinnerRingView()
                    Text("Applying command...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            )
        }
        // Circular spinner that matches the checkmark ring size for seamless morphing
        return AnyView(SpinnerRingView())
    }

    // MARK: - Success State

    private var successContent: some View {
        AnimatedCheckmarkView()
    }

    // MARK: - No Speech State

    private var noSpeechContent: some View {
        NoSpeechContentView(isCommand: viewModel.sessionKind == .command)
    }

    // MARK: - Error Card

    private func errorCard(message: String) -> some View {
        let info = errorInfo(message)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Icon in tinted circle
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.recordingRed.opacity(0.12))
                        .frame(width: 32, height: 32)

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignSystem.Colors.recordingRed)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(info.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(2)
                }
            }

            // Dismiss button
            HStack {
                Spacer()

                Button(action: { viewModel.onDismiss?() }) {
                    Text("Dismiss")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
        }
        .padding(16)
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.pillBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                        .strokeBorder(DesignSystem.Colors.pillBorder.opacity(0.5), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
    }

    /// Map technical error messages to user-friendly title + actionable subtitle
    private func errorInfo(_ message: String) -> (title: String, subtitle: String) {
        let lower = message.lowercased()

        if lower.contains("stt") || lower.contains("speech engine") || lower.contains("engine")
            || lower.contains("model not loaded")
            || lower.contains("failed to start") {
            return ("Speech Engine Not Ready", "Run onboarding or go to Settings > Speech Model > Repair.")
        }
        if lower.contains("couldn't hear") || lower.contains("empty")
            || lower.contains("too short") || lower.contains("insufficient") {
            return ("No Speech Detected", "Try speaking louder or holding a bit longer.")
        }
        if lower.contains("microphone") || lower.contains("audio input") {
            return ("Microphone Unavailable", "Check your mic connection or select a different input.")
        }
        if lower.contains("copied to clipboard") || lower.contains("cmd+v") {
            return ("Copied to Clipboard", "Auto-paste wasn't available. Press Cmd+V where you want the text.")
        }
        if lower.contains("permission") || lower.contains("access") {
            return ("Permission Required", "Grant access in System Settings > Privacy & Security.")
        }
        if lower.contains("not recording") {
            let trigger = HotkeyTrigger.current
            let hint = trigger.isDisabled
                ? "Click the dictation pill to start recording."
                : "Press \(trigger.displayName) to start recording first."
            return ("Not Recording", hint)
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return ("Transcription Timed Out", "Try a shorter recording or restart the app.")
        }
        if lower.contains("memory") || lower.contains("oom") {
            return ("Out of Memory", "Close other apps to free memory and try again.")
        }

        // Fallback: use the raw message as subtitle
        let title = "Something Went Wrong"
        let subtitle = message.count > 60 ? String(message.prefix(57)) + "..." : message
        return (title, subtitle)
    }

    /// Tooltip bubble with dark background — readable over any content
    @ViewBuilder
    private var tooltipLabel: some View {
        if let tooltip = viewModel.hoverTooltip {
            // Split into action text and key shortcut: "Cancel (Esc)" → "Cancel " + "Esc"
            Group {
                if let parenStart = tooltip.firstIndex(of: "("),
                   let parenEnd = tooltip.firstIndex(of: ")") {
                    let action = String(tooltip[tooltip.startIndex..<parenStart])
                    let key = String(tooltip[tooltip.index(after: parenStart)..<parenEnd])
                    HStack(spacing: 4) {
                        Text(action.trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(key)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(nsColor: NSColor(red: 0.85, green: 0.55, blue: 0.75, alpha: 1.0)))
                    }
                } else {
                    Text(tooltip)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.pillBackground)
                    .overlay(
                        Capsule()
                            .strokeBorder(DesignSystem.Colors.pillBorder.opacity(0.67), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            )
        }
    }

}

#Preview {
    VStack(spacing: 20) {
        DictationOverlayView(viewModel: {
            let vm = DictationOverlayViewModel()
            vm.state = .ready
            return vm
        }())

        DictationOverlayView(viewModel: {
            let vm = DictationOverlayViewModel()
            vm.state = .recording
            vm.audioLevel = 0.5
            return vm
        }())

        DictationOverlayView(viewModel: {
            let vm = DictationOverlayViewModel()
            vm.state = .cancelled(timeRemaining: 3.0)
            return vm
        }())

        DictationOverlayView(viewModel: {
            let vm = DictationOverlayViewModel()
            vm.state = .processing
            return vm
        }())

        DictationOverlayView(viewModel: {
            let vm = DictationOverlayViewModel()
            vm.state = .success
            return vm
        }())

        DictationOverlayView(viewModel: {
            let vm = DictationOverlayViewModel()
            vm.state = .noSpeech
            return vm
        }())

        DictationOverlayView(viewModel: {
            let vm = DictationOverlayViewModel()
            vm.state = .error("Failed to start speech engine: model not loaded")
            return vm
        }())

        DictationOverlayView(viewModel: {
            let vm = DictationOverlayViewModel()
            vm.state = .error("Microphone access denied")
            return vm
        }())
    }
    .padding(30)
    .background(Color.gray.opacity(0.3))
}
