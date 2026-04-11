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

/// No-speech terminal animation: Merkaba dissolves inside a 46×46 circle, then
/// the pill expands horizontally as the falling leaf + serif label bloom in.
/// The `expanded` prop is driven by the parent so the pill's padding (circle ↔
/// oval) stays in sync with this view's internal leaf/text animations.
private struct NoSpeechContentView: View {
    let isCommand: Bool
    let expanded: Bool

    @State private var leafVisible: Double = 0
    @State private var leafDrift: CGFloat = -4
    @State private var leafRotation: Double = -18
    @State private var textOpacity: Double = 0

    private var label: String {
        isCommand ? "no command" : "more audio please"
    }

    var body: some View {
        HStack(spacing: expanded ? 4 : 0) {
            // Sacred geometry + falling leaf — dissolving Merkaba inside a fixed 26×26 box.
            ZStack {
                MerkabaDissipateView(size: 26)

                // Leaf drifts in as geometry fades — warm coral-orange (parakeet plumage).
                // Hidden in phase 0 (circular) and blooms in phase 1 (expanded oval).
                Image(systemName: "leaf.fill")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.accent.opacity(leafVisible))
                    .rotationEffect(.degrees(leafRotation))
                    .offset(x: leafDrift * 0.5, y: leafDrift)
            }
            .frame(width: 26, height: 26)

            // Elegant serif italic label — only present in the HStack once expanded,
            // using `.fixedSize()` for its natural intrinsic width. The parent's
            // `withAnimation` around the `noSpeechExpanded` flip smoothly animates
            // the HStack's size change as the text view appears.
            //
            // IMPORTANT: do not use `.frame(maxWidth: .infinity)` here — it propagates
            // up through the HStack → pill → overlay window and balloons the capsule
            // to full window width. `fixedSize()` alone gives the correct tight width.
            if expanded {
                Text(label)
                    .font(DesignSystem.Typography.dictationOverlayTerminalLabel)
                    .foregroundStyle(.white.opacity(textOpacity))
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .onChange(of: expanded) { _, isExpanded in
            guard isExpanded else { return }
            runBloomAnimations()
        }
    }

    /// Resets animation state and runs the leaf + text bloom sequence. Called when
    /// `expanded` flips to true (~0.4s after `.noSpeech` is entered, giving the
    /// circular Merkaba time to settle / dissolve first).
    private func runBloomAnimations() {
        #if DEBUG
        // Fail loudly in debug builds if someone shrinks the dismiss window below
        // what the animation phases need to complete. This is the actual guard
        // behind `NoSpeechAnimationTiming.isDismissWindowSufficient`.
        assert(
            NoSpeechAnimationTiming.isDismissWindowSufficient,
            "No-speech dismiss window (\(NoSpeechAnimationTiming.dismissSeconds)s) is too short for " +
            "estimated animation completion (\(NoSpeechAnimationTiming.estimatedAnimationCompletionSeconds)s) " +
            "+ buffer (\(NoSpeechAnimationTiming.completionBufferSeconds)s)."
        )
        #endif

        // Reset to baseline so repeated presentations replay deterministically.
        leafVisible = 0
        leafDrift = -4
        leafRotation = -18
        textOpacity = 0

        // Leaf fades in as Merkaba finishes dissolving
        withAnimation(.easeIn(duration: NoSpeechAnimationTiming.leafFadeInDuration)) {
            leafVisible = 0.7
        }
        // Leaf gently drifts down + rotates (falling)
        withAnimation(.easeInOut(duration: NoSpeechAnimationTiming.leafDriftDuration)) {
            leafDrift = 6
            leafRotation = 18
        }
        // Text fades in alongside the expansion
        withAnimation(.easeIn(duration: NoSpeechAnimationTiming.textFadeInDuration).delay(0.15)) {
            textOpacity = 0.95
        }
        // Leaf softly recedes so text reads clean
        withAnimation(.easeOut(duration: NoSpeechAnimationTiming.leafRecedeDuration).delay(NoSpeechAnimationTiming.leafRecedeDelay - NoSpeechAnimationTiming.leafFadeInDelay)) {
            leafVisible = 0.3
        }
    }
}

/// Slow horizontal drift of warm light across the no-speech pill — the polish
/// that accompanies the pill's farewell. Not a shimmer (that reads as sparkle
/// or loading). A wide, soft band of light pools on the left after the leaf
/// and label have settled, then drifts across the capsule at a contemplative
/// pace, exiting the right edge exactly as the dismiss timer fires. The light
/// completing its journey *is* the pill's goodbye — the motion and the
/// disappearance are the same gesture.
///
/// Timing constants live in `NoSpeechAnimationTiming` alongside the leaf and
/// Merkaba phases so the debug `isDismissWindowSufficient` assert covers them
/// and future edits stay coordinated. With today's values the drift ends at
/// ~2.1s after the oval expansion — exactly the 2.5s dismiss boundary once
/// the 0.4s expansion delay is accounted for.
private struct NoSpeechLightDrift: View {
    let active: Bool

    /// Normalized horizontal offset of the light band, expressed in multiples
    /// of the pill's width. `-1.2` parks it just off the left edge; `1.2`
    /// pushes it just off the right edge so it fully enters and exits.
    @State private var phase: CGFloat = -1.2

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0),    location: 0.20),
                    .init(color: .white.opacity(0.16), location: 0.50),
                    .init(color: .white.opacity(0),    location: 0.80),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            // Wide, soft band — the falloff does the work, not a sharp edge.
            .frame(width: w * 1.6)
            .offset(x: phase * w)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
        .mask(Capsule())
        .opacity(active ? 1 : 0)
        .onChange(of: active) { _, isActive in
            guard isActive else { return }
            // Reset off-left, then drift across with a slow easeInOut that
            // lands right as the dismiss timer fires.
            phase = -1.2
            withAnimation(
                .easeInOut(duration: NoSpeechAnimationTiming.lightDriftDuration)
                    .delay(NoSpeechAnimationTiming.lightDriftDelay)
            ) {
                phase = 1.2
            }
        }
    }
}

