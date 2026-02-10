import SwiftUI

/// The dictation overlay pill — compact dark capsule shown during dictation.
struct DictationOverlayView: View {
    @Bindable var viewModel: DictationOverlayViewModel

    var body: some View {
        VStack(spacing: 4) {
            // Tooltip space (always reserved to prevent resize jitter)
            Text(tooltipText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .opacity(0) // Hidden by default, shown on hover via overlay
                .frame(height: 20)

            // Main pill
            pillContent
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.9))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
        }
    }

    @ViewBuilder
    private var pillContent: some View {
        switch viewModel.state {
        case .recording:
            recordingContent

        case .cancelled(let timeRemaining):
            cancelledContent(timeRemaining: timeRemaining)

        case .processing:
            processingContent

        case .success:
            successContent

        case .error(let message):
            errorContent(message: message)
        }
    }

    // MARK: - Recording State

    private var recordingContent: some View {
        HStack(spacing: 10) {
            // Cancel button
            Button(action: { viewModel.onCancel?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.2)))
            }
            .buttonStyle(.plain)

            // Recording timer
            Text(viewModel.formattedElapsed)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 36)

            // Waveform
            WaveformView(audioLevel: viewModel.audioLevel)
                .frame(width: 60)

            // Stop button
            Button(action: { viewModel.onStop?() }) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .padding(6)
                    .background(Circle().fill(Color.red))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Cancelled State

    private func cancelledContent(timeRemaining: Double) -> some View {
        HStack(spacing: 10) {
            // Countdown ring
            ZStack {
                Circle()
                    .trim(from: 0, to: CGFloat(timeRemaining / 5.0))
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(-90))

                Text("\(Int(ceil(timeRemaining)))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }

            // Undo button
            Button(action: { viewModel.onUndo?() }) {
                Text("Undo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Processing State

    private var processingContent: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .tint(.white)

            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
        }
    }

    // MARK: - Success State

    private var successContent: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 20))
            .foregroundStyle(.green)
    }

    // MARK: - Error State

    private func errorContent(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.yellow)

            Text(friendlyErrorMessage(message))
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    /// Convert technical error messages into short user-friendly text
    private func friendlyErrorMessage(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("stt") || lower.contains("daemon") || lower.contains("python")
            || lower.contains("failed to start") {
            return "STT not ready"
        }
        if lower.contains("microphone") || lower.contains("audio input")
            || lower.contains("recording") {
            return "Mic unavailable"
        }
        if lower.contains("permission") || lower.contains("access") {
            return "Permission needed"
        }
        if lower.contains("not recording") {
            return "Not recording"
        }
        // Fallback: truncate to fit pill
        if message.count > 20 {
            return String(message.prefix(17)) + "..."
        }
        return message
    }

    private var tooltipText: String {
        switch viewModel.state {
        case .recording: return "Press Fn to finish"
        case .cancelled: return "Dismiss"
        case .processing: return "Processing..."
        case .success: return ""
        case .error: return ""
        }
    }
}

#Preview {
    VStack(spacing: 20) {
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
            vm.state = .error("Couldn't hear you — check mic")
            return vm
        }())
    }
    .padding(30)
    .background(Color.gray.opacity(0.3))
}
