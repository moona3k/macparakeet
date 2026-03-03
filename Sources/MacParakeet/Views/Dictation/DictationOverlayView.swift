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
            pillContent
                .padding(.horizontal, isReady ? 6 : 10)
                .padding(.vertical, isReady ? 4 : 7)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.9))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
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
                if viewModel.recordingMode == .holdToTalk {
                    holdToTalkContent
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                } else {
                    Group {
                        if viewModel.sessionKind == .command {
                            commandRecordingContent
                        } else {
                            recordingContent
                        }
                    }
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }

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

    private var holdToTalkContent: some View {
        HStack(spacing: 10) {
            // Recording indicator dot
            Circle()
                .fill(Color.red)
                .frame(width: 5, height: 5)

            // Live waveform — fewer bars than full recording pill
            WaveformView(audioLevel: viewModel.audioLevel, barCount: 8)
                .frame(width: 44, height: 16)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Recording State

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

            recordingContent
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
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))

                Text(viewModel.sessionKind == .command ? "No command detected" : "No speech detected")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }

            // Thin progress bar — track + fill, shrinks over 3s
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(Color.white.opacity(0.4))
                    .scaleEffect(x: viewModel.noSpeechProgress, anchor: .trailing)
                    .animation(.linear(duration: 3.0), value: viewModel.noSpeechProgress)
            }
            .frame(height: 2.5)
            .onAppear {
                // Trigger after the view renders so SwiftUI has a "from" value to animate
                viewModel.noSpeechProgress = 0.0
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    // MARK: - Error Card

    private func errorCard(message: String) -> some View {
        let info = errorInfo(message)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Icon in tinted circle
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.12))
                        .frame(width: 32, height: 32)

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
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
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
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
            return ("Not Recording", "Press \(HotkeyTrigger.current.displayName) to start recording first.")
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
                    .fill(Color.black.opacity(0.9))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            )
        }
    }

    private var tooltipText: String {
        switch viewModel.state {
        case .ready: return ""
        case .recording: return "" // Per-button tooltips via hoverTooltip
        case .cancelled: return ""
        case .processing: return ""
        case .success: return ""
        case .noSpeech: return ""
        case .error: return ""
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
            vm.noSpeechProgress = 0.6
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