/// The dictation overlay — compact dark capsule during dictation, wider card for errors.
struct DictationOverlayView: View {
    @Bindable var viewModel: DictationOverlayViewModel

    /// Drives the no-speech pill's circle → oval width expansion. Starts `false`
    /// so the pill begins at 46×46 (matching the processing spinner), then flips
    /// to `true` after a short delay so the pill blooms horizontally as the leaf
    /// + "more audio please" label fade in. Reset whenever the pill state changes.
    @State private var noSpeechExpanded: Bool = false

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
        .onChange(of: viewModel.pillStateKey) { _, newKey in
            handlePillStateChange(to: newKey)
        }
    }

    /// When entering any noSpeech state, start as a 46×46 circle and schedule the
    /// oval expansion after a short delay so the Merkaba can begin dissolving in
    /// its circular form before the pill blooms horizontally.
    private func handlePillStateChange(to key: String) {
        guard key.contains("noSpeech") else {
            noSpeechExpanded = false
            return
        }
        noSpeechExpanded = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // Guard against stale transitions: only expand if we are still in noSpeech.
            guard viewModel.pillStateKey.contains("noSpeech") else { return }
            withAnimation(.easeOut(duration: 0.45)) {
                noSpeechExpanded = true
            }
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch viewModel.state {
        case .error(let message):
            errorCard(message: message)

        default:
            let isReady = if case .ready = viewModel.state { true } else { false }
            // Processing (non-command) and success show a single icon — use equal
            // padding so the Capsule background renders as a perfect circle, not
            // an oval. noSpeech starts as a circle (matching processing) and then
            // blooms into an oval once `noSpeechExpanded` flips — so its label
            // reads cleanly on a full dark background after the expansion.
            let isIconOnly: Bool = {
                switch viewModel.state {
                case .processing: return viewModel.sessionKind != .command
                case .formatting: return viewModel.sessionKind != .command
                case .success: return true
                case .noSpeech: return !noSpeechExpanded
                default: return false
                }
            }()
            // noSpeech (expanded) uses tighter horizontal padding and smaller vertical
            // padding than the circular phase, so the bloom animation stretches the
            // 46×46 circle horizontally while also slimming down vertically into a
            // low-profile terminal pill.
            let isNoSpeechState = { if case .noSpeech = viewModel.state { return true } else { return false } }()
            let isNoSpeechExpanded = isNoSpeechState && noSpeechExpanded
            // Ready uses equal horizontal/vertical padding so the breathing
            // ring sits inside a tight ~32×32 circular pill — distinctly
            // smaller and lighter than the 46×46 processing / noSpeech
            // circles, reinforcing that `.ready` is a brief, poised pause
            // rather than active work.
            let horizontalPadding: CGFloat = {
                if isReady { return 7 }
                if isIconOnly { return 10 }
                if isNoSpeechExpanded { return 10 }
                return 16
            }()
            let verticalPadding: CGFloat = {
                if isReady { return 7 }
                if isIconOnly { return 10 }
                if isNoSpeechExpanded { return 5 }
                return 7
            }()
            pillContent
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(
                    Capsule()
                        .fill(DesignSystem.Colors.pillBackground)
                        .overlay(
                            Capsule()
                                .strokeBorder(DesignSystem.Colors.pillBorder, lineWidth: 1)
                        )
                        // Slow horizontal light drift that accompanies the
                        // no-speech pill's farewell — lands exactly at the
                        // dismiss boundary. No-op for every other state:
                        // `active` stays false, view sits at opacity 0, and
                        // onChange never fires.
                        .overlay(NoSpeechLightDrift(active: isNoSpeechExpanded))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                )
                .animation(.easeInOut(duration: 0.25), value: viewModel.pillStateKey)
                .animation(.easeOut(duration: 0.45), value: noSpeechExpanded)
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

            case .formatting:
                formattingContent
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))

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

    /// Ready pill — a gentle breathing ring that appears briefly after the
    /// first Fn tap while the state machine waits to see if a second tap lands
    /// (double-tap = persistent recording) or the window elapses (back to
    /// idle). The breath ring belongs to the same sacred-geometry family as
    /// `SpinnerRingView` (processing) and `MerkabaDissipateView` (no speech),
    /// but is the smallest and lightest member — a poised inhale rather than
    /// active work or a terminal dissolve.
    private var readyContent: some View {
        BreathingRingView(size: 18)
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

    // MARK: - Formatting State (AI formatter refinement)

    /// Shown between `.processing` and `.success` when the AI formatter is
    /// enabled and actually running on the transcript. Renders the spinning
    /// Seed of Life bloom via `FormatterVisualView`.
    ///
    /// For command sessions we fall back to the standard spinner + a
    /// "Refining..." label so the copy continues to read during refinement
    /// — formatting context is already implied by the visible command text.
    private var formattingContent: some View {
        Group {
            if viewModel.sessionKind == .command {
                HStack(spacing: 8) {
                    SpinnerRingView()
                    Text("Refining...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.80))
                }
            } else {
                FormatterVisualView()
            }
        }
    }

    // MARK: - Success State

    private var successContent: some View {
        AnimatedCheckmarkView()
    }

    // MARK: - No Speech State

    private var noSpeechContent: some View {
        NoSpeechContentView(
            isCommand: viewModel.sessionKind == .command,
            expanded: noSpeechExpanded
        )
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
